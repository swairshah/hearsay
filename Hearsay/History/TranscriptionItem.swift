import Foundation

/// Represents a single transcription in history.
struct TranscriptionItem: Codable, Identifiable {
    let id: UUID
    let text: String
    let timestamp: Date
    let durationSeconds: Double
    let audioFilePath: String?
    
    init(text: String, durationSeconds: Double, audioFilePath: String? = nil) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.durationSeconds = durationSeconds
        self.audioFilePath = audioFilePath
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
        let truncated = text.prefix(40)
        return truncated.count < text.count ? "\(truncated)..." : String(truncated)
    }
}
