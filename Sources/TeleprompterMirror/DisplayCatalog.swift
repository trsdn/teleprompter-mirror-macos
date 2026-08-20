import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import TeleprompterCore

struct DisplayDescriptor: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let frame: CGRect
    let identity: PersistentDisplayIdentity

    var label: String {
        "\(name) — \(pixelWidth)×\(pixelHeight)"
    }
}

/// An on-screen window that can be mirrored. `id` is a per-launch handle and
/// is never persisted; `identity` is the durable form.
struct WindowDescriptor: Identifiable, Hashable, Sendable {
    let id: CGWindowID
    let applicationName: String
    let bundleIdentifier: String?
    let title: String?
    let pixelWidth: Int
    let pixelHeight: Int
    let identity: WindowIdentity

    var label: String {
        "\(identity.localizedName) — \(pixelWidth)×\(pixelHeight)"
    }
}

/// The validated capture source behind a running session.
@MainActor
enum ResolvedCaptureSource {
    case display(SCDisplay, CGDirectDisplayID)
    case window(SCWindow)
}

/// An immutable, validated pairing of a capture source and the physical output
/// target. The target is always a physical `NSScreen` that shows the
/// transformed image; the source is the virtual display, another physical
/// display, or a single window.
@MainActor
struct ResolvedCaptureSnapshot {
    let source: ResolvedCaptureSource
    let sourceKind: CaptureSourceKind
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceLabel: String
    let targetDescriptor: DisplayDescriptor
    let targetScreen: NSScreen
    /// This app's running instances, excluded when a physical display is the
    /// source so the control window never appears in the mirrored image.
    var excludedApplications: [SCRunningApplication] = []

    var sourceDisplayID: CGDirectDisplayID? {
        if case let .display(_, displayID) = source {
            return displayID
        }
        return nil
    }
}

enum DisplayResolutionError: LocalizedError {
    case virtualSourceUnavailable
    case sourceDisplayUnavailable
    case sourceWindowUnavailable
    case sourceIsTarget
    case screenCaptureSourceUnavailable(CGDirectDisplayID)
    case targetDisplayUnavailable
    case configurationChanged

    var errorDescription: String? {
        switch self {
        case .virtualSourceUnavailable:
            return "The virtual source display is not available for screen capture."
        case .sourceDisplayUnavailable:
            return "The selected source display is not unambiguously connected."
        case .sourceWindowUnavailable:
            return "The selected source window is not unambiguously open."
        case .sourceIsTarget:
            return "Source and target must not be the same display, otherwise an optical feedback loop occurs."
        case let .screenCaptureSourceUnavailable(displayID):
            return "ScreenCaptureKit did not find the source display with ID \(displayID)."
        case .targetDisplayUnavailable:
            return "The selected target display is not unambiguously connected."
        case .configurationChanged:
            return "The display configuration changed while starting up."
        }
    }
}

