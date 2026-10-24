import Foundation
import os.log

private let meetingStoreLogger = Logger(subsystem: "com.swair.hearsay", category: "meetings")

/// Persists meetings under `Application Support/Hearsay/Meetings/`.
///
/// Layout (also read directly by the `hearsay` CLI):
/// - `index.json` — `[MeetingSummary]`, newest first
/// - `<id>/meeting.json` — the full `MeetingDocument`
/// - `<id>/transcript.md` — Markdown copy, rewritten on every save
/// - `<id>/microphone.m4a`, `<id>/system.m4a` — audio tracks (optional)
///
/// Main-thread API. Disk writes run on a private serial queue.
final class MeetingStore {

    static let shared = MeetingStore()

    private(set) var summaries: [MeetingSummary] = []
    private var documents: [UUID: MeetingDocument] = [:]
    private var changeObservers: [(Set<UUID>) -> Void] = []
    private var pendingSaves: [UUID: DispatchWorkItem] = [:]
    /// Deleted this session. Late writers (a meeting finishing in the
    /// background) must not bring these back.
    private var deletedIDs = Set<UUID>()
    private let ioQueue = DispatchQueue(label: "com.swair.hearsay.meetings.io", qos: .utility)

    private init() {
        try? FileManager.default.createDirectory(at: MeetingPaths.rootDirectory, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - Observers

    /// Called on the main queue with the ids that changed (empty = "reload everything").
    /// Observers live for the app's lifetime — capture `[weak self]`.
    func addChangeObserver(_ observer: @escaping (Set<UUID>) -> Void) {
        changeObservers.append(observer)
    }

    private func notifyChanged(_ ids: Set<UUID>) {
        for observer in changeObservers { observer(ids) }
    }

    // MARK: - Reading

    func document(id: UUID) -> MeetingDocument? {
        guard !deletedIDs.contains(id) else { return nil }
        if let cached = documents[id] { return cached }
        guard let data = try? Data(contentsOf: MeetingPaths.documentURL(for: id)),
              let document = try? MeetingCoding.makeDecoder().decode(MeetingDocument.self, from: data) else {
            return nil
        }
        documents[id] = document
        return document
    }

    func summaries(onDayOf date: Date, calendar: Calendar = .current) -> [MeetingSummary] {
        summaries
            .filter { calendar.isDate($0.startedAt, inSameDayAs: date) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Meeting counts keyed by start-of-day, for the calendar's activity dots.
    func meetingCountsByDay(calendar: Calendar = .current) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        for summary in summaries {
            counts[calendar.startOfDay(for: summary.startedAt), default: 0] += 1
        }
        return counts
    }

    var mostRecent: MeetingSummary? { summaries.first }

    struct SearchResult {
        let summary: MeetingSummary
        let matchCount: Int
        let snippet: String
    }

    /// Searches titles, speaker names and transcript text across every meeting.
    func search(_ query: String) -> [SearchResult] {
        guard let query = MeetingSearch.normalizedQuery(query) else { return [] }
        var results: [SearchResult] = []
        for summary in summaries {
            guard let document = document(id: summary.id) else { continue }
            let hits = MeetingSearch.hits(in: document, query: query)
            let titleMatch = document.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            let speakerMatch = document.speakers.contains {
                $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            guard !hits.isEmpty || titleMatch || speakerMatch else { continue }

            let snippet: String
            if let first = hits.first, let segment = document.segments.first(where: { $0.id == first.segmentID }) {
                snippet = "\(document.speakerName(for: segment)): " + MeetingSearch.snippet(for: query, in: segment.text, radius: 48)
            } else {
                snippet = summary.preview
            }
            results.append(SearchResult(
                summary: summary,
                matchCount: hits.reduce(0) { $0 + $1.ranges.count },
                snippet: snippet
            ))
        }
        return results
    }

    // MARK: - Writing

    /// Insert or replace a meeting and write it to disk now.
    func save(_ document: MeetingDocument) {
        guard !deletedIDs.contains(document.id) else { return }
        pendingSaves[document.id]?.cancel()
        pendingSaves[document.id] = nil
        documents[document.id] = document
        upsertSummary(document.summary())
        writeToDisk(document)
        writeIndex()
        notifyChanged([document.id])
    }

    /// Update in memory and observers immediately, coalescing disk writes.
    /// Used for the live meeting, which changes several times a second.
    func update(_ document: MeetingDocument, writeDelay: TimeInterval = 1.5) {
        guard !deletedIDs.contains(document.id) else { return }
        documents[document.id] = document
        upsertSummary(document.summary())
        notifyChanged([document.id])

        pendingSaves[document.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let latest = self.documents[document.id] else { return }
            self.pendingSaves[document.id] = nil
            self.writeToDisk(latest)
            self.writeIndex()
        }
        pendingSaves[document.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + writeDelay, execute: work)
    }

    /// Apply `change` to the stored meeting and save it.
    @discardableResult
    func modify(id: UUID, _ change: (inout MeetingDocument) -> Void) -> MeetingDocument? {
        guard var document = document(id: id) else { return nil }
        change(&document)
        save(document)
        return document
    }

    func delete(id: UUID) {
        deletedIDs.insert(id)
        pendingSaves[id]?.cancel()
        pendingSaves[id] = nil
        documents[id] = nil
        summaries.removeAll { $0.id == id }
        let directory = MeetingPaths.directory(for: id)
        ioQueue.async {
            try? FileManager.default.removeItem(at: directory)
        }
        writeIndex()
        meetingStoreLogger.info("Deleted meeting \(id.uuidString.prefix(8))")
        notifyChanged([id])
    }

    /// Write everything now and wait for the disk (call before the app exits).
    func flush() {
        let pending = pendingSaves
        pendingSaves = [:]
        for (id, work) in pending {
            work.cancel()
            if let document = documents[id] { writeToDisk(document) }
        }
        if !pending.isEmpty { writeIndex() }
        ioQueue.sync {}
    }

    /// Mark meetings left in `recording`/`processing` by a crash or force-quit.
    func recoverInterruptedMeetings(except activeID: UUID?) {
        for summary in summaries where summary.status == .recording || summary.status == .processing {
            guard summary.id != activeID, var document = document(id: summary.id) else { continue }
            document.status = .interrupted
            if document.endedAt == nil {
                let lastEnd = document.segments.map(\.end).max() ?? 0
                document.endedAt = document.startedAt.addingTimeInterval(lastEnd)
            }
            save(document)
            meetingStoreLogger.notice("Recovered interrupted meeting \(summary.shortID)")
        }
    }

    // MARK: - Disk

    private func upsertSummary(_ summary: MeetingSummary) {
        if let index = summaries.firstIndex(where: { $0.id == summary.id }) {
            summaries[index] = summary
        } else {
            summaries.append(summary)
        }
        summaries.sort { $0.startedAt > $1.startedAt }
    }

    private func writeToDisk(_ document: MeetingDocument) {
        let encoder = MeetingCoding.makeEncoder()
        guard let data = try? encoder.encode(document) else {
            meetingStoreLogger.error("Failed to encode meeting \(document.shortID)")
            return
        }
        let markdown = MeetingTranscriptFormatter.markdown(for: document)
        let directory = MeetingPaths.directory(for: document.id)
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: MeetingPaths.documentURL(for: document.id), options: .atomic)
                try markdown.write(to: MeetingPaths.markdownURL(for: document.id), atomically: true, encoding: .utf8)
            } catch {
                meetingStoreLogger.error("Failed to write meeting \(document.shortID): \(error.localizedDescription)")
            }
        }
    }

    private func writeIndex() {
        guard let data = try? MeetingCoding.makeEncoder().encode(summaries) else { return }
        ioQueue.async {
            try? data.write(to: MeetingPaths.indexURL, options: .atomic)
        }
    }

    private func loadIndex() {
        if let data = try? Data(contentsOf: MeetingPaths.indexURL),
           let decoded = try? MeetingCoding.makeDecoder().decode([MeetingSummary].self, from: data) {
            summaries = decoded.sorted { $0.startedAt > $1.startedAt }
            return
        }
        rebuildIndexFromDisk()
    }

    /// Recreate `index.json` from the meeting folders (missing or corrupt index).
    private func rebuildIndexFromDisk() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: MeetingPaths.rootDirectory, includingPropertiesForKeys: nil) else {
            summaries = []
            return
        }
        var rebuilt: [MeetingSummary] = []
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent), let document = document(id: id) else { continue }
            rebuilt.append(document.summary())
        }
        summaries = rebuilt.sorted { $0.startedAt > $1.startedAt }
        if !summaries.isEmpty {
            meetingStoreLogger.notice("Rebuilt meetings index with \(self.summaries.count) entries")
            writeIndex()
        }
    }
}
