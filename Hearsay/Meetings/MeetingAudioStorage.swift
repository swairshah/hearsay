import Foundation
import os.log

private let storageLogger = Logger(subsystem: "com.swair.hearsay", category: "meeting-storage")

/// Keeps saved meeting audio under the size set in Meetings settings by
/// deleting the oldest meetings' audio. Transcripts are never touched.
/// Main-thread API (it goes through `MeetingStore`).
enum MeetingAudioStorage {

    private static let trackNames = ["microphone.m4a", "system.m4a", "microphone.caf", "system.caf"]

    /// Bytes of audio saved across all meetings.
    static func totalBytes() -> Int64 {
        MeetingStore.shared.summaries.reduce(0) { $0 + audioBytes(of: $1.id) }
    }

    /// Delete the oldest meetings' audio until the total fits the limit.
    /// Meetings still recording or being processed are left alone.
    static func enforceLimit() {
        let limitGB = MeetingSettings.audioLimitGB
        guard limitGB > 0 else { return }
        let limit = Int64(limitGB) * 1_000_000_000
        var total = totalBytes()
        guard total > limit else { return }

        let oldestFirst = MeetingStore.shared.summaries
            .filter { $0.status == .completed || $0.status == .interrupted }
            .sorted { $0.startedAt < $1.startedAt }
        var cleared = 0
        for summary in oldestFirst where total > limit {
            guard !MeetingSpeakerTools.isRefining(summary.id),
                  MeetingRecorder.shared.live?.meetingID != summary.id else { continue }
            let bytes = audioBytes(of: summary.id)
            guard bytes > 0 else { continue }
            deleteAudio(of: summary.id)
            total -= bytes
            cleared += 1
        }
        storageLogger.notice("Meeting audio over \(limitGB)GB limit: cleared audio from \(cleared) meetings, now \(total / 1_000_000)MB")
    }

    private static func audioURLs(of id: UUID) -> [URL] {
        let directory = MeetingPaths.directory(for: id)
        return trackNames.map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func audioBytes(of id: UUID) -> Int64 {
        audioURLs(of: id).reduce(0) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    private static func deleteAudio(of id: UUID) {
        for url in audioURLs(of: id) {
            try? FileManager.default.removeItem(at: url)
        }
        MeetingStore.shared.modify(id: id) { $0.audio = nil }
    }
}
