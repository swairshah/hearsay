import XCTest
@testable import Hearsay

final class MeetingSpeakerRefinementTests: XCTestCase {

    private typealias Word = MeetingSpeakerRefinement.Word
    private typealias Turn = MeetingSpeakerRefinement.Turn

    /// "One two three. Four five six." spoken as six words, 0.3 s each, with a
    /// half-second pause after "three."
    private func words(offset: TimeInterval = 0) -> [Word] {
        let texts = ["One", "two", "three.", "Four", "five", "six."]
        var start = offset
        return texts.enumerated().map { index, text in
            defer { start += index == 2 ? 0.8 : 0.3 }
            return Word(text: text, start: start, end: start + 0.3)
        }
    }

    private func document(_ segments: [MeetingSegment], speakers: [MeetingSpeaker] = [.me, .them]) -> MeetingDocument {
        var document = MeetingDocument(title: "Test", startedAt: Date())
        document.segments = segments
        document.speakers = speakers
        return document
    }

    private func callSegment(_ text: String, _ start: TimeInterval, _ end: TimeInterval, speaker: String = MeetingSpeaker.themID) -> MeetingSegment {
        MeetingSegment(speakerID: speaker, channel: .system, start: start, end: end, text: text)
    }

    func testSplitsAnUtteranceWhereTheSpeakerChanges() {
        let segment = callSegment("One two three. Four five six.", 0, 2.4)
        var doc = document([segment])
        // The detected change lands one word early (inside "three.").
        let turns = [Turn(speaker: 0, start: 0, end: 0.7), Turn(speaker: 1, start: 0.7, end: 2.4)]

        let outcome = MeetingSpeakerRefinement.apply(to: &doc, turns: turns, words: [segment.id: words()])

        XCTAssertEqual(outcome.splitLines, 1)
        XCTAssertEqual(outcome.speakers, 2)
        XCTAssertEqual(doc.segments.map(\.text), ["One two three.", "Four five six."], "snapped to the sentence end")
        XCTAssertEqual(doc.segments.map(\.speakerID), ["s1", "s2"])
        XCTAssertEqual(doc.segments[0].id, segment.id, "first piece keeps the original id")
        XCTAssertEqual(doc.segments[0].start, 0)
        XCTAssertEqual(doc.segments[1].end, 2.4)
        XCTAssertEqual(doc.segments[1].originalText, "Four five six.")
        XCTAssertEqual(Set(doc.speakers.map(\.id)), ["me", "them", "s1", "s2"])
    }

    func testKeepsLiveWordingWhenTheRerunHeardDifferentWords() {
        var rerun = words()
        rerun[4] = Word(text: "hive", start: rerun[4].start, end: rerun[4].end)
        let aligned = MeetingSpeakerRefinement.align(rerun, to: "One two three. Four five six.", start: 0, end: 2.4)
        XCTAssertEqual(aligned.map(\.text), ["One", "two", "three.", "Four", "five", "six."])
        XCTAssertEqual(aligned[4].start, rerun[4].start, accuracy: 0.001)
    }

    func testRelabelsWithoutWordTimings() {
        let segment = callSegment("Hello there everyone", 1, 3)
        var doc = document([segment])
        let outcome = MeetingSpeakerRefinement.apply(to: &doc, turns: [Turn(speaker: 0, start: 0.9, end: 3.1)], words: [:])
        XCTAssertEqual(outcome.splitLines, 0)
        XCTAssertEqual(outcome.relabelledLines, 1)
        XCTAssertEqual(doc.segments.map(\.speakerID), ["s1"])
    }

    func testHandPickedLinesAreLeftAlone() {
        var picked = callSegment("One two three. Four five six.", 0, 2.4, speaker: "p1")
        picked.manualSpeaker = true
        var doc = document([picked], speakers: [.me, MeetingSpeaker(id: "p1", name: "Dana", kind: .remote, colorIndex: 4)])
        let turns = [Turn(speaker: 0, start: 0, end: 1.2), Turn(speaker: 1, start: 1.2, end: 2.4)]
        _ = MeetingSpeakerRefinement.apply(to: &doc, turns: turns, words: [picked.id: words()])
        XCTAssertEqual(doc.segments, [picked])
        XCTAssertEqual(doc.speaker(id: "p1")?.name, "Dana")
    }

    func testEditedLinesAreRelabelledButNotSplit() {
        var edited = callSegment("One two three. Four five six.", 0, 2.4)
        edited.text = "One, two, three! Four, five, six!"
        edited.edited = true
        var doc = document([edited])
        let turns = [Turn(speaker: 0, start: 0, end: 0.9), Turn(speaker: 1, start: 1.4, end: 2.4)]
        let outcome = MeetingSpeakerRefinement.apply(to: &doc, turns: turns, words: [edited.id: words()])
        XCTAssertEqual(outcome.splitLines, 0)
        XCTAssertEqual(doc.segments.count, 1)
        XCTAssertEqual(doc.segments[0].text, edited.text)
    }

    func testRenamedSpeakersKeepTheirNames() {
        // Live: "s2" was renamed to Zach; everyone else kept default names.
        let first = callSegment("Hi I'm the host", 0, 2, speaker: "s1")
        let second = callSegment("And I'm Zach", 3, 5, speaker: "s2")
        var zach = MeetingSpeaker.remote(slot: 1)
        zach.name = "Zach"
        var doc = document([first, second], speakers: [.me, .them, .remote(slot: 0), zach])
        // Whole-recording pass numbers Zach first.
        let turns = [Turn(speaker: 0, start: 3, end: 5), Turn(speaker: 1, start: 0, end: 2)]

        _ = MeetingSpeakerRefinement.apply(to: &doc, turns: turns, words: [:])

        XCTAssertEqual(doc.speakerName(for: doc.segments[1]), "Zach")
        XCTAssertEqual(doc.segments[1].speakerID, "s2")
        XCTAssertEqual(doc.segments[0].speakerID, "s1")
    }

    func testDropsDetectedSpeakersNobodyUsesAnyMore() {
        let segment = callSegment("Hello there everyone", 0, 2, speaker: "s4")
        var doc = document([segment], speakers: [.me, .them, .remote(slot: 3)])
        _ = MeetingSpeakerRefinement.apply(to: &doc, turns: [Turn(speaker: 0, start: 0, end: 2)], words: [:])
        XCTAssertEqual(doc.segments[0].speakerID, "s1")
        XCTAssertNil(doc.speaker(id: "s4"))
        XCTAssertNotNil(doc.speaker(id: "s1"))
    }

    func testSingleWordBlipsDoNotSplit() {
        let segment = callSegment("One two three. Four five six.", 0, 2.4)
        var doc = document([segment])
        // Someone else for just "five".
        let turns = [Turn(speaker: 0, start: 0, end: 1.7), Turn(speaker: 1, start: 1.7, end: 2.0), Turn(speaker: 0, start: 2.0, end: 2.4)]
        let outcome = MeetingSpeakerRefinement.apply(to: &doc, turns: turns, words: [segment.id: words()])
        XCTAssertEqual(outcome.splitLines, 0)
        XCTAssertEqual(doc.segments.map(\.speakerID), ["s1"])
    }
}
