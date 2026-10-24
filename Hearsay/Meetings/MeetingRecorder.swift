import AVFoundation
import Foundation
import os.log

private let recorderLogger = Logger(subsystem: "com.swair.hearsay", category: "meeting")
private let diagnosticLog = DiagnosticLog.shared

/// Live status of the meeting being recorded, for the UI.
struct MeetingLiveState {
    enum Phase: Equatable {
        case recording
        /// Capture stopped; last utterances and speaker labels are being finalized.
        case finishing
    }

    enum SpeakerDetection: Equatable {
        case off
        case loading
        case active
        case unavailable(String)
    }

    /// Words heard so far in an utterance that hasn't finished.
    struct Partial: Equatable {
        let ordinal: Int
        let start: TimeInterval
        var text: String
    }

    let meetingID: UUID
    let startedAt: Date
    var phase: Phase = .recording
    var micLevel: Float = 0
    var systemLevel: Float = 0
    var micSpeaking = false
    var systemSpeaking = false
    var partials: [MeetingSegment.Channel: Partial] = [:]
    var systemAudioAvailable = true
    var speakerDetection: SpeakerDetection = .off
    var lastSpeechAt: Date

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
}

enum MeetingRecorderEvent {
    case started(UUID)
    /// Levels, partial text or status changed (frequent).
    case liveUpdated
    case stopping(UUID)
    case finished(UUID)
    /// Nobody has spoken for `minutes`; ask whether the meeting is over.
    case silenceReminder(minutes: Int)
    /// Someone said goodbye and the conversation went quiet; ask to stop.
    case wrapUpSuggested
    case autoStopped(UUID, minutes: Int)
    case failed(String)
}

enum MeetingRecorderError: LocalizedError {
    case alreadyRecording
    case microphonePermissionMissing
    case transcriberUnavailable
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A meeting is already being recorded"
        case .microphonePermissionMissing: return "Hearsay needs microphone access to record meetings"
        case .transcriberUnavailable: return "Install a speech model before recording a meeting"
        case .captureFailed(let message): return message
        }
    }
}

/// Records a meeting: microphone ("You") and system audio ("the call") as two
/// aligned tracks, transcribed utterance by utterance while the meeting runs,
/// with the call side split into speakers by a streaming diarizer.
///
/// Main-thread API. Audio is processed on a private serial queue.
final class MeetingRecorder {

    static let shared = MeetingRecorder()

    /// Supplies the active speech backend (owned by AppDelegate).
    var transcriberProvider: (() -> (any SpeechTranscribing)?)?

    private(set) var live: MeetingLiveState?
    var isRecording: Bool { live?.phase == .recording }
    var isActive: Bool { live != nil }
    var currentMeetingID: UUID? { live?.meetingID }

    private var observers: [(MeetingRecorderEvent) -> Void] = []

    // Session state (main thread)
    /// The store is the source of truth: the UI may rename, edit or reassign
    /// speakers while we record, so always read-modify-write through it.
    private var meetingID: UUID?
    private var document: MeetingDocument? { meetingID.flatMap { MeetingStore.shared.document(id: $0) } }
    private var transcriber: (any SpeechTranscribing)?
    private var micCapture: MeetingMicrophoneCapture?
    private var systemTap: AnyObject?
    private var diarizer: MeetingDiarizer?
    private var diarizerFeed: AsyncStream<[Float]>.Continuation?
    private var diarizerFeedTask: Task<Void, Never>?
    private var stopDate: Date?
    /// Keeps App Nap from throttling timers and the Mac from idle-sleeping mid-meeting.
    private var activity: NSObjectProtocol?
    private var monitorTimer: Timer?
    private var partialTimer: Timer?
    private var relabelTimer: Timer?
    private var silenceReminderSent = false
    /// When the latest goodbye was heard (cleared when the conversation goes on).
    private var goodbyeHeardAt: Date?
    private var wrapUpPrompted = false
    private var nextPartialChannel: MeetingSegment.Channel = .microphone
    private var lastPartialLength: [MeetingSegment.Channel: (ordinal: Int, samples: Int)] = [:]

