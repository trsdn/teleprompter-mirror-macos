import CoreGraphics
import SwiftUI
import TeleprompterCore

/// A titled block of related controls. Keeps the window scannable without
/// relying on the heavier platform `GroupBox` chrome.
private struct ControlSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

/// Live illustration of what rotation and mirroring do to the source image,
/// so the correct teleprompter orientation can be found without guessing.
private struct OrientationPreview: View {
    let transform: DisplayTransform

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.black)
            Text("Fg")
                .font(.system(size: 26, weight: .bold, design: .serif))
                .foregroundStyle(.white)
                .scaleEffect(
                    x: transform.mirrorHorizontally ? -1 : 1,
                    y: transform.mirrorVertically ? -1 : 1
                )
                .rotationEffect(.degrees(Double(transform.rotation.rawValue)))
        }
        .frame(width: 74, height: 52)
        .accessibilityLabel("Vorschau der Ausrichtung")
    }
}

struct ControlView: View {
    @ObservedObject var model: AppModel
    let onAppear: () -> Void

    private var sourceKindBinding: Binding<CaptureSourceKind> {
        Binding(
            get: { model.sourceKind },
            set: { model.selectSourceKind($0) }
        )
    }

    private var sourceDisplayBinding: Binding<CGDirectDisplayID?> {
        Binding(
            get: { model.selectedSourceDisplayID },
            set: { model.selectSourceDisplay($0) }
        )
    }

    private var sourceWindowBinding: Binding<CGWindowID?> {
        Binding(
            get: { model.selectedSourceWindowID },
            set: { model.selectSourceWindow($0) }
        )
    }

    private var displayBinding: Binding<CGDirectDisplayID?> {
        Binding(
            get: { model.selectedDisplayID },
            set: { model.selectDisplay($0) }
        )
    }

    private var rotationBinding: Binding<DisplayRotation> {
        Binding(
            get: { model.transform.rotation },
            set: { rotation in
                var value = model.transform
                value.rotation = rotation
                model.setTransform(value)
            }
        )
    }

    private var horizontalMirrorBinding: Binding<Bool> {
        Binding(
            get: { model.transform.mirrorHorizontally },
            set: { enabled in
                var value = model.transform
                value.mirrorHorizontally = enabled
                model.setTransform(value)
            }
        )
    }

    private var verticalMirrorBinding: Binding<Bool> {
        Binding(
            get: { model.transform.mirrorVertically },
            set: { enabled in
                var value = model.transform
                value.mirrorVertically = enabled
                model.setTransform(value)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sourceSection
            targetSection
            orientationSection
            startupSection
            statusSection
            actionBar
        }
        .padding(16)
        .frame(width: 560)
        .onAppear(perform: onAppear)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Teleprompter Mirror")
                    .font(.headline)
                Text("Monitor, Fenster oder virtuellen Monitor gedreht und gespiegelt ausgeben")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            runningBadge
        }
    }

