import Foundation

enum CleanupSettings {
    static let promptDefaultsKey = "cleanupPrompt"

    static var prompt: String {
        get {
            let stored = UserDefaults.standard.string(forKey: promptDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (stored?.isEmpty == false) ? stored! : TextCleaner.defaultPrompt
        }
        set {
            UserDefaults.standard.set(newValue, forKey: promptDefaultsKey)
        }
    }

    static func resetPrompt() {
        UserDefaults.standard.set(TextCleaner.defaultPrompt, forKey: promptDefaultsKey)
    }
}