    // Transcription queue (main thread)
    private struct Job {
        let channel: MeetingSegment.Channel
        let segment: SpeechSegmenter.Segment
    }
    private var pendingJobs: [Job] = []
    private var isTranscribing = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    // Processing queue state
    private let processingQueue = DispatchQueue(label: "com.swair.hearsay.meeting.processing", qos: .userInitiated)
    private var micTrack: MeetingTrack?
    private var systemTrack: MeetingTrack?
    private var diarizationBuffer: [Float] = []
    private var feedsDiarizer = false
    private var replayTimer: DispatchSourceTimer?
    private var lastLevelPost = Date.distantPast

    private init() {}

    // MARK: - Observers

    /// Events arrive on the main queue. Observers live for the app's lifetime.
    func addObserver(_ observer: @escaping (MeetingRecorderEvent) -> Void) {
        observers.append(observer)
    }

    private func emit(_ event: MeetingRecorderEvent) {
        for observer in observers { observer(event) }
    }

    // MARK: - Start

    /// Pre-recorded tracks to run through the live pipeline instead of the
    /// microphone and system tap. Used for testing and benchmarking.
    struct ReplaySource {
        var microphone: URL?
        var system: URL?
        /// 1 = real time. Higher values feed audio faster than it was spoken.
        var speed: Double = 1
    }

    @discardableResult
    func start(title: String? = nil, source: String? = nil, replay: ReplaySource? = nil) throws -> UUID {
        guard live == nil else { throw MeetingRecorderError.alreadyRecording }
        if replay == nil {
            guard PermissionsManager.checkMicrophone() == .granted else {
                throw MeetingRecorderError.microphonePermissionMissing
            }
        }
        guard let transcriber = transcriberProvider?() else {
            throw MeetingRecorderError.transcriberUnavailable
        }

        let startedAt = Date()
        var document = MeetingDocument(
            title: title ?? Self.defaultTitle(source: source),
            startedAt: startedAt,
            source: source ?? (replay != nil ? "Replay" : nil)
        )
        let directory = MeetingPaths.directory(for: document.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Tracks first, so no early audio is dropped.
        let micTrack = MeetingTrack(channel: .microphone, directory: directory, fileName: "microphone.caf")
        let systemTrack = MeetingTrack(channel: .system, directory: directory, fileName: "system.caf")
        // The diarizer must see the system track from sample zero, or its
        // timeline drifts from the transcript's — so set it up before capture.
        let wantsDiarizer = MeetingSettings.speakerDetection && MeetingDiarizer.isSupported
            && (replay == nil || replay?.system != nil)
        processingQueue.sync {
            self.micTrack = micTrack
            self.systemTrack = systemTrack
            self.diarizationBuffer = []
            self.feedsDiarizer = wantsDiarizer
        }
        if wantsDiarizer {
            startDiarizer()
        }

        var systemAvailable = false
        var replayAudio: (microphone: [Float], system: [Float])?

        if let replay {
            do {
                let mic = try replay.microphone.map(MeetingAudioIO.readMonoSamples) ?? []
                let system = try replay.system.map(MeetingAudioIO.readMonoSamples) ?? []
                replayAudio = (mic, system)
                systemAvailable = replay.system != nil
            } catch {
                abortStart(directory: directory)
                throw MeetingRecorderError.captureFailed("Couldn't read replay audio: \(error.localizedDescription)")
            }
        } else {
            // Microphone (required).
            let mic = MeetingMicrophoneCapture()
            mic.onSamples = { [weak self] samples in
                // Stamp on arrival, not when the processing queue gets to it.
                let elapsed = Date().timeIntervalSince(startedAt)
                self?.processingQueue.async {
                    self?.ingest(samples, channel: .microphone, elapsed: elapsed)
                }
            }
            mic.onError = { [weak self] message in
                self?.emit(.failed(message))
            }
            do {
                try mic.start()
            } catch {
                abortStart(directory: directory)
                throw MeetingRecorderError.captureFailed("Couldn't start the microphone: \(error.localizedDescription)")
            }
            self.micCapture = mic

            // System audio (best effort: falls back to a mic-only recording).
            if #available(macOS 14.2, *) {
                let tap = SystemAudioTap()
                tap.onSamples = { [weak self] samples in
                    let elapsed = Date().timeIntervalSince(startedAt)
                    self?.processingQueue.async {
                        self?.ingest(samples, channel: .system, elapsed: elapsed)
                    }
                }
                do {
                    try tap.start()
                    systemTap = tap
                    systemAvailable = true
                } catch {
                    recorderLogger.error("System audio unavailable: \(error.localizedDescription, privacy: .public)")
                    diagnosticLog.event("meeting.system_audio_failed", level: .warning, fields: diagnosticLog.errorFields(for: error))
                }
            }
        }
        if !systemAvailable {
            document.microphoneOnly = true
            stopDiarizer()
        }

        self.meetingID = document.id
        self.transcriber = transcriber
        self.stopDate = nil
        self.silenceReminderSent = false
        self.goodbyeHeardAt = nil
        self.wrapUpPrompted = false
        self.lastPartialLength = [:]
        self.pendingJobs = []

        var state = MeetingLiveState(meetingID: document.id, startedAt: startedAt, lastSpeechAt: startedAt)
        state.systemAudioAvailable = systemAvailable
        state.speakerDetection = diarizer != nil ? .loading : .off
        live = state

        MeetingStore.shared.save(document)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recording a meeting"
        )
        startTimers()
        if let replayAudio {
            startReplay(microphone: replayAudio.microphone, system: replayAudio.system, speed: max(0.1, replay?.speed ?? 1))
        }

