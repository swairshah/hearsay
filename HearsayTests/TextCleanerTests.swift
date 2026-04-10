import XCTest
@testable import Hearsay

final class TextCleanerTests: XCTestCase {

    func testFormatInputWrapsTextInUserInputTags() {
        let input = "hello world"
        let formatted = TextCleaner.formatInput(input)

        XCTAssertTrue(formatted.contains("<USER-INPUT>"))
        XCTAssertTrue(formatted.contains("</USER-INPUT>"))
        XCTAssertTrue(formatted.contains(input))
    }

    func testSanitizeRemovesThinkBlocks() {
        let raw = "<think>internal reasoning</think>Clean output"
        let sanitized = TextCleaner.sanitize(raw)

        XCTAssertEqual(sanitized, "Clean output")
    }

    func testSanitizeTrimsWhitespace() {
        let raw = "   Clean output   \n"
        let sanitized = TextCleaner.sanitize(raw)

        XCTAssertEqual(sanitized, "Clean output")
    }

    func testSanitizeLeavesNormalTextUntouched() {
        let raw = "The meeting is at 3pm on Tuesday."
        let sanitized = TextCleaner.sanitize(raw)

        XCTAssertEqual(sanitized, raw)
    }
}