@MainActor
enum DisplayCatalog {
    /// Physical displays eligible as output targets. The virtual source is
    /// never listed, so the user can never mirror the source onto itself.
    static func connectedDisplays(
        excluding excludedID: CGDirectDisplayID?
    ) -> [DisplayDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID,
                  displayID != excludedID,
                  CGDisplayVendorNumber(displayID) != 0x544D else {
                return nil
            }

            let currentMode = CGDisplayCopyDisplayMode(displayID)
            let nativeMode =
                (CGDisplayCopyAllDisplayModes(displayID, nil)
                    as? [CGDisplayMode])?
                    .max {
                        ($0.pixelWidth * $0.pixelHeight)
                            < ($1.pixelWidth * $1.pixelHeight)
                    }
            let nativeWidth = nativeMode?.pixelWidth
                ?? currentMode?.pixelWidth
                ?? CGDisplayPixelsWide(displayID)
            let nativeHeight = nativeMode?.pixelHeight
                ?? currentMode?.pixelHeight
                ?? CGDisplayPixelsHigh(displayID)

            return DisplayDescriptor(
                id: displayID,
                name: screen.localizedName,
                pixelWidth: CGDisplayPixelsWide(displayID),
                pixelHeight: CGDisplayPixelsHigh(displayID),
                frame: screen.frame,
                identity: PersistentDisplayIdentity(
                    vendorID: CGDisplayVendorNumber(displayID),
                    productID: CGDisplayModelNumber(displayID),
                    serialNumber: CGDisplaySerialNumber(displayID),
                    displayUUID: displayUUID(for: displayID),
                    localizedName: screen.localizedName,
                    nativePixelWidth: nativeWidth,
                    nativePixelHeight: nativeHeight
                )
            )
        }
        .sorted {
            if $0.name == $1.name {
                return $0.id < $1.id
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func resolve(
        _ identity: PersistentDisplayIdentity?,
        among displays: [DisplayDescriptor]
    ) -> DisplayDescriptor? {
        guard let identity,
              let index = DisplayIdentityMatcher.uniqueMatch(
                for: identity,
                among: displays.map(\.identity)
              ) else {
            return nil
        }
        return displays[index]
    }

    static func resolve(
        _ identity: WindowIdentity?,
        among windows: [WindowDescriptor]
    ) -> WindowDescriptor? {
        guard let identity,
              let index = WindowIdentityMatcher.uniqueMatch(
                for: identity,
                among: windows.map(\.identity)
              ) else {
            return nil
        }
        return windows[index]
    }

    /// On-screen windows that are large enough to mirror, excluding this app's
    /// own windows so the output can never capture itself.
    static func availableWindows() async -> [WindowDescriptor] {
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            NSLog(
                "Could not determine the window list: %@",
                error.localizedDescription
            )
            return []
        }

        return content.windows.compactMap { window -> WindowDescriptor? in
            let application = window.owningApplication
            guard let application,
                  application.processID != ownProcessID,
                  application.bundleIdentifier != ownBundleID else {
                return nil
            }
            let width = Int(window.frame.width.rounded())
            let height = Int(window.frame.height.rounded())
            guard width >= 120, height >= 120 else {
                return nil
            }
            let title = window.title?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return WindowDescriptor(
                id: window.windowID,
                applicationName: application.applicationName,
                bundleIdentifier: application.bundleIdentifier,
                title: title?.isEmpty == true ? nil : title,
                pixelWidth: width,
                pixelHeight: height,
                identity: WindowIdentity(
                    bundleIdentifier: application.bundleIdentifier,
                    applicationName: application.applicationName,
                    title: title
                )
            )
        }
        .sorted {
            if $0.applicationName == $1.applicationName {
                return ($0.title ?? "").localizedStandardCompare($1.title ?? "")
                    == .orderedAscending
            }
            return $0.applicationName
                .localizedStandardCompare($1.applicationName)
                == .orderedAscending
        }
    }

    /// Fallback target when no saved target resolves: the display named
    /// `preferredName` (AAA) if present, otherwise the smallest external
    /// display, otherwise the smallest connected display.
    static func defaultTarget(
        among displays: [DisplayDescriptor],
        preferredName: String
    ) -> DisplayDescriptor? {
        if let named = displays.first(where: {
            $0.name.compare(
                preferredName,
                options: [.caseInsensitive]
            ) == .orderedSame
        }) {
            return named
        }

        let externals = displays.filter { CGDisplayIsBuiltin($0.id) == 0 }
        let pool = externals.isEmpty ? displays : externals
        return pool.min {
            ($0.pixelWidth * $0.pixelHeight)
                < ($1.pixelWidth * $1.pixelHeight)
        }
    }

    static func makeVirtualSourceSnapshot(
        virtualDisplayID: CGDirectDisplayID,
        sourceWidth: Int,
        sourceHeight: Int,
        target: DisplayDescriptor
    ) async throws -> ResolvedCaptureSnapshot {
        guard onlineDisplayIDs().contains(virtualDisplayID) else {
            throw DisplayResolutionError.virtualSourceUnavailable
        }
        let captureDisplay = try await screenCaptureDisplay(
            matching: virtualDisplayID
        )
        // On macOS 26 a newly published CGVirtualDisplay can already appear in
        // SCShareableContent while its capture framebuffer is not ready yet.
        // Starting SCStream in that interval succeeds but never emits frames.
        try await Task.sleep(for: .seconds(5))

        return ResolvedCaptureSnapshot(
            source: .display(captureDisplay, virtualDisplayID),
            sourceKind: .virtualDisplay,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceLabel: VirtualSource.name,
            targetDescriptor: target,
            targetScreen: try targetScreen(for: target)
        )
    }

    static func makeDisplaySourceSnapshot(
        source: DisplayDescriptor,
        target: DisplayDescriptor
    ) async throws -> ResolvedCaptureSnapshot {
        guard source.id != target.id else {
            throw DisplayResolutionError.sourceIsTarget
        }
        guard onlineDisplayIDs().contains(source.id) else {
            throw DisplayResolutionError.sourceDisplayUnavailable
        }
        let captureDisplay = try await screenCaptureDisplay(
            matching: source.id
        )
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let ownApplications = (
            try? await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            ).applications.filter { $0.processID == ownProcessID }
        ) ?? []

        return ResolvedCaptureSnapshot(
            source: .display(captureDisplay, source.id),
            sourceKind: .display,
            sourceWidth: source.pixelWidth,
            sourceHeight: source.pixelHeight,
            sourceLabel: source.name,
            targetDescriptor: target,
            targetScreen: try targetScreen(for: target),
            excludedApplications: ownApplications
        )
    }

