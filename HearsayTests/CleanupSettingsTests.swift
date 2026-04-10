import XCTest
@testable import Hearsay

final class CleanupSettingsTests: XCTestCase {
    private var originalPromptValue: Any?

    override func setUp() {
        super.setUp()
        originalPromptValue = UserDefaults.standard.object(forKey: CleanupSettings.promptDefaultsKey)
    }

    override func tearDown() {
        if let originalPromptValue {
            UserDefaults.standard.set(originalPromptValue, forKey: CleanupSettings.promptDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CleanupSettings.promptDefaultsKey)
        }
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
}
