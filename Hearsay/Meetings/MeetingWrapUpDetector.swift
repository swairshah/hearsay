import Foundation

/// Spots goodbyes ("thanks everyone", "bye", "talk soon") at the end of an
/// utterance, so the recorder can ask whether the meeting is over once the
/// conversation goes quiet. It only ever suggests; stopping is the user's call.
enum MeetingWrapUpDetector {

    /// How long nobody may speak after a goodbye before we ask.
    static let quietSeconds: TimeInterval = 30

    /// A goodbye only counts near the end of an utterance: "Thanks everyone
    /// for joining, let's get started" opens a meeting rather than closing it.
    private static let tailWords = 6

    /// A later utterance at least this long means the conversation went on.
    static let continuationWords = 4

    private static let phrases: [[String]] = [
        "bye", "goodbye", "see you", "see ya", "talk soon", "talk later", "talk to you later",
        "catch you later", "take care", "have a good one", "signing off",
        "that's all for today", "that's it for today",
        "thanks for joining", "thank you for joining", "thanks for coming", "thank you for coming",
        "thanks for your time", "thank you for your time",
    ].map(words) + ["thanks", "thank you"].flatMap { thanks in
        ["everyone", "everybody", "all", "guys", "folks", "y'all"].map { words("\(thanks) \($0)") }
    } + ["good", "great", "nice"].flatMap { adjective in
        ["day", "week", "weekend", "night", "evening", "afternoon"].map { words("have a \(adjective) \($0)") }
    }

    static func isClosing(_ text: String) -> Bool {
        let spoken = words(text)
        guard !spoken.isEmpty else { return false }
        let tailStart = max(0, spoken.count - tailWords)
        for phrase in phrases where phrase.count <= spoken.count {
            for start in 0...(spoken.count - phrase.count) where start + phrase.count > tailStart {
                if Array(spoken[start..<start + phrase.count]) == phrase { return true }
            }
        }
        return false
    }

    static func wordCount(_ text: String) -> Int {
        words(text).count
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0 == "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }
}