    static func makeWindowSourceSnapshot(
        source: WindowDescriptor,
        target: DisplayDescriptor
    ) async throws -> ResolvedCaptureSnapshot {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            throw DisplayResolutionError.sourceWindowUnavailable
        }
        guard let window = content.windows.first(where: {
            $0.windowID == source.id
        }) else {
            throw DisplayResolutionError.sourceWindowUnavailable
        }

        return ResolvedCaptureSnapshot(
            source: .window(window),
            sourceKind: .window,
            sourceWidth: max(1, Int(window.frame.width.rounded())),
            sourceHeight: max(1, Int(window.frame.height.rounded())),
            sourceLabel: source.identity.localizedName,
            targetDescriptor: target,
            targetScreen: try targetScreen(for: target)
        )
    }

    static func revalidate(
        _ snapshot: ResolvedCaptureSnapshot,
        virtualDisplayID: CGDirectDisplayID?
    ) throws {
        if snapshot.sourceKind == .virtualDisplay {
            guard let virtualDisplayID,
                  snapshot.sourceDisplayID == virtualDisplayID,
                  onlineDisplayIDs().contains(virtualDisplayID) else {
                throw DisplayResolutionError.virtualSourceUnavailable
            }
        } else if let sourceDisplayID = snapshot.sourceDisplayID {
            guard onlineDisplayIDs().contains(sourceDisplayID) else {
                throw DisplayResolutionError.sourceDisplayUnavailable
            }
        }

        let physical = connectedDisplays(excluding: virtualDisplayID)
        guard let current = physical.first(where: {
            $0.id == snapshot.targetDescriptor.id
        }),
        current.pixelWidth == snapshot.targetDescriptor.pixelWidth,
        current.pixelHeight == snapshot.targetDescriptor.pixelHeight,
        current.frame == snapshot.targetDescriptor.frame else {
            throw DisplayResolutionError.configurationChanged
        }
    }

    private static func targetScreen(
        for target: DisplayDescriptor
    ) throws -> NSScreen {
        guard let screen = NSScreen.screens.first(where: {
            $0.displayID == target.id
        }) else {
            throw DisplayResolutionError.targetDisplayUnavailable
        }
        return screen
    }

    /// The set of currently online `CGDirectDisplayID`s, including the private
    /// virtual source. Empty when the list cannot be queried.
    private static func onlineDisplayIDs() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actual: UInt32 = 0
        guard CGGetOnlineDisplayList(count, &ids, &actual) == .success else {
            return []
        }
        return Set(ids.prefix(Int(actual)))
    }

    /// Resolves only the retained virtual display's live ID. Newly created
    /// virtual displays can take a short time to appear in ScreenCaptureKit,
    /// so enumeration is retried briefly but never falls back to a name,
    /// position, or another display.
    private static func screenCaptureDisplay(
        matching displayID: CGDirectDisplayID
    ) async throws -> SCDisplay {
        let maximumAttempts = 8
        var lastEnumerationError: (any Error)?

        for attempt in 1...maximumAttempts {
            do {
                let content =
                    try await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: false
                    )
                if let display = content.displays.first(where: {
                    $0.displayID == displayID
                }) {
                    return display
                }
                lastEnumerationError = nil
            } catch {
                lastEnumerationError = error
            }

            if attempt < maximumAttempts {
                try await Task.sleep(for: .milliseconds(125))
            }
        }

        if let lastEnumerationError {
            NSLog(
                "ScreenCaptureKit enumeration failed for display %u: %@",
                displayID,
                lastEnumerationError.localizedDescription
            )
        }
        throw DisplayResolutionError.screenCaptureSourceUnavailable(displayID)
    }

    private static func displayUUID(
        for displayID: CGDirectDisplayID
    ) -> String? {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID)
        else {
            return nil
        }
        let uuid = unmanagedUUID.takeRetainedValue()
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
