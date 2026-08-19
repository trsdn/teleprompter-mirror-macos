import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import TeleprompterCore

enum RenderingPath: String, Sendable {
    case sampleBufferDisplayLayer = "AVSampleBufferDisplayLayer"
    case coreImageLayer = "CoreImage/CALayer"
}

final class LatestFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latestSampleBuffer: CMSampleBuffer?
    private var generation: UInt64 = 0

    func replace(with sampleBuffer: CMSampleBuffer) {
        lock.lock()
        latestSampleBuffer = sampleBuffer
        generation &+= 1
        lock.unlock()
    }

    func current() -> (
        sampleBuffer: CMSampleBuffer,
        generation: UInt64
    )? {
        lock.lock()
        defer { lock.unlock() }
        guard let latestSampleBuffer else {
            return nil
        }
        return (latestSampleBuffer, generation)
    }

    func clear() {
        lock.lock()
        latestSampleBuffer = nil
        generation &+= 1
        lock.unlock()
    }
}

private enum DirectPresentationEvent: Sendable {
    case enqueued(size: PixelSize)
    case failed(reason: String)
}

/// Enqueues only on ScreenCaptureKit's serial sample queue. Incoming frames
/// are dropped whenever AVFoundation applies backpressure; no secondary queue
/// is allowed to accumulate.
private final class DirectSampleBufferPresenter: @unchecked Sendable {
    private let layer: AVSampleBufferDisplayLayer
    private let lock = NSLock()
    private var isActive = true
    private var eventHandler: (@Sendable (DirectPresentationEvent) -> Void)?
    private var lastReportedSize: PixelSize?
    private var hasEnqueuedFrame = false
    private var backpressureStartUptime: TimeInterval?

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    func setEventHandler(
        _ handler: @escaping @Sendable (DirectPresentationEvent) -> Void
    ) {
        lock.lock()
        eventHandler = handler
        lock.unlock()
    }

    func present(
        sampleBuffer: CMSampleBuffer,
        pixelBuffer: CVPixelBuffer
    ) {
        var event: DirectPresentationEvent?
        var handler: (@Sendable (DirectPresentationEvent) -> Void)?

        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }

        if CVPixelBufferGetIOSurface(pixelBuffer) == nil {
            isActive = false
            event = .failed(
                reason: "ScreenCaptureKit lieferte keinen IOSurface-gestützten BGRA-Puffer."
            )
        } else if layer.status == .failed {
            isActive = false
            event = .failed(
                reason: layer.error?.localizedDescription
                    ?? "AVSampleBufferDisplayLayer meldete einen unbekannten Fehler."
            )
        } else if !layer.isReadyForMoreMediaData {
            let now = ProcessInfo.processInfo.systemUptime
            if let backpressureStartUptime,
               now - backpressureStartUptime >= 2 {
                isActive = false
                event = .failed(
                    reason: "AVSampleBufferDisplayLayer nahm zwei Sekunden lang keine Frames an."
                )
            } else if backpressureStartUptime == nil {
                self.backpressureStartUptime = now
            }
        } else {
            backpressureStartUptime = nil
            layer.enqueue(sampleBuffer)

            if layer.status == .failed {
                isActive = false
                event = .failed(
                    reason: layer.error?.localizedDescription
                        ?? "AVSampleBufferDisplayLayer lehnte den BGRA-Frame ab."
                )
            } else {
                let size = PixelSize(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                )
                if !hasEnqueuedFrame || size != lastReportedSize {
                    hasEnqueuedFrame = true
                    lastReportedSize = size
                    event = .enqueued(size: size)
                }
            }
        }

        handler = eventHandler
        lock.unlock()

        if let event {
            handler?(event)
        }
    }

    func deactivate() {
        lock.lock()
        isActive = false
        eventHandler = nil
        lock.unlock()
    }
}

/// Thread-safe bridge shared by ScreenCaptureKit and the renderer. It keeps
/// exactly one retained sample for the dormant fallback path.
final class FrameReceiver: @unchecked Sendable {
    let frameStore = LatestFrameStore()

