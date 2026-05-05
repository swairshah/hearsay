import Foundation

struct CleanupRule: Codable, Equatable, Identifiable {
    var id: UUID
    var isEnabled: Bool
    var pattern: String

    init(id: UUID = UUID(), isEnabled: Bool = true, pattern: String) {
        self.id = id
        self.isEnabled = isEnabled
        self.pattern = pattern
    }
}

struct TextShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    var isEnabled: Bool
    var match: String
    var replacement: String

    init(id: UUID = UUID(), isEnabled: Bool = true, match: String, replacement: String) {
        self.id = id
        self.isEnabled = isEnabled
        self.match = match
        self.replacement = replacement
    }
}

enum TranscriptProcessingSettings {
    static let cleanupEnabledDefaultsKey = "deterministicCleanupEnabled"
    static let cleanupRulesDefaultsKey = "deterministicCleanupRules"
    static let shortcutsEnabledDefaultsKey = "textShortcutsEnabled"
    static let shortcutsDefaultsKey = "textShortcuts"

    static let defaultCleanupRules: [CleanupRule] = [
        CleanupRule(pattern: "uh+"),
        CleanupRule(pattern: "um+"),
        CleanupRule(pattern: "er+"),
        CleanupRule(pattern: "hm+")
    ]

    static var cleanupEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: cleanupEnabledDefaultsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: cleanupEnabledDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: cleanupEnabledDefaultsKey)
        }
    }

    static var cleanupRules: [CleanupRule] {
        get {
            decode([CleanupRule].self, forKey: cleanupRulesDefaultsKey) ?? defaultCleanupRules
        }
        set {
            encode(newValue, forKey: cleanupRulesDefaultsKey)
        }
    }

    static var shortcutsEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: shortcutsEnabledDefaultsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: shortcutsEnabledDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: shortcutsEnabledDefaultsKey)
        }
    }

    static var shortcuts: [TextShortcut] {
        get {
            decode([TextShortcut].self, forKey: shortcutsDefaultsKey) ?? []
        }
        set {
            encode(newValue, forKey: shortcutsDefaultsKey)
        }
    }

    static func resetCleanupRules() {
        cleanupRules = defaultCleanupRules
    }

    private static func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum TranscriptProcessor {
    static func process(_ text: String) -> String {
        var output = text
        if TranscriptProcessingSettings.cleanupEnabled {
            output = applyCleanup(output, rules: TranscriptProcessingSettings.cleanupRules)
        }
        if TranscriptProcessingSettings.shortcutsEnabled {
            output = applyShortcuts(output, shortcuts: TranscriptProcessingSettings.shortcuts)
        }
        return output
    }

    static func applyCleanup(_ text: String, rules: [CleanupRule]) -> String {
        guard !text.isEmpty, !rules.isEmpty else { return text }

        var output = text
        var didChange = false

        for rule in rules where rule.isEnabled {
            let trimmed = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let pattern = "(?<!\\w)(?:\(trimmed))(?!\\w)[ \t]*[,\\.!?;:]*"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let range = NSRange(output.startIndex..., in: output)
            let updated = regex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
            if updated != output {
                didChange = true
                output = updated
            }
        }

        guard didChange else { return text }
        return cleanupWhitespaceAndPunctuation(output)
    }

    static func applyShortcuts(_ text: String, shortcuts: [TextShortcut]) -> String {
        guard !text.isEmpty, !shortcuts.isEmpty else { return text }

        var output = text
        for shortcut in shortcuts where shortcut.isEnabled {
            let trimmed = shortcut.match.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let escaped = NSRegularExpression.escapedPattern(for: trimmed)
            let pattern = "(?<!\\w)\(escaped)(?!\\w)"
            let replacement = escapedReplacementTemplate(processEscapeSequences(shortcut.replacement))

            output = output.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return output
    }

    private static func cleanupWhitespaceAndPunctuation(_ text: String) -> String {
        var output = text
        output = output.replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
        output = output.replacingOccurrences(of: "[ \t]+([,\\.!?;:])", with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: "([,\\.!?;:])[ \t]*\\1+", with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: "(?m)^[ \t]*[,\\.!?;:]+[ \t]*", with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: "[ \t]+\\n", with: "\n", options: .regularExpression)
        output = output.replacingOccurrences(of: "\\n[ \t]+", with: "\n", options: .regularExpression)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func processEscapeSequences(_ string: String) -> String {
        let placeholder = "\u{0000}"
        return string
            .replacingOccurrences(of: "\\\\", with: placeholder)
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: placeholder, with: "\\")
    }

    private static func escapedReplacementTemplate(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\$")
    }
}
