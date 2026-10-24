import Foundation

/// Detects mic segments that are really the call playing through the Mac's
/// speakers. Both tracks then hear the same words at the same time, so the mic
/// copy is a duplicate. Comparing transcripts is cheap and doesn't need echo
/// cancellation (which would duck the call audio).
enum MeetingEchoDetector {

    /// Share of the mic segment's words that must appear, in order, in the call audio.
    /// Order matters: a reply that reuses the question's words ("can we ship
    /// Tuesday?" → "yes, we can ship Tuesday") is reordered and stays.
    static let similarityThreshold = 0.75
    /// Short replies ("yeah", "okay") are too ambiguous to drop.
    static let minimumWords = 3
    /// Allowed clock skew between the two tracks.
    static let overlapTolerance: TimeInterval = 1.5

    static func isEcho(mic: MeetingSegment, system: MeetingSegment) -> Bool {
        guard mic.channel == .microphone, system.channel == .system else { return false }
        guard mic.start < system.end + overlapTolerance, mic.end > system.start - overlapTolerance else { return false }

        let micWords = words(mic.originalText)
        guard micWords.count >= minimumWords else { return false }
        let shared = commonSubsequenceLength(micWords, words(system.originalText))
        return Double(shared) / Double(micWords.count) >= similarityThreshold
    }

    /// Shortest run of identical words treated as leaked call audio inside a
    /// longer mic utterance (e.g. the tail of a remote sentence, then you reply).
    static let minimumSpanWords = 4

    enum Resolution: Equatable {
        case keep
        /// The whole mic segment is a duplicate of the call.
        case suppress
        /// Part of it was; this is what you actually said.
        case trimmed(String)
    }

    /// Decide what to do with a mic segment given one overlapping call segment.
    static func resolve(mic: MeetingSegment, system: MeetingSegment) -> Resolution {
        if isEcho(mic: mic, system: system) { return .suppress }
        guard mic.channel == .microphone, system.channel == .system,
              mic.start < system.end + overlapTolerance, mic.end > system.start - overlapTolerance else { return .keep }

        // Tokens keep their original spelling/punctuation; comparison uses normalized words.
        var tokens = mic.text.split(whereSeparator: \.isWhitespace).map(String.init)
        // Tokenize both sides identically ("back-end" → "backend") so runs line up.
        let callWords = system.originalText.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
        var removedAny = false

        // Only trim runs that, by their position in the utterance, were spoken
        // while the call segment was playing — repeating someone later is fine.
        let duration = max(0.001, mic.end - mic.start)
        while let span = longestSharedRun(tokens.map(normalize), callWords), span.count >= minimumSpanWords {
            let count = Double(max(tokens.count, 1))
            let spanStart = mic.start + duration * Double(span.lowerBound) / count
            let spanEnd = mic.start + duration * Double(span.upperBound) / count
            guard spanStart < system.end + overlapTolerance, spanEnd > system.start - overlapTolerance else { break }
            tokens.removeSubrange(span)
            removedAny = true
        }
        guard removedAny else { return .keep }

        var remaining = tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = remaining.unicodeScalars.first, CharacterSet.punctuationCharacters.contains(first) {
            remaining = String(remaining.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if words(remaining).count < 2 { return .suppress }
        return .trimmed(capitalizeFirst(remaining))
    }

    /// Longest contiguous run of `mic` (by index range) that also appears contiguously in `call`.
    static func longestSharedRun(_ mic: [String], _ call: [String]) -> Range<Int>? {
        guard !mic.isEmpty, !call.isEmpty else { return nil }
        var best: Range<Int>?
        var previous = [Int](repeating: 0, count: call.count + 1)
        for i in 1...mic.count {
            var current = [Int](repeating: 0, count: call.count + 1)
            for j in 1...call.count where !mic[i - 1].isEmpty && mic[i - 1] == call[j - 1] {
                current[j] = previous[j - 1] + 1
                if current[j] > (best?.count ?? 0) {
                    best = (i - current[j])..<i
                }
            }
            previous = current
        }
        return best
    }

    private static func normalize(_ token: String) -> String {
        words(token).joined()
    }

    private static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Length of the longest common (not necessarily contiguous) word subsequence.
    static func commonSubsequenceLength(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            var current = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[b.count]
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
