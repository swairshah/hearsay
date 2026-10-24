import Foundation

// Shared between the Hearsay app and the `hearsay` CLI, so everything in this
// file must stay Foundation-only.

/// One recorded meeting as stored on disk at `Meetings/<id>/meeting.json`.
///
/// Times inside a meeting (`MeetingSegment.start`/`end`) are seconds from
/// `startedAt`, so the transcript stays aligned with the saved audio tracks.
struct MeetingDocument: Codable, Identifiable, Equatable {
    static let currentVersion = 1

    enum Status: String, Codable {
        /// Audio is still being captured.
        case recording
        /// Capture stopped; the last segments and speaker labels are being finalized.
        case processing
        case completed
        /// The app quit or crashed mid-recording; whatever was saved is kept.
        case interrupted
    }

    var version: Int
    let id: UUID
    var title: String
    let startedAt: Date
    var endedAt: Date?
    var status: Status
    /// Call app detected at start ("Zoom", "Google Meet", …), if any.
    var source: String?
    var speakers: [MeetingSpeaker]
    var segments: [MeetingSegment]
    var audio: MeetingAudioFiles?
    var processingPasses: [MeetingProcessingPass]?
    /// True when system audio could not be captured (mic-only recording).
    var microphoneOnly: Bool?

    init(id: UUID = UUID(), title: String, startedAt: Date = Date(), source: String? = nil) {
        self.version = Self.currentVersion
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = nil
        self.status = .recording
        self.source = source
        self.speakers = [MeetingSpeaker.me, MeetingSpeaker.them]
        self.segments = []
        self.audio = nil
        self.processingPasses = nil
        self.microphoneOnly = nil
    }

    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    var isLive: Bool { status == .recording }

    /// Wall-clock length. Live meetings measure up to `now`.
    func duration(now: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// Segments that belong in the transcript (echo duplicates are hidden).
    var visibleSegments: [MeetingSegment] {
        segments.filter { $0.suppressed != true }
    }

    func speaker(id: String) -> MeetingSpeaker? {
        speakers.first { $0.id == id }
    }

    func speakerName(for segment: MeetingSegment) -> String {
        speaker(id: segment.speakerID)?.name ?? segment.speakerID
    }

    /// Speakers that actually have visible speech, in first-spoke order.
    var activeSpeakers: [MeetingSpeaker] {
        var seen: [String] = []
        for segment in visibleSegments.sorted(by: { $0.start < $1.start }) where !seen.contains(segment.speakerID) {
            seen.append(segment.speakerID)
        }
        return seen.compactMap { speaker(id: $0) }
    }

    var hasProcessedText: Bool {
        segments.contains { $0.text != $0.originalText }
    }

    func summary() -> MeetingSummary {
        let visible = visibleSegments
        let preview = visible.first(where: { !$0.text.isEmpty }).map { String($0.text.prefix(160)) } ?? ""
        return MeetingSummary(
            id: id,
            title: title,
            startedAt: startedAt,
            endedAt: endedAt,
            status: status,
            source: source,
            durationSeconds: duration(),
            speakerNames: activeSpeakers.map(\.name),
            segmentCount: visible.count,
            wordCount: visible.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count },
            preview: preview
        )
    }
}

struct MeetingSpeaker: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        /// The person running Hearsay (microphone track).
        case local
        /// Someone on the call (system audio track).
        case remote
    }

    let id: String
    var name: String
    var kind: Kind
    /// Stable palette slot so a speaker keeps its colour across views.
    var colorIndex: Int

    static let meID = "me"
    static let themID = "them"

    static let me = MeetingSpeaker(id: meID, name: "You", kind: .local, colorIndex: 0)
    /// Remote audio before (or without) diarization.
    static let them = MeetingSpeaker(id: themID, name: "Others", kind: .remote, colorIndex: 1)

    /// Diarizer slot `index` (0-based) → stable speaker id.
    static func remoteID(forSlot index: Int) -> String { "s\(index + 1)" }

    static func remote(slot index: Int) -> MeetingSpeaker {
        MeetingSpeaker(id: remoteID(forSlot: index), name: "Speaker \(index + 1)", kind: .remote, colorIndex: index + 2)
    }
}

struct MeetingSegment: Codable, Equatable, Identifiable {
    enum Channel: String, Codable {
        case microphone
        case system
    }

    let id: UUID
    var speakerID: String
    let channel: Channel
    /// Seconds from the meeting start.
    var start: TimeInterval
    var end: TimeInterval
    /// What the speech model produced. Never modified, so passes can be reverted.
    var originalText: String
    /// What the transcript shows: original, post-processed, or hand-edited.
    var text: String
    var edited: Bool?
    /// The user picked this speaker by hand; diarization must not relabel it.
    var manualSpeaker: Bool?
    /// Hidden from the transcript, e.g. the mic picking up call audio from speakers.
    var suppressed: Bool?

    init(id: UUID = UUID(), speakerID: String, channel: Channel, start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.speakerID = speakerID
        self.channel = channel
        self.start = start
        self.end = end
        self.originalText = text
        self.text = text
        self.edited = nil
        self.manualSpeaker = nil
        self.suppressed = nil
    }
}

struct MeetingAudioFiles: Codable, Equatable {
    /// File names relative to the meeting folder.
    var microphone: String?
    var system: String?
}

struct MeetingProcessingPass: Codable, Equatable {
    enum Kind: String, Codable {
        case cleanup
        case llm
        case revert
    }

    var kind: Kind
    var date: Date
    var changedSegments: Int
}

/// Lightweight row in `Meetings/index.json` so lists don't load every transcript.
struct MeetingSummary: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var status: MeetingDocument.Status
    var source: String?
    var durationSeconds: TimeInterval
    var speakerNames: [String]
    var segmentCount: Int
    var wordCount: Int
    var preview: String

    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
}

// MARK: - Storage layout

enum MeetingPaths {
    static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hearsay/Meetings", isDirectory: true)
    }

    static var indexURL: URL {
        rootDirectory.appendingPathComponent("index.json")
    }

    static func directory(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func documentURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("meeting.json")
    }

    /// Markdown copy kept next to the JSON so agents and editors can read it directly.
    static func markdownURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("transcript.md")
    }
}

enum MeetingCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
