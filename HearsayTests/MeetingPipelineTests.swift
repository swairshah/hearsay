import XCTest
@testable import Hearsay

final class SpeechSegmenterTests: XCTestCase {

    private let rate = Int(MeetingAudioIO.sampleRate)

    private func tone(seconds: Double, amplitude: Float = 0.1) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    func testSplitsUtterancesSeparatedBySilence() {
        let segmenter = SpeechSegmenter(config: .microphone)
        let audio = silence(seconds: 1) + tone(seconds: 1.5) + silence(seconds: 1.2) + tone(seconds: 2) + silence(seconds: 1.2)
        let segments = segmenter.append(audio)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].startTime, 1.0, accuracy: 0.35)
        XCTAssertEqual(segments[0].duration, 1.5, accuracy: 0.6)
        XCTAssertEqual(segments[1].startTime, 3.7, accuracy: 0.35)
        XCTAssertEqual(segments[1].ordinal, segments[0].ordinal + 1)
    }

    func testIgnoresShortClicks() {
        let segmenter = SpeechSegmenter(config: .microphone)
        let audio = silence(seconds: 1) + tone(seconds: 0.12) + silence(seconds: 1.5)
        XCTAssertTrue(segmenter.append(audio).isEmpty)
        XCTAssertNil(segmenter.flush())
    }

    func testForceSplitsLongMonologue() {
        let segmenter = SpeechSegmenter(config: .system)
        let segments = segmenter.append(tone(seconds: 60))
        XCTAssertGreaterThanOrEqual(segments.count, 2, "Never let one utterance exceed the hard maximum")
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.duration, 26)
        }
    }

    func testFlushReturnsOpenUtterance() {
        let segmenter = SpeechSegmenter(config: .microphone)
        XCTAssertTrue(segmenter.append(silence(seconds: 0.5) + tone(seconds: 1)).isEmpty)
        XCTAssertNotNil(segmenter.openUtterance())
        let flushed = segmenter.flush()
        XCTAssertNotNil(flushed)
        XCTAssertNil(segmenter.openUtterance())
    }

    func testAdaptsToSteadyBackgroundNoise() {
        let segmenter = SpeechSegmenter(config: .microphone)
        // Constant hum at the same level for 10 s should not become "speech" forever.
        let hum = tone(seconds: 10, amplitude: 0.01)
        let segments = segmenter.append(hum) + (segmenter.flush().map { [$0] } ?? [])
        let total = segments.reduce(0) { $0 + $1.duration }
        XCTAssertLessThan(total, 10)
    }

    func testTimelineAccountsForEverySample() {
        let segmenter = SpeechSegmenter(config: .microphone)
        _ = segmenter.append(silence(seconds: 0.4) + tone(seconds: 0.4))
        _ = segmenter.append(silence(seconds: 0.2))
        // Frames are 30 ms; anything short of a frame is held back.
        XCTAssertEqual(segmenter.consumedSamples, (Int(1.0 * Double(rate)) / 480) * 480)
    }
}

final class MeetingEchoDetectorTests: XCTestCase {

    private func segment(_ channel: MeetingSegment.Channel, _ start: Double, _ end: Double, _ text: String) -> MeetingSegment {
        MeetingSegment(speakerID: channel == .microphone ? "me" : "them", channel: channel, start: start, end: end, text: text)
    }

    func testDetectsMicPickingUpCallAudio() {
        let system = segment(.system, 10, 14, "We should ship the new onboarding flow next Tuesday.")
        let mic = segment(.microphone, 10.3, 14.2, "we should ship the new onboarding flow next tuesday")
        XCTAssertTrue(MeetingEchoDetector.isEcho(mic: mic, system: system))
    }

    func testKeepsGenuineReplies() {
        let system = segment(.system, 10, 14, "Does Tuesday work for everyone?")
        let mic = segment(.microphone, 14.5, 16, "Yes, Tuesday works for me, but not Wednesday.")
        XCTAssertFalse(MeetingEchoDetector.isEcho(mic: mic, system: system))
    }

    func testKeepsShortBackchannel() {
        let system = segment(.system, 10, 12, "okay yeah")
        let mic = segment(.microphone, 10, 11, "yeah okay")
        XCTAssertFalse(MeetingEchoDetector.isEcho(mic: mic, system: system), "Too short to judge")
    }

    func testRequiresOverlapInTime() {
        let system = segment(.system, 10, 14, "We should ship the new onboarding flow next Tuesday.")
        let mic = segment(.microphone, 60, 64, "We should ship the new onboarding flow next Tuesday.")
        XCTAssertFalse(MeetingEchoDetector.isEcho(mic: mic, system: system))
    }
}

final class MeetingFormatterTests: XCTestCase {

