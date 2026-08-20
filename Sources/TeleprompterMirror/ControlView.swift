import CoreGraphics
import SwiftUI
import TeleprompterCore

struct ControlView: View {
    @ObservedObject var model: AppModel
    let onAppear: () -> Void

    private var displayBinding: Binding<CGDirectDisplayID?> {
        Binding(
            get: { model.selectedDisplayID },
            set: { model.selectDisplay($0) }
        )
    }

    private var presetBinding: Binding<Int> {
        Binding(
            get: { model.activePresetIndex },
            set: { model.selectPreset($0) }
        )
    }

    private var presetNameBinding: Binding<String> {
        Binding(
            get: { model.activePresetName },
            set: { model.renameActivePreset($0) }
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
            HStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Teleprompter Mirror")
                        .font(.headline)
                    Text("Virtuellen Quellmonitor gespiegelt auf den Zielmonitor ausgeben")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Picker("Preset", selection: presetBinding) {
                    ForEach(Array(model.presets.enumerated()), id: \.offset) {
                        index, preset in
                        Text(preset.name.isEmpty
                            ? "Preset \(index + 1)"
                            : preset.name)
                            .tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isBusy)

                HStack {
                    TextField("Preset-Name", text: presetNameBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("Neu laden") {
                        model.reloadActivePreset()
                    }
                    .disabled(model.isBusy)
                    Button("Preset speichern") {
                        model.saveCurrentConfigurationToActivePreset()
                    }
                    .disabled(!model.canSavePreset)
                }
                .controlSize(.small)

                if model.configurationIsDirty {
                    Label(
                        "Ungespeicherte Änderungen",
                        systemImage: "circle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Zielmonitor für die Ausgabe")
                    .font(.subheadline.weight(.semibold))

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

                Text("Quelle ist der virtuelle Monitor „Teleprompter Source“. Präsentation bzw. Fenster dorthin verschieben.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

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

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Drehung")
                        .font(.subheadline.weight(.semibold))
                    Picker("Drehung", selection: rotationBinding) {
                        ForEach(DisplayRotation.allCases, id: \.rawValue) {
                            rotation in
                            Text("\(rotation.rawValue)°").tag(rotation)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                HStack(spacing: 18) {
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

            HStack {
                Button {
                    model.refreshDisplays()
                } label: {
                    Label("Monitore aktualisieren", systemImage: "arrow.clockwise")
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
        .padding(18)
        .frame(width: 610)
        .onAppear(perform: onAppear)
    }
}
