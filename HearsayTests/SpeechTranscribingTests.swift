import XCTest
@testable import Hearsay

final class SpeechTranscribingTests: XCTestCase {
    private struct DummyTranscriber: SpeechTranscribing {
        func transcribe(audioURL: URL) async throws -> String {
            "ok"
        }
    }

    func testDefaultPrewarmImplementationDoesNotThrow() async {
        let transcriber = DummyTranscriber()
        await transcriber.prewarm()
        // No crash / throw is the behavior we need from the default extension.
        XCTAssertTrue(true)
    }

    func testSpeechTranscriptionErrorDescriptions() {
        XCTAssertEqual(SpeechTranscriptionError.noOutput.errorDescription, "No transcription output")

        let message = "something failed"
        XCTAssertEqual(
            SpeechTranscriptionError.failed(message).errorDescription,
            "Transcription failed: \(message)"
        )
    }
}
