import Foundation

/// Re-labels the call side of a finished meeting from whole-recording speaker
/// turns, splitting an utterance into several lines where the speaker changes.
///
/// The live pipeline gives each utterance one speaker, so two people talking
/// without a pause share a line. With per-word timings each word gets its own
/// speaker; the wording itself is kept as transcribed live.
enum MeetingSpeakerRefinement {

    struct Word: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    struct Turn: Equatable {
        let speaker: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    struct Outcome: Equatable {
        /// Distinct call speakers after refinement.
        var speakers = 0
        /// Live lines that were split because the speaker changed mid-way.
        var splitLines = 0
        /// Call lines whose speaker changed.
        var relabelledLines = 0
    }

    /// Apply `turns` (speakers numbered by first appearance) and per-segment
    /// recognized `words` to the call segments of `document`. Lines picked by
    /// hand keep their speaker; edited or post-processed lines are relabelled
    /// but never split.
    static func apply(to document: inout MeetingDocument, turns: [Turn], words: [UUID: [Word]]) -> Outcome {
        guard !turns.isEmpty else { return Outcome() }
        let mapping = speakerIDs(for: turns, in: document)
        var outcome = Outcome()
        var segments: [MeetingSegment] = []

        for segment in document.segments {
            guard segment.channel == .system, segment.manualSpeaker != true, segment.suppressed != true else {
                segments.append(segment)
                continue
            }
            let splittable = segment.edited != true && segment.text == segment.originalText
            let aligned = splittable ? align(words[segment.id] ?? [], to: segment.text, start: segment.start, end: segment.end) : []

            if aligned.count >= 2 {
                let labels = snap(aligned, smooth(aligned.map { speaker(for: $0, in: turns) }.filledForward()))
                let parts = pieces(aligned, labels: labels)
                if parts.count > 1 {
                    outcome.splitLines += 1
                    for (index, part) in parts.enumerated() {
                        var piece = MeetingSegment(
                            id: index == 0 ? segment.id : UUID(),
                            speakerID: part.speaker.flatMap { mapping[$0] } ?? segment.speakerID,
                            channel: .system,
                            start: index == 0 ? segment.start : part.words[0].start,
                            end: index == parts.count - 1 ? segment.end : part.words[part.words.count - 1].end,
                            text: part.words.map(\.text).joined(separator: " ")
                        )
                        piece.suppressed = segment.suppressed
                        segments.append(piece)
                    }
                    continue
                }
            }

            var relabelled = segment
            if let slot = dominantSpeaker(from: segment.start, to: segment.end, in: turns), let id = mapping[slot] {
                relabelled.speakerID = id
            }
            if relabelled.speakerID != segment.speakerID { outcome.relabelledLines += 1 }
            segments.append(relabelled)
        }
        document.segments = segments

        // Speakers: add the ones now in use, drop detected ones nothing points at.
        let used = Set(segments.map(\.speakerID))
        for id in Set(mapping.values).sorted() where document.speaker(id: id) == nil && used.contains(id) {
            if let slot = slot(of: id) { document.speakers.append(MeetingSpeaker.remote(slot: slot)) }
        }
        document.speakers.removeAll { $0.kind == .remote && slot(of: $0.id) != nil && !used.contains($0.id) }
        outcome.speakers = Set(segments.filter { $0.channel == .system }.map(\.speakerID)).subtracting([MeetingSpeaker.themID]).count
        return outcome
    }

    // MARK: - Speaker IDs

