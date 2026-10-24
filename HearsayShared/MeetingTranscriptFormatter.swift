import Foundation

/// A run of consecutive segments from one speaker, rendered as one paragraph.
struct MeetingTurn: Equatable {
    let speakerID: String
    let speakerName: String
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let segmentIDs: [UUID]
}

/// Renders meetings as Markdown or plain text (clipboard, share sheet, CLI).
enum MeetingTranscriptFormatter {

    /// Same-speaker segments further apart than this start a new turn.
    static let turnMergeGap: TimeInterval = 45

    static func turns(for document: MeetingDocument, original: Bool = false) -> [MeetingTurn] {
        let segments = document.visibleSegments.sorted { $0.start < $1.start }
        var turns: [MeetingTurn] = []

        for segment in segments {
            let text = (original ? segment.originalText : segment.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if let last = turns.last,
               last.speakerID == segment.speakerID,
               segment.start - last.end <= turnMergeGap {
                turns[turns.count - 1] = MeetingTurn(
                    speakerID: last.speakerID,
                    speakerName: last.speakerName,
                    start: last.start,
                    end: max(last.end, segment.end),
                    text: last.text + " " + text,
                    segmentIDs: last.segmentIDs + [segment.id]
                )
            } else {
                turns.append(MeetingTurn(
                    speakerID: segment.speakerID,
                    speakerName: document.speakerName(for: segment),
                    start: segment.start,
                    end: segment.end,
                    text: text,
                    segmentIDs: [segment.id]
                ))
            }
        }
        return turns
    }

    static func markdown(for document: MeetingDocument, original: Bool = false, timestamps: Bool = true) -> String {
        var lines: [String] = []
        lines.append("# \(document.title)")
        lines.append("")
        lines.append("- **When:** \(longDateRange(for: document))")
        lines.append("- **Duration:** \(durationText(document.duration()))")
        let speakers = document.activeSpeakers.map(\.name)
        if !speakers.isEmpty {
            lines.append("- **Speakers:** \(speakers.joined(separator: ", "))")
        }
        if let source = document.source {
            lines.append("- **Source:** \(source)")
        }
        if document.isLive {
            lines.append("- **Status:** recording in progress")
        }
        lines.append("")
        lines.append("---")

        let turns = turns(for: document, original: original)
        if turns.isEmpty {
            lines.append("")
            lines.append("_No speech was transcribed._")
        }
        for turn in turns {
            lines.append("")
            if timestamps {
                lines.append("**\(turn.speakerName)** · `\(timestamp(turn.start))`")
            } else {
                lines.append("**\(turn.speakerName)**")
            }
            lines.append("")
            lines.append(turn.text)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// "[00:12] You: text" lines, one per turn.
    static func plainText(for document: MeetingDocument, original: Bool = false, timestamps: Bool = true) -> String {
        turns(for: document, original: original)
            .map { turn in
                timestamps
                    ? "[\(timestamp(turn.start))] \(turn.speakerName): \(turn.text)"
                    : "\(turn.speakerName): \(turn.text)"
            }
            .joined(separator: "\n\n")
    }

    // MARK: - Formatting helpers

    /// "04:05" under an hour, "1:04:05" past it.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// "45 min", "1 h 05 min", "40 s".
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// "Thursday, October 23, 2026, 2:00 – 2:45 PM".
    static func longDateRange(for document: MeetingDocument) -> String {
        let day = DateFormatter()
        day.dateStyle = .full
        day.timeStyle = .none
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        let start = time.string(from: document.startedAt)
        guard let end = document.endedAt else {
            return "\(day.string(from: document.startedAt)), \(start)"
        }
        return "\(day.string(from: document.startedAt)), \(start) – \(time.string(from: end))"
    }

    /// File-name-safe title for exports: "Weekly sync 2026-10-23 1400".
    static func exportFileName(for document: MeetingDocument, extension ext: String = "md") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let title = document.title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = title.isEmpty ? "Meeting" : String(title.prefix(80))
        return "\(base) \(formatter.string(from: document.startedAt)).\(ext)"
    }
}

/// Case- and diacritic-insensitive transcript search.
enum MeetingSearch {
    struct Hit: Equatable {
        let segmentID: UUID
        /// Ranges inside the segment's displayed text.
        let ranges: [Range<String.Index>]
    }

    static func normalizedQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard let query = normalizedQuery(query) else { return [] }
        var result: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
              ) {
            result.append(range)
            searchStart = range.upperBound
        }
        return result
    }

    static func hits(in document: MeetingDocument, query: String, original: Bool = false) -> [Hit] {
        guard normalizedQuery(query) != nil else { return [] }
        return document.visibleSegments
            .sorted { $0.start < $1.start }
            .compactMap { segment in
                let text = original ? segment.originalText : segment.text
                let ranges = ranges(of: query, in: text)
                return ranges.isEmpty ? nil : Hit(segmentID: segment.id, ranges: ranges)
            }
    }

    /// A short excerpt around the first match, for result lists.
    static func snippet(for query: String, in text: String, radius: Int = 60) -> String {
        guard let first = ranges(of: query, in: text).first else {
            return String(text.prefix(radius * 2))
        }
        let lower = text.index(first.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(first.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
        if lower > text.startIndex { snippet = "…" + snippet }
        if upper < text.endIndex { snippet += "…" }
        return snippet
    }
}