    private let lock = NSLock()
    private var isActive = true
    private var directPresenter: DirectSampleBufferPresenter?

    fileprivate init(directPresenter: DirectSampleBufferPresenter) {
        self.directPresenter = directPresenter
    }

    func receive(
        sampleBuffer: CMSampleBuffer,
        pixelBuffer: CVPixelBuffer
    ) {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        frameStore.replace(with: sampleBuffer)
        directPresenter?.present(
            sampleBuffer: sampleBuffer,
            pixelBuffer: pixelBuffer
        )
        lock.unlock()
    }

    fileprivate func useFallback() {
        lock.lock()
        let presenter = directPresenter
        directPresenter = nil
        lock.unlock()
        presenter?.deactivate()
    }

    fileprivate func stop() {
        lock.lock()
        isActive = false
        let presenter = directPresenter
        directPresenter = nil
        lock.unlock()
        presenter?.deactivate()
        frameStore.clear()
    }
}

enum RendererError: LocalizedError {
    case layerUnavailable

    var errorDescription: String? {
        switch self {
        case .layerUnavailable:
            return "Die Core-Animation-Ausgabe konnte nicht erstellt werden."
        }
    }
}

@MainActor
final class FrameRenderer {
    let frameReceiver: FrameReceiver

    private enum RenderPath {
        case sampleBuffer
        case coreImage
    }

    private weak var outputView: NSView?
    private var context: CIContext?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let sampleBufferLayer: AVSampleBufferDisplayLayer
    private let fallbackLayer: CALayer
    private let directPresenter: DirectSampleBufferPresenter
    private var displayTransform: DisplayTransform
    private var onFirstFrame: ((RenderingPath) -> Void)?
    private var onFailure: ((String) -> Void)?
    private var fallbackTimer: Timer?
    private var presentationProbe: Task<Void, Never>?
    private var renderPath = RenderPath.sampleBuffer
    private var isStarted = false
    private var lastFallbackRenderedGeneration: UInt64?
    private var fallbackNeedsRender = true
    private var fallbackFailureCount = 0
    private var lastSampleSize: PixelSize?
    private var lastTargetBounds: CGRect?
    private var loggedFirstFrameRender = false
    private var failureWasReported = false