    @ViewBuilder
    private var runningBadge: some View {
        if model.isRunning {
            Label("Ausgabe läuft", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.green.opacity(0.18)))
                .foregroundStyle(.green)
        }
    }

    private var sourceSection: some View {
        ControlSection(title: "Quelle", systemImage: "square.on.square.dashed") {
            Picker("Quelle", selection: sourceKindBinding) {
                ForEach(CaptureSourceKind.allCases, id: \.rawValue) { kind in
                    Text(kind.localizedName).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(model.isBusy)

            switch model.sourceKind {
            case .virtualDisplay:
                Text("Erzeugt einen unsichtbaren Monitor „\(model.virtualSourceName)“. Fenster müssen blind dorthin verschoben werden; sichtbar wird er nur als gespiegeltes Bild auf dem Zielmonitor.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    model.openDisplaySettings()
                } label: {
                    Label(
                        "Anordnung in den Bildschirmeinstellungen …",
                        systemImage: "arrow.up.forward.app"
                    )
                    .font(.caption)
                }
                .buttonStyle(.link)
                .help("Dort lässt sich festlegen, an welcher Kante der unsichtbare Monitor liegt und wohin die Maus ihn verlässt.")
            case .display:
                Picker("Quellmonitor", selection: sourceDisplayBinding) {
                    Text("Bitte auswählen")
                        .tag(nil as CGDirectDisplayID?)
                    ForEach(model.sourceDisplays) { display in
                        Text(display.label)
                            .tag(display.id as CGDirectDisplayID?)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(model.isRunning || model.isBusy)

                Text("Spiegelt einen sichtbaren Monitor. Quelle und Ziel dürfen nicht derselbe Monitor sein.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .window:
                HStack {
                    Picker("Quellfenster", selection: sourceWindowBinding) {
                        Text("Bitte auswählen")
                            .tag(nil as CGWindowID?)
                        ForEach(model.windows) { window in
                            Text(window.label)
                                .tag(window.id as CGWindowID?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(model.isRunning || model.isBusy)

                    Button {
                        model.refreshWindows()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshingWindows)
                    .help("Fensterliste aktualisieren")

                    if model.isRefreshingWindows {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }

                Text("Spiegelt genau ein Fenster, zum Beispiel die Sprecheransicht. Alles bleibt sichtbar und normal bedienbar.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var targetSection: some View {
        ControlSection(title: "Zielmonitor", systemImage: "display") {
            Picker("Zielmonitor", selection: displayBinding) {
                Text("Bitte auswählen")
                    .tag(nil as CGDirectDisplayID?)
                ForEach(model.displays) { display in
                    Text(display.label)
                        .tag(display.id as CGDirectDisplayID?)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.isRunning || model.isBusy)

            if let hint = model.displayConnectionHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let notice = model.singleDisplayNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var orientationSection: some View {
        ControlSection(
            title: "Ausrichtung",
            systemImage: "arrow.triangle.2.circlepath"
        ) {
            HStack(alignment: .center, spacing: 14) {
                OrientationPreview(transform: model.transform)

                VStack(alignment: .leading, spacing: 8) {
                    Picker("Drehung", selection: rotationBinding) {
                        ForEach(DisplayRotation.allCases, id: \.rawValue) {
                            rotation in
                            Text("\(rotation.rawValue)°").tag(rotation)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    HStack(spacing: 16) {
                        Toggle(
                            "Horizontal spiegeln",
                            isOn: horizontalMirrorBinding
                        )
                        Toggle(
                            "Vertikal spiegeln",
                            isOn: verticalMirrorBinding
                        )
                        Spacer()
                        Button("Standard") {
                            model.resetTransform()
                        }
                        .controlSize(.small)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var startupSection: some View {
        ControlSection(title: "Start", systemImage: "power") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    "Ausgabe beim App-Start automatisch starten",
                    isOn: Binding(
                        get: { model.autoStartOutput },
                        set: { model.setAutoStartOutput($0) }
                    )
                )

                HStack {
                    Toggle(
                        "Bei Anmeldung starten",
                        isOn: Binding(
                            get: { model.loginItemEnabled },
                            set: { model.setLoginItemEnabled($0) }
                        )
                    )
                    .disabled(model.loginItemBusy)
                    if model.loginItemBusy {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    if model.loginItemNeedsApproval {
                        Button("Systemeinstellungen öffnen") {
                            model.openLoginItemsSettings()
                        }
                        .controlSize(.small)
                    }
                }

                Text(model.loginItemStatusText)
                    .font(.caption2)
                    .foregroundStyle(
                        model.loginItemStatusIsError ? .red : .secondary
                    )

                if !model.appIsInApplicationsFolder {
                    Text(
                        "Für einen zuverlässigen Anmeldestart die signierte App nach /Applications verschieben und dort registrieren."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(
                    systemName: model.statusIsError
                        ? "exclamationmark.circle.fill"
                        : "info.circle.fill"
                )
                .foregroundStyle(model.statusIsError ? .red : .secondary)

                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(
                        model.statusIsError ? .red : .secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.permissionGranted {
                HStack {
                    Button("Zugriff anfordern") {
                        model.requestPermission()
                    }
                    Button("Systemeinstellungen öffnen") {
                        model.openScreenRecordingSettings()
                    }
                    Spacer()
                    Button("Status prüfen") {
                        model.updatePermissionStatus()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Button {
                model.refreshDisplays()
            } label: {
                Label("Aktualisieren", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy)

            Spacer()

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            if model.isRunning || model.isBusy {
                Button("Stoppen", role: .destructive) {
                    model.requestStop()
                }
                .keyboardShortcut(.cancelAction)
            } else {
                Button("Ausgabe starten") {
                    Task { @MainActor in
                        await model.start()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }
        }
    }
}
