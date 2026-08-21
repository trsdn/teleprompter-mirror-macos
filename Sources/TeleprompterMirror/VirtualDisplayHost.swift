import CoreGraphics
import Foundation
import VirtualDisplayBridge

enum VirtualSource {
    static let name = "Teleprompter Source"
    static let width = 1920
    static let height = 1080
    static let refreshRate = 60.0
}

enum VirtualDisplayHostProtocol {
    static let argument = "--virtual-display-host"
    static let readyPrefix = "TPM_DISPLAY_READY "
}

enum VirtualDisplayHostError: LocalizedError {
    case executableUnavailable
    case launchFailed(String)
    case exitedBeforeReady(Int32)
    case invalidResponse(String)
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "The app executable was not found."
        case let .launchFailed(message):
            return "The display host could not be started: \(message)"
        case let .exitedBeforeReady(status):
            return "Der Display-Host wurde vorzeitig beendet (Status \(status))."
        case let .invalidResponse(response):
            return "The display host reported an invalid response: \(response)"
        case .startupTimedOut:
            return "The display host did not become ready in time."
        }
    }
}

enum VirtualDisplayHostMain {
    static func run() -> Never {
        guard let display = VirtualDisplay(
            name: VirtualSource.name,
            width: UInt32(VirtualSource.width),
            height: UInt32(VirtualSource.height),
            refreshRate: VirtualSource.refreshRate
        ) else {
            fputs("TPM_DISPLAY_ERROR creation_failed\n", stderr)
            fflush(stderr)
            exit(EXIT_FAILURE)
        }

        print(
            "\(VirtualDisplayHostProtocol.readyPrefix)\(display.displayID)"
        )
        fflush(stdout)

        let originalParent = getppid()
        while originalParent > 1, getppid() == originalParent {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        }
        exit(EXIT_SUCCESS)
    }
}

@MainActor
final class VirtualDisplayHostProcess {
    private let process = Process()
    private let outputPipe = Pipe()
    private var started = false

    var isRunning: Bool {
        process.isRunning
    }

    func start() async throws -> CGDirectDisplayID {
        guard !started else {
            throw VirtualDisplayHostError.launchFailed(
                "Der Prozess wurde bereits verwendet."
            )
        }
        guard let executableURL = Bundle.main.executableURL else {
            throw VirtualDisplayHostError.executableUnavailable
        }

        started = true
        process.executableURL = executableURL
        process.arguments = [VirtualDisplayHostProtocol.argument]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            throw VirtualDisplayHostError.launchFailed(
                error.localizedDescription
            )
        }

        do {
            let response = try await firstOutputLine()
            guard response.hasPrefix(
                VirtualDisplayHostProtocol.readyPrefix
            ) else {
                throw VirtualDisplayHostError.invalidResponse(response)
            }
            let rawID = response.dropFirst(
                VirtualDisplayHostProtocol.readyPrefix.count
            )
            guard let displayID = CGDirectDisplayID(rawID),
                  displayID != 0 else {
                throw VirtualDisplayHostError.invalidResponse(response)
            }
            return displayID
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard process.isRunning else {
            return
        }
        process.terminate()
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
    }

    private func firstOutputLine() async throws -> String {
        let handle = outputPipe.fileHandleForReading
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for try await line in handle.bytes.lines {
                    return line
                }
                throw VirtualDisplayHostError.exitedBeforeReady(
                    self.process.terminationStatus
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw VirtualDisplayHostError.startupTimedOut
            }

            guard let line = try await group.next() else {
                throw VirtualDisplayHostError.exitedBeforeReady(
                    process.terminationStatus
                )
            }
            group.cancelAll()
            return line
        }
    }
}