    private func sampleDocument() -> MeetingDocument {
        var document = MeetingDocument(title: "Weekly sync", startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        document.endedAt = document.startedAt.addingTimeInterval(1_800)
        document.status = .completed
        document.speakers.append(MeetingSpeaker.remote(slot: 0))
        document.segments = [
            MeetingSegment(speakerID: "me", channel: .microphone, start: 2, end: 5, text: "Morning everyone."),
            MeetingSegment(speakerID: "me", channel: .microphone, start: 6, end: 9, text: "Let's start with the launch."),
            MeetingSegment(speakerID: "s1", channel: .system, start: 10, end: 20, text: "The launch slipped to Tuesday."),
        ]
        var echo = MeetingSegment(speakerID: "me", channel: .microphone, start: 10, end: 20, text: "The launch slipped to Tuesday.")
        echo.suppressed = true
        document.segments.append(echo)
        document.segments[2].text = "The launch slipped to Tuesday, sadly."
        return document
    }

    func testMergesConsecutiveSegmentsIntoTurns() {
        let turns = MeetingTranscriptFormatter.turns(for: sampleDocument())
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].speakerName, "You")
        XCTAssertEqual(turns[0].text, "Morning everyone. Let's start with the launch.")
        XCTAssertEqual(turns[1].speakerName, "Speaker 1")
    }

    func testMarkdownUsesProcessedTextAndHidesEcho() {
        let markdown = MeetingTranscriptFormatter.markdown(for: sampleDocument())
        XCTAssertTrue(markdown.hasPrefix("# Weekly sync"))
        XCTAssertTrue(markdown.contains("**Speaker 1** · `00:10`"))
        XCTAssertTrue(markdown.contains("sadly"))
        XCTAssertEqual(markdown.components(separatedBy: "The launch slipped").count - 1, 1, "Suppressed echo must not appear")
    }

    func testOriginalTextIsAvailable() {
        let text = MeetingTranscriptFormatter.plainText(for: sampleDocument(), original: true)
        XCTAssertFalse(text.contains("sadly"))
        XCTAssertTrue(text.contains("[00:10] Speaker 1: The launch slipped to Tuesday."))
    }

    func testTimestamps() {
        XCTAssertEqual(MeetingTranscriptFormatter.timestamp(65), "01:05")
        XCTAssertEqual(MeetingTranscriptFormatter.timestamp(3_725), "1:02:05")
    }

    func testSearchIsCaseAndDiacriticInsensitive() {
        var document = sampleDocument()
        document.segments[0].text = "Café plans for Tuesday"
        let hits = MeetingSearch.hits(in: document, query: "cafe")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(MeetingSearch.hits(in: document, query: "TUESDAY").count, 2)
        XCTAssertTrue(MeetingSearch.hits(in: document, query: "   ").isEmpty)
    }

    func testDocumentRoundTripsThroughJSON() throws {
        let document = sampleDocument()
        let data = try MeetingCoding.makeEncoder().encode(document)
        let decoded = try MeetingCoding.makeDecoder().decode(MeetingDocument.self, from: data)
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.summary().speakerNames, ["You", "Speaker 1"])
    }
}

final class MeetingEchoTrimTests: XCTestCase {

    func testTrimsLeakedCallTailFromReply() {
        let system = MeetingSegment(speakerID: "s2", channel: .system, start: 10, end: 14,
                                    text: "On the backend side we still have two open bugs in the billing service.")
        let mic = MeetingSegment(speakerID: "me", channel: .microphone, start: 12, end: 18,
                                 text: "we still have two open bugs in the billing service. How long do you think those bugs will take?")
        XCTAssertEqual(MeetingEchoDetector.resolve(mic: mic, system: system), .trimmed("How long do you think those bugs will take?"))
    }

    func testKeepsReplyThatOnlySharesAFewWords() {
        let system = MeetingSegment(speakerID: "s1", channel: .system, start: 10, end: 14, text: "Can we ship on Tuesday?")
        let mic = MeetingSegment(speakerID: "me", channel: .microphone, start: 14, end: 17, text: "Yes we can ship on Tuesday morning.")
        XCTAssertEqual(MeetingEchoDetector.resolve(mic: mic, system: system), .keep)
    }
}

extension MeetingEchoTrimTests {
    func testHyphenatedWordsLineUp() {
        let system = MeetingSegment(speakerID: "s2", channel: .system, start: 10, end: 14,
                                    text: "On the back-end side we still have two open bugs.")
        let mic = MeetingSegment(speakerID: "me", channel: .microphone, start: 10.5, end: 16,
                                 text: "On the back-end side we still have two open bugs. How long will they take?")
        XCTAssertEqual(MeetingEchoDetector.resolve(mic: mic, system: system), .trimmed("How long will they take?"))
    }
}
