import Foundation

/// Something captured mid-recording that should be woven into the transcript at
/// the moment it occurred — either a screenshot (figure) or copied text (clip).
enum TranscriptInsertion {
    case figure(number: Int, url: URL)  // `number` is 1-based; rendered as "[Figure N]" + a path footer
    case clip(index: Int)               // index into the clips array; rendered verbatim
}

/// An insertion paired with its offset (seconds) from recording start.
struct TimedInsertion {
    let timestamp: TimeInterval
    let insertion: TranscriptInsertion
}

/// Merges figures and clips into a single time-ordered timeline and interleaves
/// them with transcript segments. Figures keep their existing "[Figure N]" +
/// footer format; clips are inserted via a placeholder that `substituteClips`
/// swaps for the verbatim copied text *after* all post-processing, so the copied
/// text is never altered by the cleanup passes.
enum TranscriptInterleaver {

    /// Placeholder wrapping a clip index. U+F8FF is a private-use character — not a
    /// word, whitespace, or punctuation character — so neither the LLM cleanup nor
    /// the deterministic `TranscriptProcessor` regexes disturb it.
    static func clipPlaceholder(_ index: Int) -> String { "\u{F8FF}CLIP\(index)\u{F8FF}" }

    /// Build a time-sorted timeline from captured figures and clips.
    static func buildTimeline(figures: [CapturedFigure], clips: [CapturedClip]) -> [TimedInsertion] {
        var timeline: [TimedInsertion] = []
        for (index, figure) in figures.enumerated() {
            timeline.append(TimedInsertion(timestamp: figure.timestamp,
                                           insertion: .figure(number: index + 1, url: figure.url)))
        }
        for (index, clip) in clips.enumerated() {
            timeline.append(TimedInsertion(timestamp: clip.timestamp, insertion: .clip(index: index)))
        }
        // Stable-ish ordering by time; figures and clips are each already in capture order.
        timeline.sort { $0.timestamp < $1.timestamp }
        return timeline
    }

    /// Timestamps at which to split the audio (one segment boundary per insertion).
    static func splitTimestamps(for timeline: [TimedInsertion]) -> [TimeInterval] {
        timeline.map { $0.timestamp }
    }

    /// Interleave transcript `segments` with `timeline`. Expects
    /// `segments.count == timeline.count + 1`, but tolerates mismatches.
    static func interleave(segments: [String], timeline: [TimedInsertion]) -> String {
        var result = ""

        for (index, segment) in segments.enumerated() {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                if !result.isEmpty && !result.hasSuffix(" ") { result += " " }
                result += trimmed
            }

            guard index < timeline.count else { continue }
            switch timeline[index].insertion {
            case .figure(let number, _):
                if !result.isEmpty { result += " " }
                result += "[Figure \(number)]"
            case .clip(let clipIndex):
                if !result.isEmpty { result += " " }
                result += clipPlaceholder(clipIndex)
            }
        }

        let footer = figureFooter(for: timeline)
        return footer.isEmpty ? result : "\(result)\n\n\(footer)"
    }

    /// "Figure N: /path" lines for the figures in the timeline, in figure-number order.
    static func figureFooter(for timeline: [TimedInsertion]) -> String {
        timeline
            .compactMap { timed -> String? in
                if case .figure(let number, let url) = timed.insertion {
                    return "Figure \(number): \(url.path)"
                }
                return nil
            }
            .joined(separator: "\n")
    }

    /// Replace clip placeholders with the verbatim copied text. Run this AFTER all
    /// cleanup so the copied text is reproduced exactly. Any residual placeholder
    /// (e.g. mangled by an LLM cleanup pass) is stripped to avoid leaking markers.
    static func substituteClips(_ text: String, clips: [CapturedClip]) -> String {
        guard !clips.isEmpty else { return text }

        var output = text
        for (index, clip) in clips.enumerated() {
            output = output.replacingOccurrences(of: clipPlaceholder(index), with: clip.text)
        }
        output = output.replacingOccurrences(
            of: "\u{F8FF}[^\u{F8FF}]*\u{F8FF}",
            with: "",
            options: .regularExpression
        )
        return output
    }
}
