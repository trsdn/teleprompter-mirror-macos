import AppKit
import TeleprompterCore

@MainActor
final class PassiveOutputWindow: NSWindow {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

@MainActor
final class OutputWindowController {
    let frameReceiver: FrameReceiver

    private let window: PassiveOutputWindow
    private let renderer: FrameRenderer
    private var isClosed = false
    private var isVisible = false

    init(
        snapshot: ResolvedCaptureSnapshot,
        transform: DisplayTransform,
        onFirstFrame: ((RenderingPath) -> Void)? = nil,
        onFailure: ((String) -> Void)? = nil
    ) throws {
        let window = PassiveOutputWindow(
            contentRect: snapshot.targetScreen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: snapshot.targetScreen
        )
        let outputView = NSView(
            frame: NSRect(
                origin: .zero,
                size: snapshot.targetScreen.frame.size
            )
        )
        let renderer = try FrameRenderer(
            view: outputView,
            transform: transform,
            onFirstFrame: onFirstFrame,
            onFailure: onFailure
        )

        self.window = window
        self.renderer = renderer
        frameReceiver = renderer.frameReceiver

        outputView.autoresizingMask = [.width, .height]
        window.contentView = outputView
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = false
        window.isMovable = false
        window.level = Self.outputLevel(for: snapshot.targetScreen)
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        window.animationBehavior = .none
        window.sharingType = .none
        window.setFrame(snapshot.targetScreen.frame, display: false)
        window.orderOut(nil)
    }

    func reveal() {
        guard !isClosed, !isVisible else {
            return
        }
        renderer.start()
        refreshWindowLevel()
        window.orderFrontRegardless()
        isVisible = true
    }

    /// The output must cover the target monitor completely, including its
    /// menu bar and Dock, otherwise the teleprompter shows the frontmost
    /// app's menus instead of the mirrored image. On a single-monitor setup
    /// the menu bar stays reachable so the status item can still stop output.
    func refreshWindowLevel() {
        guard !isClosed else {
            return
        }
        let level = Self.outputLevel(for: window.screen)
        if window.level != level {
            window.level = level
        }
    }

    private static func outputLevel(for screen: NSScreen?) -> NSWindow.Level {
        // A second monitor keeps the menu bar and status item reachable, so
        // the output may cover the target monitor entirely.
        guard let screen, NSScreen.screens.contains(where: { $0 != screen })
        else {
            return .floating
        }
        return NSWindow.Level(
            rawValue: NSWindow.Level.mainMenu.rawValue + 1
        )
    }

    func updateTransform(_ transform: DisplayTransform) {
        guard !isClosed else {
            return
        }
        renderer.updateTransform(transform)
    }

    func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        isVisible = false
        renderer.stop()
        window.orderOut(nil)
        window.close()
    }
}
