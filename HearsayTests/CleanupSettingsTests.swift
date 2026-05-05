import XCTest
@testable import Hearsay

final class CleanupSettingsTests: XCTestCase {
    private var originalPromptValue: Any?
    private var originalCleanupEnabledValue: Any?
    private var originalCleanupRulesValue: Any?
    private var originalShortcutsEnabledValue: Any?
    private var originalShortcutsValue: Any?

    override func setUp() {
        super.setUp()
        originalPromptValue = UserDefaults.standard.object(forKey: CleanupSettings.promptDefaultsKey)
        originalCleanupEnabledValue = UserDefaults.standard.object(forKey: TranscriptProcessingSettings.cleanupEnabledDefaultsKey)
        originalCleanupRulesValue = UserDefaults.standard.object(forKey: TranscriptProcessingSettings.cleanupRulesDefaultsKey)
        originalShortcutsEnabledValue = UserDefaults.standard.object(forKey: TranscriptProcessingSettings.shortcutsEnabledDefaultsKey)
        originalShortcutsValue = UserDefaults.standard.object(forKey: TranscriptProcessingSettings.shortcutsDefaultsKey)
    }

    override func tearDown() {
        restore(originalPromptValue, forKey: CleanupSettings.promptDefaultsKey)
        restore(originalCleanupEnabledValue, forKey: TranscriptProcessingSettings.cleanupEnabledDefaultsKey)
        restore(originalCleanupRulesValue, forKey: TranscriptProcessingSettings.cleanupRulesDefaultsKey)
        restore(originalShortcutsEnabledValue, forKey: TranscriptProcessingSettings.shortcutsEnabledDefaultsKey)
        restore(originalShortcutsValue, forKey: TranscriptProcessingSettings.shortcutsDefaultsKey)
        super.tearDown()
    }

    func testPromptFallsBackToDefaultWhenUnset() {
        UserDefaults.standard.removeObject(forKey: CleanupSettings.promptDefaultsKey)

        XCTAssertEqual(CleanupSettings.prompt, TextCleaner.defaultPrompt)
    }

    func testPromptFallsBackToDefaultWhenBlank() {
        UserDefaults.standard.set("   ", forKey: CleanupSettings.promptDefaultsKey)

        XCTAssertEqual(CleanupSettings.prompt, TextCleaner.defaultPrompt)
    }

    func testResetPromptRestoresDefault() {
        CleanupSettings.prompt = "custom prompt"
        XCTAssertEqual(CleanupSettings.prompt, "custom prompt")

        CleanupSettings.resetPrompt()

        XCTAssertEqual(CleanupSettings.prompt, TextCleaner.defaultPrompt)
    }

    func testDeterministicCleanupDefaultsToEnabledWithDefaultRules() {
        UserDefaults.standard.removeObject(forKey: TranscriptProcessingSettings.cleanupEnabledDefaultsKey)
        UserDefaults.standard.removeObject(forKey: TranscriptProcessingSettings.cleanupRulesDefaultsKey)

        XCTAssertTrue(TranscriptProcessingSettings.cleanupEnabled)
        XCTAssertEqual(TranscriptProcessingSettings.cleanupRules.map(\.pattern), ["uh+", "um+", "er+", "hm+"])
    }

    func testShortcutsRoundTripThroughUserDefaults() {
        let shortcuts = [
            TextShortcut(match: "my number", replacement: "555-0100")
        ]

        TranscriptProcessingSettings.shortcuts = shortcuts

        XCTAssertEqual(TranscriptProcessingSettings.shortcuts, shortcuts)
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