    /// Detected speaker → speaker ID. Speakers the user renamed during the
    /// meeting keep their ID (and name) when a detected speaker mostly matches
    /// them; everyone else is numbered "Speaker 1, 2, …" by first appearance.
    static func speakerIDs(for turns: [Turn], in document: MeetingDocument) -> [Int: String] {
        let renamed = Set(document.speakers.filter { speaker in
            guard speaker.kind == .remote, let slot = slot(of: speaker.id) else { return false }
            return speaker.name != MeetingSpeaker.remote(slot: slot).name
        }.map(\.id))
        let handPicked = Set(document.segments.filter { $0.manualSpeaker == true }.map(\.speakerID))

        var overlap: [Int: [String: TimeInterval]] = [:]
        for segment in document.segments where segment.channel == .system && renamed.contains(segment.speakerID) {
            for turn in turns {
                let seconds = min(segment.end, turn.end) - max(segment.start, turn.start)
                if seconds > 0 { overlap[turn.speaker, default: [:]][segment.speakerID, default: 0] += seconds }
            }
        }

        var mapping: [Int: String] = [:]
        var taken = handPicked.union(renamed)
        let pairs = overlap.flatMap { speaker, ids in ids.map { (speaker, $0.key, $0.value) } }.sorted { $0.2 > $1.2 }
        var keptRenamed = Set<String>()
        for (speaker, id, _) in pairs where mapping[speaker] == nil && !keptRenamed.contains(id) {
            mapping[speaker] = id
            keptRenamed.insert(id)
        }
        taken.formUnion(keptRenamed)

        var nextSlot = 0
        for speaker in Set(turns.map(\.speaker)).sorted() where mapping[speaker] == nil {
            while taken.contains(MeetingSpeaker.remoteID(forSlot: nextSlot)) { nextSlot += 1 }
            let id = MeetingSpeaker.remoteID(forSlot: nextSlot)
            mapping[speaker] = id
            taken.insert(id)
        }
        return mapping
    }

    /// Slot number of a detected-speaker ID ("s3" → 2), nil for anything else.
    static func slot(of id: String) -> Int? {
        guard id.hasPrefix("s"), let number = Int(id.dropFirst()), number > 0 else { return nil }
        return number - 1
    }

    // MARK: - Words

