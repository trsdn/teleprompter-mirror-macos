import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import TeleprompterCore

enum CapturePipelineError: LocalizedError {
    case processExclusionUnavailable

    var errorDescription: String? {
        switch self {
        case .processExclusionUnavailable:
            return "Die eigene App kann nicht sicher aus der Aufnahme ausgeschlossen werden."
        }
    }
}

final class StreamOutputBridge: NSObject, SCStreamOutput {
    private let frameReceiver: FrameReceiver
    private var loggedFirstFrame = false

    init(frameReceiver: FrameReceiver) {
        self.frameReceiver = frameReceiver
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        guard let statusNumber = CMGetAttachment(
            sampleBuffer,
            key: SCStreamFrameInfo.status.rawValue as CFString,
            attachmentModeOut: nil
        ) as? NSNumber,
        let status = SCFrameStatus(rawValue: statusNumber.intValue),
        status == .complete else {
            return
        }

        if !loggedFirstFrame {
            loggedFirstFrame = true
            NSLog(
                "Erster Videoframe empfangen: %dx%d, Pixelformat %u",
                CVPixelBufferGetWidth(pixelBuffer),
                CVPixelBufferGetHeight(pixelBuffer),
                CVPixelBufferGetPixelFormatType(pixelBuffer)
            )
        }

        markForImmediateDisplay(sampleBuffer)
        frameReceiver.receive(
            sampleBuffer: sampleBuffer,
            pixelBuffer: pixelBuffer
        )
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

final class CaptureStreamDelegate: NSObject, SCStreamDelegate {
    private let onUnexpectedStop: @Sendable (String) -> Void

    init(onUnexpectedStop: @escaping @Sendable (String) -> Void) {
        self.onUnexpectedStop = onUnexpectedStop
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onUnexpectedStop(error.localizedDescription)
    }
}

@MainActor
final class CaptureSession {
    private let stream: SCStream
    private let streamOutput: StreamOutputBridge
    private let streamDelegate: CaptureStreamDelegate
    private let sampleQueue = DispatchQueue(
        label: "com.github.trsdn.TeleprompterMirror.capture",
        qos: .userInteractive
    )
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
        guard snapshot.ownApplication.processID == getpid() else {
            throw CapturePipelineError.processExclusionUnavailable
        }

        let filter = SCContentFilter(
            display: snapshot.scDisplay,
            excludingApplications: [snapshot.ownApplication],
            exceptingWindows: []
        )

        let captureSize = CaptureSizing.fitted(
            sourceWidth: snapshot.descriptor.pixelWidth,
            sourceHeight: snapshot.descriptor.pixelHeight,
            maximumDimension: snapshot.maximumOutputDimension
        )
        let configuration = SCStreamConfiguration()
        configuration.width = captureSize.width
        configuration.height = captureSize.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 2
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let delegate = CaptureStreamDelegate(onUnexpectedStop: onUnexpectedStop)
        streamDelegate = delegate
        streamOutput = StreamOutputBridge(frameReceiver: frameReceiver)
        stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: delegate
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
                sampleHandlerQueue: sampleQueue
            )
            outputWasAdded = true
            try await stream.startCapture()
            captureStarted = true
        } catch {
            let startError = error
            if outputWasAdded {
                do {
                    try stream.removeStreamOutput(streamOutput, type: .screen)
                } catch {
                    NSLog(
                        "Stream-Ausgabe nach Startfehler nicht entfernbar: %@",
                        error.localizedDescription
                    )
                }
            }
            outputWasAdded = false
            startInProgress = false
            stopped = true
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
        if stopped {
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
        var firstError: (any Error)?

        if captureStarted {
            do {
                try await stream.stopCapture()
            } catch {
                firstError = error
            }
            captureStarted = false
        }

        if outputWasAdded {
            do {
                try stream.removeStreamOutput(streamOutput, type: .screen)
            } catch where firstError == nil {
                firstError = error
            } catch {
                // Preserve the original stop error.
            }
            outputWasAdded = false
        }

        stopped = true
        if let firstError {
            return .failure(firstError)
        }
        return .success(())
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
