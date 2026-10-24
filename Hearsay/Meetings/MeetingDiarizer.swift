import AVFoundation
import Foundation
import os.log

/// Speaker diarization for the remote (system audio) side of a meeting.
///
/// Runs in its own `HearsayParakeetHelper` process so diarization never queues
/// behind (or blocks) dictation transcription. Audio pushed before the models
/// finish loading is queued and replayed in order.
actor MeetingDiarizer {

    private struct Request: Encodable {
        let id: Int
        let command: String
        let model: String?
        let audioPath: String?
        let ranges: [[Double]]?
    }

    private struct Response: Decodable {
        struct Word: Decodable {
            let text: String
            let start: Double
            let end: Double
        }

        let id: Int
        let ok: Bool
        let error: String?
        let speakers: [Int]?
        let turns: [[Double]]?
        let words: [[Word]]?
    }

    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    static var isSupported: Bool { HelperProcessConnection.isAvailable }

    private let connection = HelperProcessConnection(name: "diarizer")
    private let logger = Logger(subsystem: "com.swair.hearsay", category: "diarizer")
    private var nextRequestID = 1
    private(set) var state: State = .idle
    private var sessionGeneration: Int?
    private var startTask: Task<Void, Never>?

    // MARK: - Live session

    /// Begin a new streaming session. Returns immediately; models load in the background.
    func startSession() {
        state = .loading
        pending.removeAll()
        startTask = Task {
            do {
                // First run downloads ~250 MB and compiles the model.
                try await self.send(command: "diarize_start", timeout: 900)
                self.markReady()
            } catch {
                self.markFailed(error)
            }
        }
    }

    /// Queue the next chunk of 16 kHz mono system audio (contiguous with the last one).
    /// Chunks are sent strictly in order by a single drain loop.
    func push(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        if case .failed = state { return }
        pending.append(samples)
        guard drainTask == nil else { return }
        drainTask = Task { await self.drainPending() }
    }

    private var pending: [[Float]] = []
    private var drainTask: Task<Void, Never>?

    private func drainPending() async {
        await startTask?.value
        while !pending.isEmpty {
            let samples = pending.removeFirst()
            guard state == .ready, connection.generation == sessionGeneration else {
                pending.removeAll()
                break
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hearsay-diarize-\(UUID().uuidString).wav")
            do {
                try MeetingAudioIO.writeWAV(samples, to: url)
                try await send(command: "diarize_push", audioPath: url.path, timeout: 30)
            } catch {
                // A missing chunk would shift every later timestamp, so the
                // session can't be trusted after any failed push.
                logger.error("Diarizer push failed: \(error.localizedDescription, privacy: .public)")
                state = .failed("Speaker detection stopped unexpectedly")
            }
            try? FileManager.default.removeItem(at: url)
        }
        drainTask = nil
    }

    /// Wait until every queued chunk has been sent. Only call when `.ready`:
    /// before that, the drain loop is parked behind model loading.
    private func waitForPending() async {
        while let task = drainTask {
            await task.value
        }
    }

    /// Dominant remote speaker slot for each time range (seconds from session start).
    func assign(_ ranges: [ClosedRange<TimeInterval>]) async -> [Int?] {
        guard !ranges.isEmpty, state == .ready else { return ranges.map { _ in nil } }
        await waitForPending()
        guard state == .ready, connection.generation == sessionGeneration else {
            return ranges.map { _ in nil }
        }
        do {
            let response = try await send(
                command: "diarize_assign",
                ranges: ranges.map { [$0.lowerBound, $0.upperBound] },
                timeout: 30
            )
            let slots = response.speakers ?? []
            return ranges.indices.map { index in
                index < slots.count && slots[index] >= 0 ? slots[index] : nil
            }
        } catch {
            logger.error("Diarizer assign failed: \(error.localizedDescription, privacy: .public)")
            return ranges.map { _ in nil }
        }
    }

    /// Flush the model's lookahead so the last seconds get final labels.
    /// Skipped if the model never finished loading (first-run download):
    /// the meeting saves with "Others" and can be re-detected later.
    func finishSession() async {
        guard state == .ready else { return }
        await waitForPending()
        guard state == .ready, connection.generation == sessionGeneration else { return }
        do {
            try await send(command: "diarize_finish", timeout: 60)
        } catch {
            logger.error("Diarizer finish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whole-recording speaker turns for a saved call track, plus per-word
    /// timings for each of `ranges` when a Parakeet `wordModel` is installed.
    func refine(
        audioURL: URL,
        ranges: [ClosedRange<TimeInterval>],
        wordModel: String?
    ) async throws -> (turns: [MeetingSpeakerRefinement.Turn], words: [[MeetingSpeakerRefinement.Word]]?) {
        // First use downloads the speaker models.
        let response = try await send(
            command: "refine",
            model: wordModel,
            audioPath: audioURL.path,
            ranges: ranges.map { [$0.lowerBound, $0.upperBound] },
            timeout: 900
        )
        let turns = (response.turns ?? []).compactMap { values -> MeetingSpeakerRefinement.Turn? in
            guard values.count == 3 else { return nil }
            return MeetingSpeakerRefinement.Turn(speaker: Int(values[2]), start: values[0], end: values[1])
        }
        let words = response.words?.map { list in
            list.map { MeetingSpeakerRefinement.Word(text: $0.text, start: $0.start, end: $0.end) }
        }
        return (turns, words)
    }

    func shutdown() {
        connection.stop()
        state = .idle
        sessionGeneration = nil
    }

    // MARK: - Private

    private func markReady() {
        sessionGeneration = connection.generation
        state = .ready
        logger.notice("Diarizer ready")
    }

    private func markFailed(_ error: Error) {
        state = .failed(error.localizedDescription)
        logger.error("Diarizer unavailable: \(error.localizedDescription, privacy: .public)")
    }

    @discardableResult
    private func send(command: String, model: String? = nil, audioPath: String? = nil, ranges: [[Double]]? = nil, timeout: TimeInterval? = nil) async throws -> Response {
        let requestID = nextRequestID
        nextRequestID += 1
        let request = Request(id: requestID, command: command, model: model, audioPath: audioPath, ranges: ranges)
        let data = try await connection.roundTrip(try JSONEncoder().encode(request), timeout: timeout)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.id == requestID else {
            throw SpeechTranscriptionError.failed("Diarizer returned an out-of-order response")
        }
        guard response.ok else {
            throw SpeechTranscriptionError.failed(response.error ?? "Diarizer failed")
        }
        return response
    }
}