    /// Put the live wording onto the re-recognized words' timings. The two
    /// usually match; where they differ, the live words share the time span of
    /// the words they replace.
    static func align(_ words: [Word], to text: String, start: TimeInterval, end: TimeInterval) -> [Word] {
        let target = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !target.isEmpty else { return [] }
        guard !words.isEmpty else { return [] }

        let key = { (word: String) in word.lowercased().filter { $0.isLetter || $0.isNumber } }
        let source = words.map { key($0.text) }
        let wanted = target.map(key)

        // Longest common subsequence over normalized words.
        var table = Array(repeating: Array(repeating: 0, count: wanted.count + 1), count: source.count + 1)
        for i in stride(from: source.count - 1, through: 0, by: -1) {
            for j in stride(from: wanted.count - 1, through: 0, by: -1) {
                table[i][j] = source[i] == wanted[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var matches: [(Int, Int)] = []
        var i = 0, j = 0
        while i < source.count, j < wanted.count {
            if source[i] == wanted[j] {
                matches.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        var output: [Word] = []
        var previousSource = -1, previousTarget = -1
        func fill(upToSource sourceIndex: Int, target targetIndex: Int) {
            let gap = Array(target[(previousTarget + 1)..<targetIndex])
            guard !gap.isEmpty else { return }
            let spanStart = previousSource + 1 < sourceIndex ? words[previousSource + 1].start
                : (output.last?.end ?? start)
            let spanEnd = previousSource + 1 < sourceIndex ? words[sourceIndex - 1].end
                : (sourceIndex < words.count ? words[sourceIndex].start : end)
            let step = max(0, spanEnd - spanStart) / Double(gap.count)
            for (offset, text) in gap.enumerated() {
                output.append(Word(text: text, start: spanStart + Double(offset) * step, end: spanStart + Double(offset + 1) * step))
            }
        }
        for (sourceIndex, targetIndex) in matches {
            fill(upToSource: sourceIndex, target: targetIndex)
            output.append(Word(text: target[targetIndex], start: words[sourceIndex].start, end: words[sourceIndex].end))
            previousSource = sourceIndex
            previousTarget = targetIndex
        }
        fill(upToSource: words.count, target: target.count)
        return output
    }

    // MARK: - Labels

    /// Detected speaker talking during `word`, or nearby (within a second) when
    /// it falls in a gap between turns.
    static func speaker(for word: Word, in turns: [Turn]) -> Int? {
        var best: Int?
        var bestOverlap = 0.0
        for turn in turns {
            let overlap = min(word.end, turn.end) - max(word.start, turn.start)
            if overlap > bestOverlap {
                best = turn.speaker
                bestOverlap = overlap
            }
        }
        if let best { return best }
        let middle = (word.start + word.end) / 2
        let nearest = turns.min { distance(middle, $0) < distance(middle, $1) }
        return nearest.flatMap { distance(middle, $0) < 1 ? $0.speaker : nil }
    }

    private static func distance(_ time: TimeInterval, _ turn: Turn) -> TimeInterval {
        time < turn.start ? turn.start - time : max(0, time - turn.end)
    }

    /// Speaker with the most talk time inside a line, if they cover a fair share of it.
    static func dominantSpeaker(from start: TimeInterval, to end: TimeInterval, in turns: [Turn]) -> Int? {
        var seconds: [Int: TimeInterval] = [:]
        for turn in turns {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > 0 { seconds[turn.speaker, default: 0] += overlap }
        }
        guard let best = seconds.max(by: { $0.value < $1.value }) else { return nil }
        return best.value >= min(0.4, (end - start) * 0.2) ? best.key : nil
    }

    /// A single word between two words of the same other speaker is boundary jitter.
    static func smooth(_ labels: [Int?]) -> [Int?] {
        var labels = labels
        guard labels.count >= 3 else { return labels }
        for index in 1..<(labels.count - 1) where labels[index - 1] == labels[index + 1] && labels[index] != labels[index - 1] {
            labels[index] = labels[index - 1]
        }
        return labels
    }

    /// Move each speaker change to the most natural break within three words:
    /// the longest pause, preferring sentence ends. Detected turn boundaries
    /// are a few hundred milliseconds off, which otherwise hands the last word
    /// of a sentence ("…as well.") to the next person.
    static func snap(_ words: [Word], _ labels: [Int?]) -> [Int?] {
        var labels = labels
        guard words.count == labels.count else { return labels }
        var index = 1
        while index < words.count {
            guard labels[index] != labels[index - 1] else {
                index += 1
                continue
            }
            var best = index
            var bestScore = -Double.infinity
            for candidate in max(1, index - 3)..<min(words.count, index + 4) {
                let pause = words[candidate].start - words[candidate - 1].end
                let ending = words[candidate - 1].text.last
                let bonus = ending.map { ".?!".contains($0) ? 0.4 : ($0 == "," ? 0.15 : 0) } ?? 0
                if pause + bonus > bestScore {
                    best = candidate
                    bestScore = pause + bonus
                }
            }
            let before = labels[index - 1], after = labels[index]
            for position in min(best, index)..<max(best, index) {
                labels[position] = best > index ? before : after
            }
            index = max(best, index) + 1
        }
        return labels
    }

    /// Runs of the same speaker; runs of a single word join their neighbour.
    static func pieces(_ words: [Word], labels: [Int?]) -> [(speaker: Int?, words: [Word])] {
        var runs: [(speaker: Int?, words: [Word])] = []
        for (word, label) in zip(words, labels) {
            if let last = runs.last, last.speaker == label {
                runs[runs.count - 1].words.append(word)
            } else {
                runs.append((label, [word]))
            }
        }
        var merged: [(speaker: Int?, words: [Word])] = []
        for run in runs {
            if let last = merged.last, run.words.count < 2 {
                merged[merged.count - 1].words = last.words + run.words
            } else if let last = merged.last, last.words.count < 2 {
                merged.removeLast()
                merged.append((run.speaker, last.words + run.words))
            } else {
                merged.append(run)
            }
        }
        return merged
    }
}

private extension Array where Element == Int? {
    /// Words in a gap with no nearby turn take the previous word's speaker.
    func filledForward() -> [Int?] {
        var previous: Int?
        return map { label in
            if let label { previous = label }
            return label ?? previous
        }
    }
}