        recorderLogger.notice("Meeting \(document.shortID, privacy: .public) started system_audio=\(systemAvailable)")
        diagnosticLog.event("meeting.start", fields: [
            "id": document.shortID,
            "system_audio": "\(systemAvailable)",
            "source": source ?? "manual"
        ])
        emit(.started(document.id))
        return document.id
    }

    private static func defaultTitle(source: String?) -> String {
        if let source { return "\(source) call" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "morning" : (hour < 17 ? "afternoon" : "evening")
        return "\(formatter.string(from: Date())) \(part) meeting"
    }

    private func abortStart(directory: URL) {
        stopDiarizer()
        processingQueue.sync { self.micTrack = nil; self.systemTrack = nil }
        try? FileManager.default.removeItem(at: directory)
    }

    private func stopDiarizer() {
        processingQueue.sync { self.feedsDiarizer = false }
        diarizerFeed?.finish()
        diarizerFeed = nil
        if let diarizer {
            Task { await diarizer.shutdown() }
        }
        diarizer = nil
        diarizerFeedTask = nil
    }

    private func startDiarizer() {
        let diarizer = MeetingDiarizer()
        self.diarizer = diarizer

        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        diarizerFeed = continuation
        diarizerFeedTask = Task {
            await diarizer.startSession()
            for await chunk in stream {
                await diarizer.push(chunk)
            }
        }

        // Reflect model loading in the UI once it settles.
        Task { [weak self] in
            for _ in 0..<600 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let state = await diarizer.state
                guard let self else { return }
                let done: Bool = await MainActor.run {
                    guard self.diarizer === diarizer, self.live != nil else { return true }
                    switch state {
                    case .ready:
                        self.live?.speakerDetection = .active
                    case .failed(let message):
                        self.live?.speakerDetection = .unavailable(message)
                    case .idle, .loading:
                        return false
                    }
                    self.emit(.liveUpdated)
                    return true
                }
                if done { return }
            }
        }
    }

    // MARK: - Stop

    enum StopReason {
        case user
        case silence(minutes: Int)
        case appQuitting
    }

    /// Stop capturing and finish the transcript in the background.
    /// `completion` runs (on main) once the meeting is fully saved.
    func stop(reason: StopReason = .user, completion: (() -> Void)? = nil) {
        guard var state = live, state.phase == .recording, let document else {
            completion?()
            return
        }
        let id = document.id
        stopDate = Date()
        state.phase = .finishing
        state.partials = [:]
        live = state
        stopTimers()

        micCapture?.stop()
        micCapture = nil
        if #available(macOS 14.2, *) {
            (systemTap as? SystemAudioTap)?.stop()
        }
        systemTap = nil

        if var current = self.document {
            current.status = .processing
            current.endedAt = stopDate
            MeetingStore.shared.save(current)
        }

        recorderLogger.notice("Meeting \(document.shortID, privacy: .public) stopping")
        diagnosticLog.event("meeting.stop", fields: ["id": document.shortID])
        emit(.stopping(id))
        if case .silence(let minutes) = reason {
            emit(.autoStopped(id, minutes: minutes))
        }

        processingQueue.async { [self] in
            replayTimer?.cancel()
            replayTimer = nil
            var closing: [Job] = []
            if let segment = micTrack?.finish() { closing.append(Job(channel: .microphone, segment: segment)) }
            if let segment = systemTrack?.finish() { closing.append(Job(channel: .system, segment: segment)) }
            let tail = diarizationBuffer
            diarizationBuffer = []
            feedsDiarizer = false
            micTrack = nil
            systemTrack = nil

            DispatchQueue.main.async { [self] in
                if !tail.isEmpty { diarizerFeed?.yield(tail) }
                diarizerFeed?.finish()
                diarizerFeed = nil
                for job in closing.sorted(by: { $0.segment.startSample < $1.segment.startSample }) {
                    enqueue(job)
                }
                Task {
                    await self.finish(meetingID: id)
                    await MainActor.run { completion?() }
                }
            }
        }
    }

    private func finish(meetingID: UUID) async {
        await waitForTranscriptionQueue()
        await diarizerFeedTask?.value

        if let diarizer {
            await diarizer.finishSession()
            await relabelSystemSegments(since: nil)
            await diarizer.shutdown()
        }

        // Whole-recording speaker pass, run once the meeting is saved. Needs the
        // call track: the uncompressed one if audio isn't being kept.
        let directory = MeetingPaths.directory(for: meetingID)
        let refine = diarizer != nil && FileManager.default.fileExists(atPath: directory.appendingPathComponent("system.caf").path)
        let audio = await finalizeAudio(meetingID: meetingID, keepingSystemTrack: refine)

        await MainActor.run {
            // Deleted while finishing: don't resurrect it.
            if var document = self.document, document.id == meetingID {
                document.status = .completed
                document.endedAt = self.stopDate ?? Date()
                document.audio = audio
                MeetingStore.shared.save(document)

                recorderLogger.notice("Meeting \(document.shortID, privacy: .public) saved segments=\(document.segments.count)")
                diagnosticLog.event("meeting.saved", fields: [
                    "id": document.shortID,
                    "segments": "\(document.visibleSegments.count)",
                    "speakers": "\(document.activeSpeakers.count)",
                    "duration_seconds": String(format: "%.0f", document.duration())
                ])
            }

            if let activity = self.activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
            self.meetingID = nil
            self.transcriber = nil
            self.diarizer = nil
            self.diarizerFeedTask = nil
            self.live = nil
            self.emit(.finished(meetingID))

            if refine, MeetingStore.shared.document(id: meetingID) != nil {
                let temporaryTrack = audio?.system == nil ? directory.appendingPathComponent("system.caf") : nil
                MeetingSpeakerTools.refineSpeakers(meetingID: meetingID, audioURL: temporaryTrack) { _ in
                    if let temporaryTrack { try? FileManager.default.removeItem(at: temporaryTrack) }
                }
            }
        }
    }

    /// Compress the CAF tracks to AAC, or delete them if audio isn't kept
    /// (except the call track when the speaker pass still needs it).
    private func finalizeAudio(meetingID: UUID, keepingSystemTrack: Bool) async -> MeetingAudioFiles? {
        let directory = MeetingPaths.directory(for: meetingID)
        let tracks = ["microphone.caf", "system.caf"].map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        guard MeetingSettings.keepAudio else {
            for track in tracks where !(keepingSystemTrack && track.lastPathComponent == "system.caf") {
                try? FileManager.default.removeItem(at: track)
            }
            return nil
        }

        var files = MeetingAudioFiles()
        for track in tracks {
            let stored: URL
            do {
                stored = try await MeetingAudioIO.compressToAAC(track)
            } catch {
                recorderLogger.error("Keeping uncompressed track: \(error.localizedDescription, privacy: .public)")
                stored = track
            }
            if track.lastPathComponent.hasPrefix("microphone") {
                files.microphone = stored.lastPathComponent
            } else {
                files.system = stored.lastPathComponent
            }
        }
        return files.microphone == nil && files.system == nil ? nil : files
    }

    /// Stop immediately without finishing transcription (app is terminating).
    func abandonForTermination() {
        guard live != nil, var document else { return }
        micCapture?.stop()
        if #available(macOS 14.2, *) {
            (systemTap as? SystemAudioTap)?.stop()
        }
        processingQueue.sync {
            _ = micTrack?.finish()
            _ = systemTrack?.finish()
        }
        document.status = .interrupted
        document.endedAt = stopDate ?? Date()
        // Point at whatever audio exists so it isn't orphaned (CAF until compressed).
        let directory = MeetingPaths.directory(for: document.id)
        func existing(_ names: [String]) -> String? {
            names.first { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        }
        let audio = MeetingAudioFiles(
            microphone: existing(["microphone.m4a", "microphone.caf"]),
            system: existing(["system.m4a", "system.caf"])
        )
        document.audio = audio.microphone == nil && audio.system == nil ? nil : audio
        MeetingStore.shared.save(document)
        MeetingStore.shared.flush()
        meetingID = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        live = nil
    }

    /// Restart the silence countdown ("Keep recording").
    func snoozeSilenceReminder() {
        live?.lastSpeechAt = Date()
        silenceReminderSent = false
    }

    // MARK: - Audio processing (processingQueue)

    /// Feeds pre-recorded tracks through `ingest` in 100 ms steps on a virtual clock.
    private func startReplay(microphone: [Float], system: [Float], speed: Double) {
        let step = Int(MeetingAudioIO.sampleRate / 10)
        let total = max(microphone.count, system.count)
        var position = 0
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now(), repeating: 0.1 / speed)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let end = min(position + step, total)
            let elapsed = TimeInterval(end) / MeetingAudioIO.sampleRate
            if position < microphone.count {
                self.ingest(Array(microphone[position..<min(end, microphone.count)]), channel: .microphone, elapsed: elapsed)
            }
            if position < system.count {
                self.ingest(Array(system[position..<min(end, system.count)]), channel: .system, elapsed: elapsed)
            }
            position = end
            if position >= total {
                timer.cancel()
                self.replayTimer = nil
                DispatchQueue.main.async { self.stop() }
            }
        }
        replayTimer = timer
        timer.resume()
    }

    /// `elapsed` is the meeting clock at the end of `samples`.
    private func ingest(_ samples: [Float], channel: MeetingSegment.Channel, elapsed: TimeInterval) {
        guard let track = channel == .microphone ? micTrack : systemTrack else { return }
        let closed = track.ingest(samples, elapsed: elapsed)

        if channel == .system, feedsDiarizer {
            diarizationBuffer.append(contentsOf: track.lastIngestedWithPadding)
            if diarizationBuffer.count >= Int(MeetingAudioIO.sampleRate * 2) {
                let chunk = diarizationBuffer
                diarizationBuffer = []
                DispatchQueue.main.async { [weak self] in self?.diarizerFeed?.yield(chunk) }
            }
        }

        let now = Date()
        let speaking = track.segmenter.isInUtterance
        let postLevels = now.timeIntervalSince(lastLevelPost) > 0.12
        if postLevels { lastLevelPost = now }

        guard !closed.isEmpty || postLevels || speaking else { return }
        let micLevel = micTrack?.segmenter.level ?? 0
        let systemLevel = systemTrack?.segmenter.level ?? 0
        let micSpeaking = micTrack?.segmenter.isInUtterance ?? false
        let systemSpeaking = systemTrack?.segmenter.isInUtterance ?? false

        DispatchQueue.main.async { [weak self] in
            guard let self, self.live != nil else { return }
            // Utterances that closed just before Stop must still be transcribed.
            for segment in closed {
                self.enqueue(Job(channel: channel, segment: segment))
            }
            guard self.live?.phase == .recording else { return }
            self.live?.micLevel = micLevel
            self.live?.systemLevel = systemLevel
            self.live?.micSpeaking = micSpeaking
            self.live?.systemSpeaking = systemSpeaking
            if postLevels || !closed.isEmpty {
                self.emit(.liveUpdated)
            }
        }
    }

    // MARK: - Transcription queue (main)

    private func enqueue(_ job: Job) {
        pendingJobs.append(job)
        pumpTranscription()
    }

    private func pumpTranscription() {
        guard !isTranscribing else { return }
        guard !pendingJobs.isEmpty, let transcriber else {
            let waiters = drainWaiters
            drainWaiters = []
            waiters.forEach { $0.resume() }
            return
        }
        let job = pendingJobs.removeFirst()
        isTranscribing = true
        Task {
            let text = await Self.transcribe(job.segment.samples, with: transcriber)
            await MainActor.run {
                self.isTranscribing = false
                self.handleFinal(job, text: text)
                self.pumpTranscription()
            }
        }
    }

    private func waitForTranscriptionQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                if !self.isTranscribing && self.pendingJobs.isEmpty {
                    continuation.resume()
                } else {
                    self.drainWaiters.append(continuation)
                }
            }
        }
    }

    private static func transcribe(_ samples: [Float], with transcriber: any SpeechTranscribing) async -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hearsay-meeting-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try MeetingAudioIO.writeWAV(samples, to: url)
            let text = try await transcriber.transcribe(audioURL: url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch SpeechTranscriptionError.noOutput {
            return nil
        } catch {
            recorderLogger.error("Meeting segment transcription failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func handleFinal(_ job: Job, text: String?) {
        if live?.partials[job.channel]?.ordinal == job.segment.ordinal {
            live?.partials[job.channel] = nil
        }
        guard let heard = text, var document else {
            emit(.liveUpdated)
            return
        }
        // Vocabulary aliases are part of recognition, so they land in originalText too.
        let text = VocabularyStore.shared.applyAliases(to: heard)
        if live?.phase == .recording {
            noteWords(text)
        }

        let speakerID = job.channel == .microphone ? MeetingSpeaker.meID : MeetingSpeaker.themID
        var segment = MeetingSegment(
            speakerID: speakerID,
            channel: job.channel,
            start: job.segment.startTime,
            end: job.segment.endTime,
            text: text
        )

        if MeetingSettings.suppressEcho {
            if job.channel == .microphone {
                for other in document.segments where other.channel == .system {
                    segment = Self.applyEcho(MeetingEchoDetector.resolve(mic: segment, system: other), to: segment)
                    if segment.suppressed == true { break }
                }
            } else {
                for index in document.segments.indices
                where document.segments[index].channel == .microphone && document.segments[index].suppressed != true {
                    let resolution = MeetingEchoDetector.resolve(mic: document.segments[index], system: segment)
                    document.segments[index] = Self.applyEcho(resolution, to: document.segments[index])
                }
            }
        }

        let insertAt = document.segments.firstIndex(where: { $0.start > segment.start }) ?? document.segments.endIndex
        document.segments.insert(segment, at: insertAt)
        MeetingStore.shared.update(document)
        emit(.liveUpdated)

        if job.channel == .system, let diarizer {
            let segmentID = segment.id
            let range = segment.start...segment.end
            Task {
                let slots = await diarizer.assign([range])
                await MainActor.run { self.applySpeakerSlots([(segmentID, slots.first ?? nil)]) }
            }
        }
    }

    /// Echo text isn't something you said, so trimming rewrites the original too.
    private static func applyEcho(_ resolution: MeetingEchoDetector.Resolution, to segment: MeetingSegment) -> MeetingSegment {
        var segment = segment
        switch resolution {
        case .keep:
            break
        case .suppress:
            segment.suppressed = true
        case .trimmed(let text):
            segment.originalText = text
            if segment.edited != true { segment.text = text }
        }
        return segment
    }

    // MARK: - Speakers

    /// Re-ask the diarizer about recent (or all) call segments; labels firm up
    /// once the model has seen more context.
    private func relabelSystemSegments(since cutoff: TimeInterval?) async {
        guard let diarizer else { return }
        let targets: [(UUID, ClosedRange<TimeInterval>)] = await MainActor.run {
            (self.document?.segments ?? [])
                .filter { $0.channel == .system && $0.manualSpeaker != true }
                .filter { cutoff == nil || $0.end >= cutoff! }
                .map { ($0.id, $0.start...$0.end) }
        }
        guard !targets.isEmpty else { return }
        let slots = await diarizer.assign(targets.map(\.1))
        await MainActor.run {
            self.applySpeakerSlots(Array(zip(targets.map(\.0), slots)))
        }
    }

    private func applySpeakerSlots(_ assignments: [(UUID, Int?)]) {
        guard var document else { return }
        var changed = false
        for (segmentID, slot) in assignments {
            guard let slot, let index = document.segments.firstIndex(where: { $0.id == segmentID }),
                  document.segments[index].manualSpeaker != true else { continue }
            let speakerID = MeetingSpeaker.remoteID(forSlot: slot)
            if document.speaker(id: speakerID) == nil {
                document.speakers.append(MeetingSpeaker.remote(slot: slot))
            }
            if document.segments[index].speakerID != speakerID {
                document.segments[index].speakerID = speakerID
                changed = true
            }
        }
        guard changed else { return }
        MeetingStore.shared.update(document)
        emit(.liveUpdated)
    }

    // MARK: - Partial transcription

    private var supportsLivePreview: Bool {
        // qwen_asr starts a process per call, which is too slow to re-run every second.
        transcriber is ParakeetTranscriber || transcriber is WhisperTranscriber
    }

    private func transcribePartialIfIdle() {
        guard MeetingSettings.livePreview, supportsLivePreview, live?.phase == .recording,
              !isTranscribing, pendingJobs.isEmpty, let transcriber else { return }

        let channel = nextPartialChannel
        nextPartialChannel = channel == .microphone ? .system : .microphone
        let snapshot: SpeechSegmenter.Segment? = processingQueue.sync {
            (channel == .microphone ? micTrack : systemTrack)?.segmenter.openUtterance()
        }
        guard let snapshot, snapshot.duration >= 1.2 else { return }
        if let last = lastPartialLength[channel], last.ordinal == snapshot.ordinal,
           snapshot.samples.count - last.samples < Int(MeetingAudioIO.sampleRate * 0.8) {
            return
        }
        lastPartialLength[channel] = (snapshot.ordinal, snapshot.samples.count)

        isTranscribing = true
        Task {
            let text = await Self.transcribe(snapshot.samples, with: transcriber)
            await MainActor.run {
                self.isTranscribing = false
                if let text, self.live?.phase == .recording {
                    self.noteSpeech()
                    self.live?.partials[channel] = MeetingLiveState.Partial(
                        ordinal: snapshot.ordinal,
                        start: snapshot.startTime,
                        text: text
                    )
                    self.emit(.liveUpdated)
                }
                self.pumpTranscription()
            }
        }
    }

    // MARK: - Timers & silence

    private func startTimers() {
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkSilence()
        }
        partialTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.transcribePartialIfIdle()
        }
        relabelTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, let live = self.live else { return }
            Task { await self.relabelSystemSegments(since: max(0, live.elapsed - 120)) }
        }
        for timer in [monitorTimer, partialTimer, relabelTimer] {
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
    }

    private func stopTimers() {
        monitorTimer?.invalidate()
        partialTimer?.invalidate()
        relabelTimer?.invalidate()
        monitorTimer = nil
        partialTimer = nil
        relabelTimer = nil
    }

    /// Silence is measured in words, not sound: music, a video or room noise
    /// after the call shouldn't keep the "still in the meeting?" timer at bay.
    private func noteSpeech() {
        live?.lastSpeechAt = Date()
        silenceReminderSent = false
    }

    /// A finished utterance: words were spoken, and maybe a goodbye.
    private func noteWords(_ text: String) {
        noteSpeech()
        if MeetingWrapUpDetector.isClosing(text) {
            goodbyeHeardAt = Date()
            wrapUpPrompted = false
        } else if MeetingWrapUpDetector.wordCount(text) >= MeetingWrapUpDetector.continuationWords {
            goodbyeHeardAt = nil
        }
    }

    private func checkSilence() {
        guard let live, live.phase == .recording else { return }
        let quiet = Date().timeIntervalSince(live.lastSpeechAt)
        let silentMinutes = quiet / 60

        if MeetingSettings.askAfterGoodbyes, goodbyeHeardAt != nil, !wrapUpPrompted,
           quiet >= MeetingWrapUpDetector.quietSeconds {
            wrapUpPrompted = true
            recorderLogger.notice("Goodbye followed by \(Int(quiet))s of quiet; suggesting stop")
            emit(.wrapUpSuggested)
        }

        let autoStop = MeetingSettings.autoStopSilenceMinutes
        if autoStop > 0, silentMinutes >= Double(autoStop) {
            recorderLogger.notice("Auto-stopping meeting after \(autoStop) silent minutes")
            stop(reason: .silence(minutes: autoStop))
            return
        }

        let reminder = MeetingSettings.silenceReminderMinutes
        if reminder > 0, silentMinutes >= Double(reminder), !silenceReminderSent {
            silenceReminderSent = true
            emit(.silenceReminder(minutes: reminder))
        }
    }
}

