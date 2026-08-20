import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

enum CapturePipelineError: LocalizedError {
    case invalidSourceGeometry(width: Int, height: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidSourceGeometry(width, height):
            return "Ungültige Capture-Größe \(width)×\(height)."
        }
    }
}

/// ScreenCaptureKit callback bridge. The stream invokes this object only on
/// the retained serial callback queue. Frames are passed directly to the
/// renderer; no pixel copy or additional frame queue is introduced.
private final class CaptureStreamBridge: NSObject, @unchecked Sendable,
    SCStreamOutput, SCStreamDelegate
{
    private let lock = NSLock()
    private let frameReceiver: FrameReceiver
    private let onUnexpectedStop: @Sendable (String) -> Void
    private var stoppingIntentionally = false
    private var loggedFirstCallback = false
    private var loggedFirstCompleteFrame = false

    init(
        frameReceiver: FrameReceiver,
        onUnexpectedStop: @escaping @Sendable (String) -> Void
    ) {
        self.frameReceiver = frameReceiver
        self.onUnexpectedStop = onUnexpectedStop
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        lock.lock()
        if !loggedFirstCallback {
            loggedFirstCallback = true
            NSLog(
                "Erster ScreenCaptureKit-Callback: Typ=%ld",
                outputType.rawValue
            )
        }
        lock.unlock()

        guard outputType == .screen else {
            return
        }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let statusRawValue = attachments.first?[.status] as? Int,
              statusRawValue == SCFrameStatus.complete.rawValue,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }

        lock.lock()
        if !loggedFirstCompleteFrame {
            loggedFirstCompleteFrame = true
            NSLog(
                "Erster vollständiger ScreenCaptureKit-Frame: %dx%d, Pixelformat %u",
                CVPixelBufferGetWidth(pixelBuffer),
                CVPixelBufferGetHeight(pixelBuffer),
                CVPixelBufferGetPixelFormatType(pixelBuffer)
            )
        }
        lock.unlock()

        markForImmediateDisplay(sampleBuffer)
        frameReceiver.receive(
            sampleBuffer: sampleBuffer,
            pixelBuffer: pixelBuffer
        )
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock()
        let expected = stoppingIntentionally
        lock.unlock()

        NSLog(
            "ScreenCaptureKit-Stream beendet%@ : %@",
            expected ? " (angefordert)" : "",
            error.localizedDescription
        )
        if !expected {
            onUnexpectedStop(error.localizedDescription)
        }
    }

    func prepareForStop() {
        lock.lock()
        stoppingIntentionally = true
        lock.unlock()
    }

    private func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else {
            return
        }

        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(
                kCMSampleAttachmentKey_DisplayImmediately
            ).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

/// Captures exactly the retained virtual source display with ScreenCaptureKit.
/// The filter, stream, delegate/output bridge, and callback queue are all
/// retained by this session until explicit teardown completes.
@MainActor
final class CaptureSession {
    private let filter: SCContentFilter
    private let stream: SCStream
    private let streamOutput: CaptureStreamBridge
    private let streamDelegate: CaptureStreamBridge
    private let callbackQueue: DispatchQueue

    private var outputWasAdded = false
    private var captureStarted = false
    private var startInProgress = false
    private var stopInProgress = false
    private var stopRequested = false
    private var stopped = false
    private var stopWaiters: [
        CheckedContinuation<Result<Void, any Error>, Never>
    ] = []

    init(
        snapshot: ResolvedDisplaySnapshot,
        frameReceiver: FrameReceiver,
        onUnexpectedStop: @escaping @Sendable (String) -> Void
    ) throws {
        guard snapshot.sourceWidth > 0, snapshot.sourceHeight > 0 else {
            throw CapturePipelineError.invalidSourceGeometry(
                width: snapshot.sourceWidth,
                height: snapshot.sourceHeight
            )
        }

        let filter = SCContentFilter(
            display: snapshot.sourceCaptureDisplay,
            excludingWindows: []
        )
        let configuration = SCStreamConfiguration()
        if #available(macOS 14.0, *) {
            configuration.width = max(
                1,
                Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            )
            configuration.height = max(
                1,
                Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            )
        } else {
            configuration.width = snapshot.sourceWidth
            configuration.height = snapshot.sourceHeight
        }
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 4
        configuration.showsCursor = true

        let bridge = CaptureStreamBridge(
            frameReceiver: frameReceiver,
            onUnexpectedStop: onUnexpectedStop
        )
        let queue = DispatchQueue(
            label: "com.github.trsdn.TeleprompterMirror.capture",
            qos: .userInteractive
        )

        self.filter = filter
        streamOutput = bridge
        streamDelegate = bridge
        callbackQueue = queue
        stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: bridge
        )
    }

    func start() async throws {
        guard !startInProgress, !captureStarted, !stopped else {
            throw CancellationError()
        }
        startInProgress = true

        do {
            try stream.addStreamOutput(
                streamOutput,
                type: .screen,
                sampleHandlerQueue: callbackQueue
            )
            outputWasAdded = true
            try await stream.startCapture()
            captureStarted = true
        } catch {
            let startError = error
            NSLog(
                "ScreenCaptureKit-Stream konnte nicht gestartet werden: %@",
                error.localizedDescription
            )
            teardownAfterStartFailure()
            startInProgress = false
            finishStopWaiters(with: .success(()))
            throw startError
        }

        startInProgress = false
        if stopRequested {
            stopInProgress = true
            let result = await performStop()
            stopInProgress = false
            finishStopWaiters(with: result)
            try result.get()
        }
    }

    func stop() async throws {
        guard !stopped else {
            return
        }
        stopRequested = true
        if startInProgress || stopInProgress {
            let result = await withCheckedContinuation { continuation in
                stopWaiters.append(continuation)
            }
            try result.get()
            return
        }

        stopInProgress = true
        let result = await performStop()
        stopInProgress = false
        finishStopWaiters(with: result)
        try result.get()
    }

    private func performStop() async -> Result<Void, any Error> {
        streamDelegate.prepareForStop()
        var firstError: (any Error)?
        if captureStarted {
            do {
                try await stream.stopCapture()
            } catch {
                firstError = error
                NSLog(
                    "ScreenCaptureKit-Stream konnte nicht gestoppt werden: %@",
                    error.localizedDescription
                )
            }
            captureStarted = false
        }

        if outputWasAdded {
            do {
                try stream.removeStreamOutput(streamOutput, type: .screen)
            } catch {
                if firstError == nil {
                    firstError = error
                }
                NSLog(
                    "ScreenCaptureKit-Ausgabe konnte nicht entfernt werden: %@",
                    error.localizedDescription
                )
            }
            outputWasAdded = false
        }

        stopped = true
        if let firstError {
            return .failure(firstError)
        }
        return .success(())
    }

    private func teardownAfterStartFailure() {
        streamDelegate.prepareForStop()
        if outputWasAdded {
            do {
                try stream.removeStreamOutput(streamOutput, type: .screen)
            } catch {
                NSLog(
                    "ScreenCaptureKit-Ausgabe nach Startfehler nicht entfernbar: %@",
                    error.localizedDescription
                )
            }
            outputWasAdded = false
        }
        captureStarted = false
        stopped = true
    }

    private func finishStopWaiters(
        with result: Result<Void, any Error>
    ) {
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }
}
