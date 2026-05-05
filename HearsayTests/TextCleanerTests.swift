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

    func testDeterministicCleanupRemovesCommonFillersAndTidiesPunctuation() {
        let rules = [
            CleanupRule(pattern: "uh+"),
            CleanupRule(pattern: "um+")
        ]

        let output = TranscriptProcessor.applyCleanup("So uh, um, the meeting is tomorrow.", rules: rules)

        XCTAssertEqual(output, "So the meeting is tomorrow.")
    }

    func testDeterministicCleanupSkipsDisabledRules() {
        let rules = [
            CleanupRule(isEnabled: false, pattern: "um+")
        ]

        let output = TranscriptProcessor.applyCleanup("Um, keep this.", rules: rules)

        XCTAssertEqual(output, "Um, keep this.")
    }

    func testShortcutsReplaceWholePhrasesCaseInsensitively() {
        let shortcuts = [
            TextShortcut(match: "my email", replacement: "sam@example.com")
        ]

        let output = TranscriptProcessor.applyShortcuts("Send it to my email, not my emailer.", shortcuts: shortcuts)

        XCTAssertEqual(output, "Send it to sam@example.com, not my emailer.")
    }

    func testShortcutsSupportEscapeSequences() {
        let shortcuts = [
            TextShortcut(match: "my signature", replacement: "Sam\\nFounder")
        ]

        let output = TranscriptProcessor.applyShortcuts("Regards, my signature", shortcuts: shortcuts)

        XCTAssertEqual(output, "Regards, Sam\nFounder")
    }

    func testShortcutsTreatReplacementDollarsLiterally() {
        let shortcuts = [
            TextShortcut(match: "my budget", replacement: "$5")
        ]

        let output = TranscriptProcessor.applyShortcuts("Budget is my budget.", shortcuts: shortcuts)

        XCTAssertEqual(output, "Budget is $5.")
    }
}
