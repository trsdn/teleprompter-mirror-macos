import AppKit
import SwiftUI

@MainActor
final class AppStatusItemController: NSObject, NSMenuDelegate {
    private weak var model: AppModel?
    private var showControlsHandler: (() -> Void)?
    private let statusItem: NSStatusItem
    private let startItem: NSMenuItem
    private let stopItem: NSMenuItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        startItem = NSMenuItem(
            title: "Start output",
            action: #selector(startOutput),
            keyEquivalent: ""
        )
        stopItem = NSMenuItem(
            title: "Stop output",
            action: #selector(stopOutput),
            keyEquivalent: "."
        )
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.on.rectangle.angled",
            accessibilityDescription: "Teleprompter Mirror"
        )
        statusItem.button?.toolTip = "Teleprompter Mirror"

        startItem.target = self
        stopItem.target = self
        stopItem.keyEquivalentModifierMask = [.command]

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())

        let showItem = NSMenuItem(
            title: "Show control window",
            action: #selector(showControls),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Teleprompter Mirror",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func configure(
        model: AppModel,
        showControls: @escaping () -> Void
    ) {
        self.model = model
        showControlsHandler = showControls
    }

    func menuWillOpen(_ menu: NSMenu) {
        startItem.isEnabled = model?.canStart == true
        stopItem.isEnabled = model?.canStop == true
    }

    @objc
    private func startOutput() {
        Task { @MainActor [weak self] in
            await self?.model?.start()
        }
    }

    @objc
    private func stopOutput() {
        model?.requestStop(message: "Output stopped from the status menu.")
    }

    @objc
    private func showControls() {
        showControlsHandler?()
    }

    @objc
    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationPending = false
    private let statusItemController = AppStatusItemController()
    private var showControlsHandler: (() -> Void)?

    func configure(
        model: AppModel,
        showControls: @escaping () -> Void
    ) {
        self.model = model
        showControlsHandler = showControls
        statusItemController.configure(
            model: model,
            showControls: showControls
        )
    }

    func showControls() {
        showControlsHandler?()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            showControls()
        }
        return true
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        if terminationPending {
            return .terminateLater
        }
        guard let model else {
            return .terminateNow
        }
        terminationPending = true
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.prepareForTermination()
    }
}

@MainActor
struct TeleprompterMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @StateObject
    private var model = AppModel()

    var body: some Scene {
        Window("Teleprompter Mirror", id: "controls") {
            ControlRootView(
                model: model,
                configure: { showControls in
                    appDelegate.configure(
                        model: model,
                        showControls: showControls
                    )
                    model.appDidLaunch()
                }
            )
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Output") {
                Button("Start output") {
                    Task { @MainActor in
                        await model.start()
                    }
                }
                .disabled(!model.canStart)

                Button("Stop output") {
                    model.requestStop()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!model.canStop)

                Divider()

                Button("Show control window") {
                    appDelegate.showControls()
                }

                Button("Refresh displays") {
                    model.refreshDisplays()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isBusy)
            }
        }
    }
}

private struct ControlRootView: View {
    @ObservedObject var model: AppModel
    let configure: (@escaping () -> Void) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ControlView(model: model) {
            configure {
                openWindow(id: "controls")
                DispatchQueue.main.async {
                    model.showControls()
                }
            }
        }
    }
}
