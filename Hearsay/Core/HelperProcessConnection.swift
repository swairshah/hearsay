import Foundation
import os.log

/// One `HearsayParakeetHelper` process speaking line-delimited JSON over stdio.
///
/// Requests are strictly serialized on a private queue: the helper answers in
/// order, so two callers must never interleave a write/read pair. (Swift actors
/// are re-entrant across `await`, which is why this isn't an actor.)
final class HelperProcessConnection: @unchecked Sendable {

    private let name: String
    private let queue: DispatchQueue
    private let logger = Logger(subsystem: "com.swair.hearsay", category: "helper")

    // Pipes are only touched on `queue`.
    private var input: FileHandle?
    private var output: FileHandle?

    // Readable from any thread without waiting behind an in-flight request
    // (a first-run model download can take minutes).
    private let stateLock = NSLock()
    private var process: Process?
    private var launchCount = 0

    init(name: String) {
        self.name = name
        self.queue = DispatchQueue(label: "com.swair.hearsay.helper.\(name)", qos: .userInitiated)
        // Writing to a helper that just died must fail with EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Bumped every time a fresh helper process is launched, so callers can
    /// tell when in-process state (loaded models, sessions) was lost.
    var generation: Int {
        stateLock.withLock { launchCount }
    }

    var isRunning: Bool {
        stateLock.withLock { process?.isRunning == true }
    }

    static var isAvailable: Bool { helperExecutableURL() != nil }

    /// Send one JSON line and wait for the matching response line.
    /// With a `timeout`, a helper that doesn't answer in time is killed.
    func roundTrip(_ request: Data, timeout: TimeInterval? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                var watchdog: DispatchWorkItem?
                do {
                    try ensureRunningLocked()
                    guard let input, let output else {
                        throw SpeechTranscriptionError.failed("\(name) helper pipes are unavailable")
                    }
                    if let timeout {
                        let work = DispatchWorkItem { [weak self] in self?.terminateNow(reason: "timed out") }
                        watchdog = work
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
                    }
                    try input.write(contentsOf: request + Data([0x0A]))
                    let response = try Self.readLine(from: output)
                    watchdog?.cancel()
                    continuation.resume(returning: response)
                } catch {
                    watchdog?.cancel()
                    logger.error("\(self.name, privacy: .public) helper request failed: \(error.localizedDescription, privacy: .public)")
                    // The protocol is out of sync after any I/O error; start fresh next time.
                    stopLocked()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Terminate the helper. Doesn't wait behind an in-flight request: killing
    /// the process makes that request's read fail, which unblocks the queue.
    func stop() {
        terminateNow(reason: "stopped")
        queue.async { [self] in stopLocked() }
    }

    private func terminateNow(reason: String) {
        let running = stateLock.withLock { process }
        guard let running, running.isRunning else { return }
        logger.notice("Terminating \(self.name, privacy: .public) helper (\(reason, privacy: .public))")
        running.terminate()
    }

    // MARK: - Process lifecycle (on `queue`)

    private func ensureRunningLocked() throws {
        if isRunning {
            return
        }
        stopLocked()

        guard let helperURL = Self.helperExecutableURL() else {
            throw SpeechTranscriptionError.failed("Parakeet helper is not bundled for this architecture.")
        }

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let helperProcess = Process()
        helperProcess.executableURL = helperURL
        helperProcess.standardInput = standardInput
        helperProcess.standardOutput = standardOutput
        helperProcess.standardError = FileHandle.standardError

        do {
            try helperProcess.run()
        } catch {
            throw SpeechTranscriptionError.failed("Unable to launch \(name) helper: \(error.localizedDescription)")
        }

        stateLock.withLock {
            process = helperProcess
            launchCount += 1
        }
        input = standardInput.fileHandleForWriting
        output = standardOutput.fileHandleForReading
        logger.notice("Launched \(self.name, privacy: .public) helper pid=\(helperProcess.processIdentifier)")
    }

    private func stopLocked() {
        try? input?.close()
        let old = stateLock.withLock { () -> Process? in
            defer { process = nil }
            return process
        }
        if old?.isRunning == true {
            old?.terminate()
        }
        input = nil
        output = nil
    }

    private static func helperExecutableURL() -> URL? {
        #if arch(arm64)
        if let url = Bundle.main.url(forAuxiliaryExecutable: "HearsayParakeetHelper") {
            return url
        }

        let fallback = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/HearsayParakeetHelper")
        if FileManager.default.isExecutableFile(atPath: fallback.path) {
            return fallback
        }
        #endif

        return nil
    }

    private static func readLine(from handle: FileHandle) throws -> Data {
        var data = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            guard let value = byte.first else {
                throw SpeechTranscriptionError.failed("Helper exited unexpectedly")
            }

            if value == 0x0A {
                return data
            }

            data.append(value)
        }
    }
}
