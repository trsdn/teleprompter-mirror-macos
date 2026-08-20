import AppKit
import CoreGraphics
import Foundation
import OSLog
import ServiceManagement
import TeleprompterCore

private let lifecycleLogger = Logger(
    subsystem: "com.github.trsdn.TeleprompterMirror",
    category: "lifecycle"
)

/// Name of the physical display preferred as the default output target.
private let preferredTargetName = "AAA"

private enum AppModelError: LocalizedError {
    case captureStoppedDuringStart(String)
    case renderingFailedDuringStart(String)

    var errorDescription: String? {
        switch self {
        case let .captureStoppedDuringStart(message):
            return "Die Bildschirmaufnahme wurde beim Start beendet: \(message)"
        case let .renderingFailedDuringStart(message):
            return "Die Bildausgabe ist beim Start fehlgeschlagen: \(message)"
        }
    }
}

private enum SettingsStore {
    static let key = "app-settings-v1"

    static func load(from defaults: UserDefaults) -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            return .defaults
        }
        do {
            return try AppSettingsCodec.decode(data)
        } catch {
            NSLog(
                "Gespeicherte Einstellungen sind ungültig; Standardwerte werden verwendet: %@",
                error.localizedDescription
            )
            return .defaults
        }
    }

    static func save(_ settings: AppSettings, to defaults: UserDefaults) {
        do {
            defaults.set(try AppSettingsCodec.encode(settings), forKey: key)
        } catch {
            NSLog(
                "Einstellungen konnten nicht gespeichert werden: %@",
                error.localizedDescription
            )
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var displays: [DisplayDescriptor] = []
    @Published private(set) var windows: [WindowDescriptor] = []
    @Published private(set) var sourceKind: CaptureSourceKind
    @Published private(set) var selectedSourceDisplayID: CGDirectDisplayID?
    @Published private(set) var selectedSourceWindowID: CGWindowID?
    @Published private(set) var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var transform: DisplayTransform
    @Published private(set) var autoStartOutput: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var isRefreshingWindows = false
    @Published private(set) var permissionGranted = false
    @Published private(set) var statusText = "Monitore werden gesucht …"
    @Published private(set) var statusIsError = false
    @Published private(set) var loginItemEnabled = false
    @Published private(set) var loginItemBusy = false
    @Published private(set) var loginItemNeedsApproval = false
    @Published private(set) var loginItemStatusText =
        "Anmeldestatus wird geprüft …"
    @Published private(set) var loginItemStatusIsError = false

    private enum Lifecycle: Equatable {
        case idle
        case waiting
        case starting(UInt64)
        case running
        case stopping
        case blocked
    }

    private enum BlockReason: Equatable {
        case permission
        case capture
    }

    private let defaults: UserDefaults
    private let isSelfTest =
        CommandLine.arguments.contains("--self-test")
    private var settings: AppSettings
    /// A separate process owns the private virtual display. Keeping creation
    /// and ScreenCaptureKit capture in different processes avoids a macOS 26
    /// failure where a Finder-launched app receives no stream callbacks. The
    /// host only runs while the virtual display is actually the source.
    private var virtualDisplayHost: VirtualDisplayHostProcess?
    private var virtualDisplayID: CGDirectDisplayID?
    private var workingSource: CaptureSourceSelection
    private var workingTargetIdentity: PersistentDisplayIdentity?
    private var lifecycle: Lifecycle = .idle
    private var blockReason: BlockReason?
    private var desiredOutput = false
    private var manualStopSuppressed = false
    private var operationEpoch: UInt64 = 0
    private var pendingCaptureStop: (epoch: UInt64, message: String)?
    private var pendingRenderingFailure: (epoch: UInt64, message: String)?
    private var captureSession: CaptureSession?
    private var outputController: OutputWindowController?
    private var startingCaptureSession: CaptureSession?
    private var startingOutputController: OutputWindowController?
    private var activeSnapshot: ResolvedCaptureSnapshot?
    private var displayChangeTask: Task<Void, Never>?
    private var windowRefreshTask: Task<Void, Never>?
    private var selfTestTimeoutTask: Task<Void, Never>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var didLaunch = false
    private var selfTestRenderedFrame = false

    init(defaults: UserDefaults = .standard) {
        let loaded = SettingsStore.load(from: defaults).normalized()
        self.defaults = defaults
        settings = loaded
        autoStartOutput = loaded.autoStartOutput

        let configuration = loaded.configuration
        workingSource = configuration.source
        sourceKind = configuration.source.kind
        workingTargetIdentity = configuration.target
        transform = configuration.transform
        permissionGranted = CGPreflightScreenCaptureAccess()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        refreshDisplaySnapshot()
        updateIdleStatus()
    }

    deinit {
        displayChangeTask?.cancel()
        windowRefreshTask?.cancel()
        selfTestTimeoutTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    var canStart: Bool {
        !isRunning && !isBusy && workingTargetIdentity != nil
            && workingSource.isComplete
    }

    var canStop: Bool {
        desiredOutput || isRunning || isBusy
    }

    var usesVirtualSource: Bool {
        sourceKind == .virtualDisplay
    }

    var virtualSourceName: String {
        VirtualSource.name
    }

    /// Physical displays that may act as a source. The output target is
    /// excluded, because mirroring a display onto itself would cover it.
    var sourceDisplays: [DisplayDescriptor] {
        displays.filter { $0.id != selectedDisplayID }
    }

    var sourceSummary: String {
        switch sourceKind {
        case .virtualDisplay:
            return "Virtueller Monitor „\(VirtualSource.name)“ (\(VirtualSource.width)×\(VirtualSource.height))"
        case .display:
            guard let identity = workingSource.display else {
                return "Kein Quellmonitor ausgewählt."
            }
            return selectedSourceDisplayID == nil
                ? "Gespeicherter Quellmonitor, derzeit nicht eindeutig verbunden: \(identity.localizedName)"
                : identity.localizedName
        case .window:
            guard let identity = workingSource.window else {
                return "Kein Quellfenster ausgewählt."
            }
            return selectedSourceWindowID == nil
                ? "Gespeichertes Fenster, derzeit nicht eindeutig geöffnet: \(identity.localizedName)"
                : identity.localizedName
        }
    }

    var displayConnectionHint: String? {
        guard selectedDisplayID == nil,
              let identity = workingTargetIdentity else {
            return nil
        }
        return "Gespeichertes Ziel, derzeit nicht eindeutig verbunden: \(identity.localizedName) — \(identity.nativeLongEdge)×\(identity.nativeShortEdge)"
    }

    var singleDisplayNotice: String? {
        guard displays.count == 1 else {
            return nil
        }
        if sourceKind == .display {
            return "Nur ein physischer Monitor ist verbunden; er kann nicht gleichzeitig Quelle und Ziel sein. Fenstermodus oder virtuellen Monitor wählen."
        }
        return "Nur ein physischer Monitor ist verbunden; er dient als Ziel und die Ausgabe überdeckt dort den Schreibtisch. Stoppen bleibt über das Statusmenü erreichbar."
    }

    var appIsInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path == "/Applications"
            || path.hasPrefix("/Applications/")
    }

    func appDidLaunch() {
        guard !didLaunch else {
            return
        }
        didLaunch = true
        Task { @MainActor [weak self] in
            await self?.finishLaunching()
        }
    }

    private func finishLaunching() async {
        if usesVirtualSource {
            await ensureVirtualSource()
        }
        updatePermissionStatus()
        refreshLoginItemStatus()
        if sourceKind == .window {
            refreshWindows()
        }

        if isSelfTest {
            await startSelfTestIfRequested()
        } else if autoStartOutput {
            desiredOutput = true
            await reconcileOutput()
        }
    }

    /// Starts a headless copy of this signed executable that owns the virtual
    /// display for as long as it is the selected source. The main process
    /// remains the sole ScreenCaptureKit client.
    private func ensureVirtualSource() async {
        guard virtualDisplayID == nil else {
            return
        }
        let host = VirtualDisplayHostProcess()
        do {
            let displayID = try await host.start()
            virtualDisplayHost = host
            virtualDisplayID = displayID
            lifecycleLogger.notice(
                "Virtueller Quellmonitor im Display-Host erstellt: \(displayID, privacy: .public) (\(VirtualSource.width, privacy: .public)×\(VirtualSource.height, privacy: .public))"
            )
        } catch {
            setStatus(
                "Der virtuelle Quellmonitor konnte nicht erstellt werden: \(error.localizedDescription)",
                isError: true
            )
            return
        }
        // Re-enumerate so the new virtual display is excluded from targets.
        refreshDisplaySnapshot()
        updateIdleStatus()
    }

    /// Tears the virtual display down when another source is chosen, so no
    /// unused synthetic monitor stays in the arrangement.
    private func releaseVirtualSource() {
        guard virtualDisplayHost != nil || virtualDisplayID != nil else {
            return
        }
        virtualDisplayHost?.stop()
        virtualDisplayHost = nil
        virtualDisplayID = nil
        refreshDisplaySnapshot()
    }

    func selectSourceKind(_ kind: CaptureSourceKind) {
        guard kind != sourceKind else {
            return
        }
        let shouldContinueOutput =
            !manualStopSuppressed && (desiredOutput || isRunning)
        invalidateStartIfNeeded()

        sourceKind = kind
        workingSource.kind = kind
        blockReason = nil

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if isRunning || captureSession != nil {
                await stopCommittedOutput(
                    message: "Quelle gewechselt; Ausgabe wird neu aufgebaut.",
                    isError: false
                )
            }
            switch kind {
            case .virtualDisplay:
                await ensureVirtualSource()
            case .display:
                releaseVirtualSource()
            case .window:
                releaseVirtualSource()
                refreshWindows()
            }
            refreshDisplaySnapshot()
            persistConfiguration()
            desiredOutput = shouldContinueOutput
            updateIdleStatus()
            await reconcileOutput()
        }
    }

    func selectSourceDisplay(_ displayID: CGDirectDisplayID?) {
        guard !isRunning, !isBusy else {
            return
        }
        selectedSourceDisplayID = displayID
        workingSource.display = displayID.flatMap { id in
            displays.first(where: { $0.id == id })?.identity
        }
        persistConfiguration()
        updateIdleStatus()
    }

    func selectSourceWindow(_ windowID: CGWindowID?) {
        guard !isRunning, !isBusy else {
            return
        }
        selectedSourceWindowID = windowID
        workingSource.window = windowID.flatMap { id in
            windows.first(where: { $0.id == id })?.identity
        }
        persistConfiguration()
        updateIdleStatus()
    }

    func selectDisplay(_ displayID: CGDirectDisplayID?) {
        guard !isRunning, !isBusy else {
            return
        }
        selectedDisplayID = displayID
        workingTargetIdentity = displayID.flatMap { id in
            displays.first(where: { $0.id == id })?.identity
        }
        // A display can never be its own source and target at the same time.
        if sourceKind == .display, displayID != nil,
           selectedSourceDisplayID == displayID {
            selectSourceDisplay(nil)
        }
        persistConfiguration()
        updateIdleStatus()
    }

    func setTransform(_ newTransform: DisplayTransform) {
        transform = newTransform
        outputController?.updateTransform(newTransform)
        persistConfiguration()
    }

    func resetTransform() {
        setTransform(.teleprompterDefault)
    }

    func refreshWindows() {
        guard !isRefreshingWindows else {
            return
        }
        isRefreshingWindows = true
        windowRefreshTask?.cancel()
        windowRefreshTask = Task { @MainActor [weak self] in
            let found = await DisplayCatalog.availableWindows()
            guard let self, !Task.isCancelled else {
                return
            }
            windows = found
            selectedSourceWindowID = DisplayCatalog.resolve(
                workingSource.window,
                among: found
            )?.id
            isRefreshingWindows = false
            updateIdleStatus()
        }
    }

    func setAutoStartOutput(_ enabled: Bool) {
        autoStartOutput = enabled
        settings.autoStartOutput = enabled
        persistSettings()

        if enabled {
            if !manualStopSuppressed {
                blockReason = nil
                desiredOutput = true
            }
        } else {
            desiredOutput = false
            invalidateStartIfNeeded()
        }
        Task { @MainActor [weak self] in
            await self?.reconcileOutput(
                stopMessage: "Automatische Ausgabe wurde deaktiviert."
            )
        }
    }

    func refreshDisplays() {
        refreshDisplaySnapshot()
        if sourceKind == .window {
            refreshWindows()
        }
        updateIdleStatus()
        Task { @MainActor [weak self] in
            await self?.reconcileOutput()
        }
    }

    func updatePermissionStatus() {
        permissionGranted = CGPreflightScreenCaptureAccess()
        if permissionGranted {
            let wasBlockedOnPermission = blockReason == .permission
            if wasBlockedOnPermission {
                blockReason = nil
            }
            if lifecycle == .idle || wasBlockedOnPermission {
                setStatus(
                    "Bildschirmaufnahme ist erlaubt.",
                    isError: false
                )
            }
            if didLaunch, desiredOutput {
                Task { @MainActor [weak self] in
                    await self?.reconcileOutput()
                }
            }
        } else {
            if lifecycle != .running {
                setStatus(
                    "Bildschirmaufnahme ist nicht erlaubt. Zugriff in den Systemeinstellungen freigeben.",
                    isError: true
                )
            }
            if didLaunch, desiredOutput || isRunning {
                Task { @MainActor [weak self] in
                    await self?.reconcileOutput()
                }
            }
        }
    }

    func requestPermission() {
        let granted = CGRequestScreenCaptureAccess()
        permissionGranted = granted || CGPreflightScreenCaptureAccess()

        if permissionGranted {
            if blockReason == .permission {
                blockReason = nil
            }
            setStatus(
                "Berechtigung erteilt. Die Ausgabe kann jetzt starten.",
                isError: false
            )
            if desiredOutput {
                Task { @MainActor [weak self] in
                    await self?.reconcileOutput()
                }
            }
        } else {
            blockReason = .permission
            setLifecycle(.blocked)
            setStatus(
                "Berechtigung wurde nicht erteilt. Systemeinstellungen → Datenschutz & Sicherheit → Bildschirmaufnahme öffnen.",
                isError: true
            )
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ), NSWorkspace.shared.open(url) else {
            setStatus(
                "Die Systemeinstellungen konnten nicht geöffnet werden.",
                isError: true
            )
            return
        }
    }

    func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        loginItemNeedsApproval = false
        loginItemStatusIsError = false

        switch status {
        case .enabled:
            loginItemEnabled = true
            loginItemStatusText = "Start bei Anmeldung ist registriert."
        case .notRegistered:
            loginItemEnabled = false
            loginItemStatusText = "Start bei Anmeldung ist deaktiviert."
        case .requiresApproval:
            loginItemEnabled = true
            loginItemNeedsApproval = true
            loginItemStatusIsError = true
            loginItemStatusText =
                "Registriert, aber noch in den Systemeinstellungen zu erlauben."
        case .notFound:
            loginItemEnabled = false
            loginItemStatusIsError = true
            loginItemStatusText =
                "Der Anmeldedienst wurde für dieses App-Bundle nicht gefunden."
        @unknown default:
            loginItemEnabled = false
            loginItemStatusIsError = true
            loginItemStatusText = "Unbekannter Anmeldestatus."
        }
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        guard !loginItemBusy else {
            return
        }
        loginItemBusy = true

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
                }
                refreshLoginItemStatus()
            } catch {
                refreshLoginItemStatus()
                loginItemStatusIsError = true
                loginItemStatusText =
                    "Änderung fehlgeschlagen: \(error.localizedDescription)"
            }
            loginItemBusy = false
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func start() async {
        manualStopSuppressed = false
        blockReason = nil
        desiredOutput = true
        await reconcileOutput()
    }

    func requestStop(message: String = "Ausgabe beendet.") {
        manualStopSuppressed = true
        desiredOutput = false
        blockReason = nil
        invalidateStartIfNeeded()

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if lifecycle == .running
                || captureSession != nil
                || startingCaptureSession != nil
                || startingOutputController != nil {
                await stopCommittedOutput(
                    message: message,
                    isError: false
                )
            } else if isBusy {
                setStatus(message, isError: false)
            } else {
                setLifecycle(.idle)
                setStatus(message, isError: false)
                ControlWindowCoordinator.restoreNormalLevels()
            }
        }
    }

    func showControls() {
        ControlWindowCoordinator.showControls()
    }

    func shutdown() async {
        displayChangeTask?.cancel()
        windowRefreshTask?.cancel()
        selfTestTimeoutTask?.cancel()
        manualStopSuppressed = true
        desiredOutput = false
        blockReason = nil
        invalidateStartIfNeeded()

        if captureSession != nil
            || outputController != nil
            || startingCaptureSession != nil
            || startingOutputController != nil
            || lifecycle == .running
            || isBusy {
            await stopCommittedOutput(
                message: "App wird beendet.",
                isError: false
            )
        }
        virtualDisplayHost?.stop()
        virtualDisplayHost = nil
        virtualDisplayID = nil
    }

    func startSelfTestIfRequested() async {
        guard isSelfTest else {
            return
        }
        // The self test always exercises the virtual source path, because it
        // is the only source that needs no user interaction to exist.
        sourceKind = .virtualDisplay
        workingSource = .virtualDisplay
        await ensureVirtualSource()
        guard let virtualDisplayID else {
            finishSelfTest(
                "SELF_TEST_FAIL: Der virtuelle Quellmonitor konnte nicht erstellt werden.",
                isError: true
            )
            return
        }
        updatePermissionStatus()
        guard permissionGranted else {
            finishSelfTest(
                "SELF_TEST_SKIP: Für com.github.trsdn.TeleprompterMirror ist keine Bildschirmaufnahme-Berechtigung vorhanden.",
                isError: false
            )
            return
        }

        refreshDisplaySnapshot()
        guard let target = resolvedTarget ?? DisplayCatalog.defaultTarget(
            among: displays,
            preferredName: preferredTargetName
        ) else {
            finishSelfTest(
                "SELF_TEST_FAIL: Kein physischer Zielmonitor ist verfügbar.",
                isError: true
            )
            return
        }

        workingTargetIdentity = target.identity
        selectedDisplayID = target.id
        transform = .teleprompterDefault
        manualStopSuppressed = false
        blockReason = nil
        desiredOutput = true

        let startMessage =
            "SELF_TEST_START: virtueller Quellmonitor \(virtualDisplayID) → Zielmonitor \(target.name) ID \(target.id) (\(target.pixelWidth)x\(target.pixelHeight))"
        NSLog("%@", startMessage)
        lifecycleLogger.notice("\(startMessage, privacy: .public)")

        selfTestTimeoutTask?.cancel()
        selfTestTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            guard let self, !selfTestRenderedFrame else {
                return
            }
            finishSelfTest(
                "SELF_TEST_FAIL: Innerhalb von 15 Sekunden wurde kein Frame dargestellt.",
                isError: true
            )
        }

        await reconcileOutput()
    }

    func prepareForTermination() {
        outputController?.close()
        startingOutputController?.close()
        outputController = nil
        startingOutputController = nil
        captureSession = nil
        startingCaptureSession = nil
        activeSnapshot = nil
        virtualDisplayHost?.stop()
        virtualDisplayHost = nil
        virtualDisplayID = nil
    }

    private var currentConfiguration: TeleprompterConfiguration {
        TeleprompterConfiguration(
            source: workingSource,
            target: workingTargetIdentity,
            transform: transform
        )
    }

    private func persistConfiguration() {
        settings.configuration = currentConfiguration
        persistSettings()
    }

    private func persistSettings() {
        SettingsStore.save(settings, to: defaults)
    }

    private func refreshDisplaySnapshot() {
        displays = DisplayCatalog.connectedDisplays(
            excluding: virtualDisplayID
        )
        // Adopt a default target only when nothing is saved yet, so a saved
        // but temporarily disconnected target is preserved for reconnect.
        if workingTargetIdentity == nil,
           let fallback = DisplayCatalog.defaultTarget(
               among: displays,
               preferredName: preferredTargetName
           ) {
            workingTargetIdentity = fallback.identity
        }
        selectedDisplayID = resolvedTarget?.id
        selectedSourceDisplayID = resolvedSourceDisplay?.id
    }

    /// The saved output target if it resolves uniquely among the physical
    /// displays, otherwise `nil` (the app then waits for reconnect).
    private var resolvedTarget: DisplayDescriptor? {
        DisplayCatalog.resolve(
            workingTargetIdentity,
            among: displays
        )
    }

    private var resolvedSourceDisplay: DisplayDescriptor? {
        guard sourceKind == .display else {
            return nil
        }
        return DisplayCatalog.resolve(
            workingSource.display,
            among: displays
        )
    }

    private var resolvedSourceWindow: WindowDescriptor? {
        guard sourceKind == .window else {
            return nil
        }
        return DisplayCatalog.resolve(
            workingSource.window,
            among: windows
        )
    }

    private func reconcileOutput(
        stopMessage: String = "Ausgabe beendet."
    ) async {
        guard didLaunch else {
            return
        }

        guard desiredOutput, !manualStopSuppressed else {
            if lifecycle == .running || captureSession != nil {
                await stopCommittedOutput(
                    message: stopMessage,
                    isError: false
                )
            } else if !isBusy {
                setLifecycle(.idle)
                updateIdleStatus()
            }
            return
        }

        if blockReason != nil {
            setLifecycle(.blocked)
            return
        }

        permissionGranted = CGPreflightScreenCaptureAccess()
        guard permissionGranted else {
            blockReason = .permission
            let message =
                "Automatischer Start wartet auf Bildschirmaufnahme-Berechtigung. Bitte Zugriff erlauben."
            if lifecycle == .running || captureSession != nil {
                await stopCommittedOutput(
                    message: message,
                    isError: true
                )
            } else {
                setLifecycle(.blocked)
                setStatus(message, isError: true)
            }
            return
        }

        if usesVirtualSource, virtualDisplayID == nil {
            let message =
                "Der virtuelle Quellmonitor konnte nicht erstellt werden (private API nicht verfügbar)."
            if lifecycle == .running || captureSession != nil {
                await stopCommittedOutput(message: message, isError: true)
            } else {
                setLifecycle(.blocked)
                setStatus(message, isError: true)
            }
            return
        }

        guard let target = resolvedTarget, resolvedSourceIsAvailable else {
            if case .starting = lifecycle {
                operationEpoch &+= 1
                setStatus(waitingStatusText, isError: false)
                return
            }
            if lifecycle == .running || captureSession != nil {
                await stopCommittedOutput(
                    message: waitingStatusText,
                    isError: false
                )
            } else if lifecycle != .stopping {
                setLifecycle(.waiting)
                setStatus(waitingStatusText, isError: false)
            }
            return
        }

        if lifecycle == .running {
            guard let activeSnapshot,
                  activeSnapshot.targetDescriptor.id == target.id,
                  activeSnapshot.targetDescriptor.identity
                    == target.identity,
                  activeSnapshot.targetDescriptor.pixelWidth
                    == target.pixelWidth,
                  activeSnapshot.targetDescriptor.pixelHeight
                    == target.pixelHeight,
                  activeSnapshot.targetDescriptor.frame
                    == target.frame else {
                await stopCommittedOutput(
                    message: "Monitorkonfiguration geändert; Ausgabe wird neu gestartet.",
                    isError: false
                )
                return
            }
            outputController?.updateTransform(transform)
            return
        }

        switch lifecycle {
        case .starting, .stopping:
            return
        case .idle, .waiting, .blocked:
            await startResolvedOutput(target: target)
        case .running:
            break
        }
    }

    /// True when the currently selected source can be captured right now.
    private var resolvedSourceIsAvailable: Bool {
        switch sourceKind {
        case .virtualDisplay:
            return virtualDisplayID != nil
        case .display:
            return resolvedSourceDisplay != nil
        case .window:
            return resolvedSourceWindow != nil
        }
    }

    private func makeSnapshot(
        target: DisplayDescriptor
    ) async throws -> ResolvedCaptureSnapshot {
        switch sourceKind {
        case .virtualDisplay:
            guard let virtualDisplayID else {
                throw DisplayResolutionError.virtualSourceUnavailable
            }
            return try await DisplayCatalog.makeVirtualSourceSnapshot(
                virtualDisplayID: virtualDisplayID,
                sourceWidth: VirtualSource.width,
                sourceHeight: VirtualSource.height,
                target: target
            )
        case .display:
            guard let source = resolvedSourceDisplay else {
                throw DisplayResolutionError.sourceDisplayUnavailable
            }
            return try await DisplayCatalog.makeDisplaySourceSnapshot(
                source: source,
                target: target
            )
        case .window:
            guard let source = resolvedSourceWindow else {
                throw DisplayResolutionError.sourceWindowUnavailable
            }
            return try await DisplayCatalog.makeWindowSourceSnapshot(
                source: source,
                target: target
            )
        }
    }

    private func startResolvedOutput(
        target: DisplayDescriptor
    ) async {
        operationEpoch &+= 1
        let epoch = operationEpoch
        pendingCaptureStop = nil
        pendingRenderingFailure = nil
        setLifecycle(.starting(epoch))
        setStatus("Aufnahme wird sicher vorbereitet …", isError: false)

        var localOutput: OutputWindowController?
        var localSession: CaptureSession?

        do {
            let snapshot = try await makeSnapshot(target: target)
            guard epoch == operationEpoch,
                  desiredOutput,
                  !manualStopSuppressed else {
                if lifecycle == .starting(epoch) {
                    setLifecycle(.idle)
                }
                await reconcileOutput()
                return
            }

            ControlWindowCoordinator.prepareForOutput(
                targetScreen: snapshot.targetScreen,
                virtualDisplayID: virtualDisplayID
            )

            let output = try OutputWindowController(
                snapshot: snapshot,
                transform: transform,
                onFirstFrame: { [weak self] path in
                    self?.firstFrameWasRendered(
                        epoch: epoch,
                        path: path
                    )
                },
                onFailure: { [weak self] message in
                    self?.renderingFailed(
                        epoch: epoch,
                        message: message
                    )
                }
            )
            localOutput = output
            startingOutputController = output

            let session = try CaptureSession(
                snapshot: snapshot,
                frameReceiver: output.frameReceiver,
                onUnexpectedStop: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.captureStoppedUnexpectedly(
                            epoch: epoch,
                            message: message
                        )
                    }
                }
            )
            localSession = session
            startingCaptureSession = session
            try await session.start()

            if let pendingCaptureStop,
               pendingCaptureStop.epoch == epoch {
                throw AppModelError.captureStoppedDuringStart(
                    pendingCaptureStop.message
                )
            }
            if let pendingRenderingFailure,
               pendingRenderingFailure.epoch == epoch {
                throw AppModelError.renderingFailedDuringStart(
                    pendingRenderingFailure.message
                )
            }

            guard epoch == operationEpoch,
                  desiredOutput,
                  !manualStopSuppressed else {
                try? await session.stop()
                output.close()
                if lifecycle == .starting(epoch) {
                    setLifecycle(.idle)
                }
                await reconcileOutput()
                return
            }

            try DisplayCatalog.revalidate(
                snapshot,
                virtualDisplayID: virtualDisplayID
            )
            guard epoch == operationEpoch,
                  desiredOutput,
                  !manualStopSuppressed else {
                try? await session.stop()
                output.close()
                if lifecycle == .starting(epoch) {
                    setLifecycle(.idle)
                }
                await reconcileOutput()
                return
            }

            output.updateTransform(transform)
            captureSession = session
            outputController = output
            if startingCaptureSession === session {
                startingCaptureSession = nil
            }
            if startingOutputController === output {
                startingOutputController = nil
            }
            activeSnapshot = snapshot
            localSession = nil
            localOutput = nil
            pendingCaptureStop = nil
            pendingRenderingFailure = nil
            setLifecycle(.running)
            output.reveal()
            setStatus(
                "Ausgabe aktiv; warte auf den ersten vollständigen Frame …",
                isError: false
            )
            lifecycleLogger.notice(
                "Ausgabe gestartet: Quelle \(snapshot.sourceLabel, privacy: .public) → Zielmonitor \(snapshot.targetDescriptor.id, privacy: .public)"
            )
        } catch {
            let startError = error
            if let localSession {
                try? await localSession.stop()
            }
            localOutput?.close()
            if startingCaptureSession === localSession {
                startingCaptureSession = nil
            }
            if startingOutputController === localOutput {
                startingOutputController = nil
            }
            pendingCaptureStop = nil
            pendingRenderingFailure = nil

            guard epoch == operationEpoch else {
                if lifecycle == .starting(epoch) {
                    setLifecycle(.idle)
                }
                await reconcileOutput()
                return
            }

            refreshDisplaySnapshot()
            if isTransientSourceStartError(startError) {
                // Der virtuelle Quellmonitor ist noch nicht online bzw. für die
                // Bildschirmaufnahme bereit (z. B. unmittelbar nach dem
                // Erstellen beim Login-Autostart) oder die Monitorkonfiguration
                // hat sich während des Starts geändert. Nicht dauerhaft
                // blockieren: auf die nächste Monitoränderung warten und dann
                // automatisch erneut versuchen.
                blockReason = nil
                setLifecycle(.waiting)
                setStatus(
                    "Warte auf den virtuellen Quellmonitor „\(VirtualSource.name)“ …",
                    isError: false
                )
            } else if resolvedTarget != nil {
                blockReason = .capture
                setLifecycle(.blocked)
                setStatus(
                    "Start fehlgeschlagen: \(startError.localizedDescription) Erneut mit „Ausgabe starten“ versuchen.",
                    isError: true
                )
            } else {
                blockReason = nil
                setLifecycle(.waiting)
                setStatus(waitingStatusText, isError: false)
            }
        }
    }

    private func stopCommittedOutput(
        message: String,
        isError: Bool
    ) async {
        if lifecycle == .stopping {
            await withCheckedContinuation { continuation in
                stopWaiters.append(continuation)
            }
            return
        }

        operationEpoch &+= 1
        let sessions = [captureSession, startingCaptureSession].compactMap {
            $0
        }
        let outputs = [outputController, startingOutputController].compactMap {
            $0
        }
        captureSession = nil
        outputController = nil
        startingCaptureSession = nil
        startingOutputController = nil
        activeSnapshot = nil
        pendingCaptureStop = nil
        pendingRenderingFailure = nil
        setLifecycle(.stopping)
        var closedOutput: OutputWindowController?
        for output in outputs
            where closedOutput == nil || closedOutput !== output {
            output.close()
            closedOutput = output
        }

        var stopError: (any Error)?
        var stoppedSession: CaptureSession?
        for session in sessions
            where stoppedSession == nil || stoppedSession !== session {
            do {
                try await session.stop()
            } catch {
                if stopError == nil {
                    stopError = error
                }
            }
            stoppedSession = session
        }
        ControlWindowCoordinator.restoreNormalLevels()

        if blockReason != nil {
            setLifecycle(.blocked)
            setStatus(message, isError: isError)
        } else if desiredOutput, !manualStopSuppressed {
            setLifecycle(.idle)
            if let stopError {
                setStatus(
                    "\(message) Freigabe meldete: \(stopError.localizedDescription)",
                    isError: true
                )
            } else {
                setStatus(message, isError: isError)
            }
            await reconcileOutput()
        } else {
            setLifecycle(.idle)
            if let stopError, !isError {
                setStatus(
                    "\(message) Freigabe meldete: \(stopError.localizedDescription)",
                    isError: true
                )
            } else {
                setStatus(message, isError: isError)
            }
        }
        finishStopWaiters()
    }

    private func finishStopWaiters() {
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func captureStoppedUnexpectedly(
        epoch: UInt64,
        message: String
    ) {
        guard epoch == operationEpoch else {
            return
        }
        if lifecycle == .starting(epoch) {
            pendingCaptureStop = (epoch, message)
            return
        }
        guard lifecycle == .running else {
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, epoch == operationEpoch else {
                return
            }
            refreshDisplaySnapshot()
            if sourceKind == .window {
                // A closed or hidden window ends the stream; re-enumerate so a
                // reopened window can be picked up instead of hard-blocking.
                windows = await DisplayCatalog.availableWindows()
                selectedSourceWindowID = DisplayCatalog.resolve(
                    workingSource.window,
                    among: windows
                )?.id
            }
            guard epoch == operationEpoch else {
                return
            }
            if resolvedTarget != nil, resolvedSourceIsAvailable {
                blockReason = .capture
                await stopCommittedOutput(
                    message: "Die Bildschirmaufnahme wurde beendet: \(message) Erneut mit „Ausgabe starten“ versuchen.",
                    isError: true
                )
            } else {
                blockReason = nil
                await stopCommittedOutput(
                    message: waitingStatusText,
                    isError: false
                )
            }
        }
    }

    private func renderingFailed(
        epoch: UInt64,
        message: String
    ) {
        guard epoch == operationEpoch else {
            return
        }
        if lifecycle == .starting(epoch) {
            pendingRenderingFailure = (epoch, message)
            return
        }
        guard lifecycle == .running else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self, epoch == operationEpoch else {
                return
            }
            blockReason = .capture
            await stopCommittedOutput(
                message: "Die Bildausgabe ist fehlgeschlagen: \(message) Erneut mit „Ausgabe starten“ versuchen.",
                isError: true
            )
        }
    }

    private func firstFrameWasRendered(
        epoch: UInt64,
        path: RenderingPath
    ) {
        guard epoch == operationEpoch, lifecycle == .running else {
            return
        }
        if isSelfTest {
            selfTestRenderedFrame = true
            selfTestTimeoutTask?.cancel()
            selfTestTimeoutTask = nil
            finishSelfTest(
                "SELF_TEST_PASS: \(path.rawValue) hat einen Frame des virtuellen Quellmonitors auf dem Zielmonitor dargestellt.",
                isError: false
            )
            return
        }
        setStatus(
            "Ausgabe läuft (\(path.rawValue)). Stoppen über Statusmenü, Steuerfenster oder ⌘.",
            isError: false
        )
    }

    private func finishSelfTest(_ message: String, isError: Bool) {
        setStatus(message, isError: isError)
        NSLog("%@", message)
        if isError {
            lifecycleLogger.error("\(message, privacy: .public)")
        } else {
            lifecycleLogger.notice("\(message, privacy: .public)")
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if isRunning || isBusy {
                requestStop(message: message)
                try? await Task.sleep(for: .milliseconds(500))
            }
            // Trigger termination from a CFRunLoop timer callout rather than
            // from any dispatch-queue context. -[NSApplication terminate:]
            // returns .terminateLater (see AppDelegate.applicationShouldTerminate)
            // and then spins a *nested* run loop until the async reply arrives.
            // That reply is delivered by a `Task { @MainActor }` whose job runs
            // on the main dispatch queue. If terminate: is invoked from within a
            // main-queue drain (a Swift Task job *or* a DispatchQueue.main.async
            // block are both such contexts), libdispatch will not re-enter the
            // main-queue drain from the nested run loop, so the reply job can
            // never run and the app hangs. A Timer callout fires as a top-level
            // run-loop event — *outside* any queue drain — so the nested run
            // loop is free to service the main dispatch queue and complete the
            // reply. (This is why the normal Quit menu path, an AppKit event
            // callout, has never hung.) Scheduled in .common modes so it still
            // fires while a tracking run-loop mode is active.
            let terminateTimer = Timer(timeInterval: 0, repeats: false) { _ in
                MainActor.assumeIsolated {
                    NSApplication.shared.terminate(nil)
                }
            }
            RunLoop.main.add(terminateTimer, forMode: .common)
        }
    }

    private var waitingStatusText: String {
        guard let workingTargetIdentity else {
            return "Es ist noch kein Zielmonitor ausgewählt."
        }
        if selectedDisplayID == nil {
            return "Warte ruhig auf den gespeicherten Zielmonitor „\(workingTargetIdentity.localizedName)“ …"
        }
        switch sourceKind {
        case .virtualDisplay:
            return "Warte auf den virtuellen Quellmonitor „\(VirtualSource.name)“ …"
        case .display:
            guard let identity = workingSource.display else {
                return "Es ist noch kein Quellmonitor ausgewählt."
            }
            return "Warte ruhig auf den gespeicherten Quellmonitor „\(identity.localizedName)“ …"
        case .window:
            guard let identity = workingSource.window else {
                return "Es ist noch kein Quellfenster ausgewählt."
            }
            return "Warte ruhig auf das Fenster „\(identity.localizedName)“ …"
        }
    }

    /// Transient start failures where the source is not yet online or ready for
    /// capture (e.g. right after creating the virtual display during login
    /// autostart) or the display configuration changed mid-start. These
    /// self-heal on the next screen-parameters change, so we wait and retry
    /// instead of hard-blocking.
    private func isTransientSourceStartError(_ error: Error) -> Bool {
        guard let error = error as? DisplayResolutionError else {
            return false
        }
        switch error {
        case .virtualSourceUnavailable,
             .sourceDisplayUnavailable,
             .sourceWindowUnavailable,
             .configurationChanged:
            return true
        case .sourceIsTarget,
             .screenCaptureSourceUnavailable,
             .targetDisplayUnavailable:
            return false
        }
    }

    private func invalidateStartIfNeeded() {
        if case .starting = lifecycle {
            operationEpoch &+= 1
        }
    }

    private func setLifecycle(_ newValue: Lifecycle) {
        lifecycle = newValue
        isRunning = newValue == .running
        switch newValue {
        case .starting, .stopping:
            isBusy = true
        case .idle, .waiting, .running, .blocked:
            isBusy = false
        }
    }

    private func updateIdleStatus() {
        guard lifecycle == .idle || lifecycle == .waiting else {
            return
        }
        if displays.isEmpty {
            setStatus(
                "Kein physischer Zielmonitor erkannt.",
                isError: false
            )
        } else if !permissionGranted {
            setStatus(
                "Bildschirmaufnahme ist noch nicht erlaubt.",
                isError: true
            )
        } else if workingTargetIdentity == nil {
            setStatus(
                "Einen Zielmonitor für die Ausgabe auswählen.",
                isError: false
            )
        } else if selectedDisplayID == nil {
            setStatus(waitingStatusText, isError: false)
        } else if !workingSource.isComplete || !resolvedSourceIsAvailable {
            setStatus(waitingStatusText, isError: false)
        } else {
            setStatus(
                "Bereit: \(sourceSummary) → \(resolvedTarget?.name ?? "Zielmonitor").",
                isError: false
            )
        }
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusText = text
        statusIsError = isError
    }

    @objc
    private func screenParametersDidChange(_ notification: Notification) {
        displayChangeTask?.cancel()
        displayChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else {
                return
            }
            refreshDisplaySnapshot()
            outputController?.refreshWindowLevel()
            await reconcileOutput()
        }
    }

    @objc
    private func applicationDidBecomeActive(_ notification: Notification) {
        updatePermissionStatus()
        refreshLoginItemStatus()
    }
}