    init(
        view: NSView,
        transform: DisplayTransform,
        onFirstFrame: ((RenderingPath) -> Void)? = nil,
        onFailure: ((String) -> Void)? = nil
    ) throws {
        view.wantsLayer = true
        guard let rootLayer = view.layer else {
            throw RendererError.layerUnavailable
        }

        let sampleBufferLayer = AVSampleBufferDisplayLayer()
        sampleBufferLayer.anchorPoint = .zero
        sampleBufferLayer.position = .zero
        sampleBufferLayer.videoGravity = .resize
        sampleBufferLayer.backgroundColor = NSColor.black.cgColor

        let fallbackLayer = CALayer()
        fallbackLayer.backgroundColor = NSColor.black.cgColor
        fallbackLayer.contentsGravity = .resizeAspect
        fallbackLayer.masksToBounds = true
        fallbackLayer.isHidden = true

        let directPresenter = DirectSampleBufferPresenter(
            layer: sampleBufferLayer
        )

        outputView = view
        displayTransform = transform
        self.onFirstFrame = onFirstFrame
        self.onFailure = onFailure
        self.sampleBufferLayer = sampleBufferLayer
        self.fallbackLayer = fallbackLayer
        self.directPresenter = directPresenter
        frameReceiver = FrameReceiver(directPresenter: directPresenter)

        rootLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.masksToBounds = true
        rootLayer.addSublayer(fallbackLayer)
        rootLayer.addSublayer(sampleBufferLayer)

        directPresenter.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleDirectPresentationEvent(event)
            }
        }
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        updateLayerGeometry()
        if renderPath == .sampleBuffer, lastSampleSize != nil {
            schedulePresentationProbe()
        } else if renderPath == .coreImage {
            startFallbackTimer()
        }
    }

    func updateTransform(_ transform: DisplayTransform) {
        guard displayTransform != transform else {
            return
        }
        displayTransform = transform
        fallbackNeedsRender = true
        updateLayerGeometry()
    }

    func targetBoundsDidChange() {
        updateLayerGeometry()
    }

    func stop() {
        guard isStarted || onFirstFrame != nil || onFailure != nil else {
            return
        }
        isStarted = false
        presentationProbe?.cancel()
        presentationProbe = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        frameReceiver.stop()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sampleBufferLayer.flushAndRemoveImage()
        sampleBufferLayer.isHidden = true
        fallbackLayer.contents = nil
        fallbackLayer.isHidden = true
        sampleBufferLayer.removeFromSuperlayer()
        fallbackLayer.removeFromSuperlayer()
        CATransaction.commit()

        context = nil
        onFirstFrame = nil
        onFailure = nil
    }

    private func handleDirectPresentationEvent(
        _ event: DirectPresentationEvent
    ) {
        guard renderPath == .sampleBuffer else {
            return
        }

        switch event {
        case let .enqueued(size):
            lastSampleSize = size
            updateLayerGeometry()
            if isStarted {
                schedulePresentationProbe()
            }
        case let .failed(reason):
            activateCoreImageFallback(reason: reason)
        }
    }

    private func schedulePresentationProbe() {
        guard presentationProbe == nil else {
            return
        }
        presentationProbe = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard let self, renderPath == .sampleBuffer else {
                return
            }
            if confirmDirectPresentationIfPossible() {
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(1_350))
            } catch {
                return
            }
            guard renderPath == .sampleBuffer else {
                return
            }
            if !confirmDirectPresentationIfPossible() {
                activateCoreImageFallback(
                    reason: "AVSampleBufferDisplayLayer blieb nach dem ersten Frame im Status „unknown“."
                )
            }
        }
    }

    @discardableResult
    private func confirmDirectPresentationIfPossible() -> Bool {
        switch sampleBufferLayer.status {
        case .rendering:
            reportFirstFrame(
                path: .sampleBufferDisplayLayer,
                message: "RENDER_PATH=AVSampleBufferDisplayLayer (IOSurface/BGRA, readiness-gated)"
            )
            return true
        case .failed:
            activateCoreImageFallback(
                reason: sampleBufferLayer.error?.localizedDescription
                    ?? "AVSampleBufferDisplayLayer meldete einen unbekannten Fehler."
            )
            return true
        case .unknown:
            return false
        @unknown default:
            return false
        }
    }

    private func updateLayerGeometry() {
        guard let outputView else {
            return
        }
        let targetBounds = outputView.bounds
        layoutFallbackLayer(in: targetBounds)

        guard renderPath == .sampleBuffer,
              let lastSampleSize,
              targetBounds.width > 0,
              targetBounds.height > 0,
              lastSampleSize != PixelSize(width: 0, height: 0),
              lastTargetBounds != targetBounds
                || sampleBufferLayer.affineTransform()
                    != geometryTransform(
                        sampleSize: lastSampleSize,
                        targetBounds: targetBounds
                    ) else {
            return
        }
        layoutSampleBufferLayer(
            sampleSize: lastSampleSize,
            targetBounds: targetBounds
        )
    }

    private func geometryTransform(
        sampleSize: PixelSize,
        targetBounds: CGRect
    ) -> CGAffineTransform {
        TransformGeometry.layerPresentationGeometry(
            sourceWidth: sampleSize.width,
            sourceHeight: sampleSize.height,
            targetBounds: targetBounds,
            transform: displayTransform
        )?.affineTransform ?? .identity
    }

    private func layoutSampleBufferLayer(
        sampleSize: PixelSize,
        targetBounds: CGRect
    ) {
        guard let geometry = TransformGeometry.layerPresentationGeometry(
            sourceWidth: sampleSize.width,
            sourceHeight: sampleSize.height,
            targetBounds: targetBounds,
            transform: displayTransform
        ) else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sampleBufferLayer.bounds = geometry.sourceBounds
        sampleBufferLayer.anchorPoint = .zero
        sampleBufferLayer.position = .zero
        sampleBufferLayer.setAffineTransform(geometry.affineTransform)
        CATransaction.commit()

        lastTargetBounds = targetBounds
    }

    private func layoutFallbackLayer(in targetBounds: CGRect) {
        guard fallbackLayer.frame != targetBounds else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fallbackLayer.frame = targetBounds
        CATransaction.commit()
    }

    private func activateCoreImageFallback(reason: String) {
        guard renderPath == .sampleBuffer else {
            return
        }
        renderPath = .coreImage
        presentationProbe?.cancel()
        presentationProbe = nil
        frameReceiver.useFallback()
        fallbackNeedsRender = true
        lastFallbackRenderedGeneration = nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sampleBufferLayer.flushAndRemoveImage()
        sampleBufferLayer.isHidden = true
        fallbackLayer.isHidden = false
        CATransaction.commit()

        NSLog(
            "RENDER_PATH=CoreImage/CALayer FALLBACK_REASON=%@",
            reason
        )
        if isStarted {
            startFallbackTimer()
        }
    }

    private func startFallbackTimer() {
        guard fallbackTimer == nil else {
            return
        }
        renderLatestFallbackFrame()
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderLatestFallbackFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func renderLatestFallbackFrame() {
        guard renderPath == .coreImage else {
            return
        }
        if sampleBufferLayer.status == .failed {
            // The direct layer is already hidden; retain its error only in the
            // path-selection log and continue the independent fallback.
        }
        guard let frame = frameReceiver.frameStore.current(),
              let pixelBuffer = frame.sampleBuffer.imageBuffer else {
            return
        }
        renderCoreImageFallback(
            pixelBuffer: pixelBuffer,
            generation: frame.generation
        )
    }

    private func renderCoreImageFallback(
        pixelBuffer: CVPixelBuffer,
        generation: UInt64
    ) {
        guard fallbackNeedsRender
                || generation != lastFallbackRenderedGeneration else {
            return
        }

        let outputImage = transformedImage(from: pixelBuffer)
        let outputExtent = outputImage.extent.integral
        guard outputExtent.width > 0,
              outputExtent.height > 0 else {
            recordFallbackFailure("Core Image erzeugte eine leere Bildfläche.")
            return
        }

        guard let cgImage = coreImageContext().createCGImage(
            outputImage,
            from: outputExtent,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            recordFallbackFailure(
                "Core Image konnte keinen CGImage-Ausgabeframe erzeugen."
            )
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fallbackLayer.contents = cgImage
        CATransaction.commit()

        fallbackFailureCount = 0
        fallbackNeedsRender = false
        lastFallbackRenderedGeneration = generation
        reportFirstFrame(
            path: .coreImageLayer,
            message: String(
                format: "RENDER_PATH=CoreImage/CALayer FRAME=%.0fx%.0f",
                outputExtent.width,
                outputExtent.height
            )
        )
    }

    private func coreImageContext() -> CIContext {
        if let context {
            return context
        }

        let contextOptions: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: colorSpace
        ]
        let newContext: CIContext
        if let device = MTLCreateSystemDefaultDevice() {
            newContext = CIContext(
                mtlDevice: device,
                options: contextOptions
            )
        } else {
            NSLog(
                "Metal ist nicht verfügbar; Core Image verwendet seinen Standard-Renderer."
            )
            newContext = CIContext(options: contextOptions)
        }
        context = newContext
        return newContext
    }

    private func transformedImage(from pixelBuffer: CVPixelBuffer) -> CIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return image.transformed(
            by: TransformGeometry.orientedAffineTransform(
                sourceExtent: image.extent,
                transform: displayTransform
            )
        )
    }

    private func recordFallbackFailure(_ message: String) {
        fallbackFailureCount += 1
        guard fallbackFailureCount >= 3, !failureWasReported else {
            return
        }
        failureWasReported = true
        NSLog("RENDER_FAILURE=%@", message)
        onFailure?(message)
    }

    private func reportFirstFrame(
        path: RenderingPath,
        message: String
    ) {
        guard !loggedFirstFrameRender else {
            return
        }
        loggedFirstFrameRender = true
        NSLog("%@", message)
        let callback = onFirstFrame
        onFirstFrame = nil
        callback?(path)
    }
}