/// One audio track of a meeting: aligned to wall-clock time, written to disk,
/// and split into utterances. Lives on the recorder's processing queue.
private final class MeetingTrack {
    let channel: MeetingSegment.Channel
    let segmenter: SpeechSegmenter
    private var writer: AVAudioFile?
    private(set) var samplesWritten = 0
    /// The audio appended by the last `ingest` call, including any gap padding.
    private(set) var lastIngestedWithPadding: [Float] = []

    /// Pad with silence when the track falls this far behind the meeting clock
    /// (late start, route change, sleep), so both tracks share one timeline.
    private static let realignThreshold = Int(MeetingAudioIO.sampleRate * 0.25)
    private static let maxPadding = Int(MeetingAudioIO.sampleRate * 600)

    init(channel: MeetingSegment.Channel, directory: URL, fileName: String) {
        self.channel = channel
        self.segmenter = SpeechSegmenter(config: channel == .microphone ? .microphone : .system)
        do {
            writer = try MeetingAudioIO.makeTrackWriter(at: directory.appendingPathComponent(fileName))
        } catch {
            recorderLogger.error("Couldn't create \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func ingest(_ samples: [Float], elapsed: TimeInterval) -> [SpeechSegmenter.Segment] {
        let expectedStart = Int(elapsed * MeetingAudioIO.sampleRate) - samples.count
        let gap = expectedStart - samplesWritten
        var audio = samples
        if gap > Self.realignThreshold {
            audio = [Float](repeating: 0, count: min(gap, Self.maxPadding)) + samples
        }
        lastIngestedWithPadding = audio

        if let writer, let buffer = MeetingAudioIO.makeBuffer(audio) {
            try? writer.write(from: buffer)
        }
        samplesWritten += audio.count
        return segmenter.append(audio)
    }

    /// Close the file and return the utterance still in progress, if any.
    func finish() -> SpeechSegmenter.Segment? {
        writer = nil
        return segmenter.flush()
    }
}