@MainActor
enum ControlWindowCoordinator {
    static func prepareForOutput(
        targetScreen: NSScreen,
        virtualDisplayID: CGDirectDisplayID?
    ) {
        guard let controlWindow = controlWindow else {
            return
        }

        // Prefer a physical screen that is neither the output target nor the
        // (invisible) virtual source, so the control window stays visible.
        let destination = NSScreen.screens.first(where: {
            $0.displayID != targetScreen.displayID
                && $0.displayID != virtualDisplayID
        }) ?? targetScreen
        controlWindow.level = .normal
        controlWindow.setFrame(
            clampedFrame(
                controlWindow.frame,
                within: destination.visibleFrame,
                centerIfOutside: controlWindow.screen?.displayID
                    != destination.displayID
            ),
            display: true
        )
        NSApplication.shared.activate(ignoringOtherApps: true)
        controlWindow.makeKeyAndOrderFront(nil)
    }

    static func showControls() {
        guard let controlWindow else {
            return
        }
        if let screen = controlWindow.screen {
            controlWindow.setFrame(
                clampedFrame(
                    controlWindow.frame,
                    within: screen.visibleFrame,
                    centerIfOutside: false
                ),
                display: true
            )
        }
        controlWindow.level = .floating
        NSApplication.shared.activate(ignoringOtherApps: true)
        controlWindow.makeKeyAndOrderFront(nil)
    }

    static func restoreNormalLevels() {
        for window in NSApplication.shared.windows where isControlWindow(window) {
            window.level = .normal
        }
    }

    private static var controlWindow: NSWindow? {
        NSApplication.shared.keyWindow.flatMap {
            isControlWindow($0) ? $0 : nil
        } ?? NSApplication.shared.windows.first(where: isControlWindow)
    }

    private static func isControlWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
            && window.canBecomeMain
    }

    private static func clampedFrame(
        _ frame: NSRect,
        within visibleFrame: NSRect,
        centerIfOutside: Bool
    ) -> NSRect {
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        var origin = frame.origin

        if centerIfOutside || !visibleFrame.intersects(frame) {
            origin = NSPoint(
                x: visibleFrame.midX - width / 2,
                y: visibleFrame.midY - height / 2
            )
        }
        origin.x = min(
            max(origin.x, visibleFrame.minX),
            visibleFrame.maxX - width
        )
        origin.y = min(
            max(origin.y, visibleFrame.minY),
            visibleFrame.maxY - height
        )
        return NSRect(
            origin: origin,
            size: NSSize(width: width, height: height)
        )
    }
}
