import Foundation

/// Represents a single transcription in history.
struct TranscriptionItem: Codable, Identifiable {
    let id: UUID
    let text: String
    let timestamp: Date
    let durationSeconds: Double
    let audioFilePath: String?
    /// nil/false = succeeded. true = transcription failed; the audio is retained
    /// (at `audioFilePath`) so it can be re-run. Optional for backward compatibility
    /// with history saved before this field existed.
    let failed: Bool?

    /// Whether this entry is a failed transcription awaiting retry.
    var isFailed: Bool { failed == true }

    init(text: String, durationSeconds: Double, audioFilePath: String? = nil, failed: Bool? = nil) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.durationSeconds = durationSeconds
        self.audioFilePath = audioFilePath
        self.failed = failed
    }

    /// Full initializer preserving identity — used when replacing an existing entry
    /// (e.g. updating a failed item to a successful one after a retry).
    init(id: UUID, text: String, timestamp: Date, durationSeconds: Double, audioFilePath: String?, failed: Bool?) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.audioFilePath = audioFilePath
        self.failed = failed
    }

    /// A copy with new text / failed state but the same identity, timestamp, and audio.
    func updating(text: String, failed: Bool?) -> TranscriptionItem {
        TranscriptionItem(id: id, text: text, timestamp: timestamp, durationSeconds: durationSeconds, audioFilePath: audioFilePath, failed: failed)
    }

    /// Formatted timestamp for display
    var formattedTime: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        
        if calendar.isDateInToday(timestamp) {
            formatter.dateFormat = "h:mm a"
            return "Today \(formatter.string(from: timestamp))"
        } else if calendar.isDateInYesterday(timestamp) {
            formatter.dateFormat = "h:mm a"
            return "Yesterday \(formatter.string(from: timestamp))"
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
            return formatter.string(from: timestamp)
        }
    }
    
    /// Truncated text for menu display
    var menuTitle: String {
        if isFailed { return "⚠️ Transcription failed" }
        let truncated = text.prefix(40)
        return truncated.count < text.count ? "\(truncated)..." : String(truncated)
    }
}
