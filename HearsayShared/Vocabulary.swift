import Foundation

/// Names and terms the speech model should get right: people, companies,
/// products, jargon. Shared by the app and the `hearsay vocab` CLI through
/// `~/Library/Application Support/Hearsay/vocabulary.json`.
///
/// Each term lists its aliases: how the speech model tends to mishear it
/// ("human lair" for HumanLayer). Aliases are replaced with the term after
/// recognition, and the term list is given to the LLM passes as a spelling
/// reference.
struct VocabularyTerm: Codable, Equatable, Identifiable {
    var id: UUID
    var text: String
    var aliases: [String]
    var note: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), text: String, aliases: [String] = [], note: String? = nil, date: Date = Vocabulary.now()) {
        self.id = id
        self.text = text
        self.aliases = []
        self.note = nil
        self.createdAt = date
        self.updatedAt = date
        setAliases(aliases)
        setNote(note)
    }

    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    /// Trimmed, de-duplicated (ignoring case), and never the term itself.
    mutating func setAliases(_ values: [String]) {
        var seen = Set<String>([Vocabulary.matchKey(text)])
        aliases = values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Vocabulary.matchKey(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    mutating func setNote(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        note = trimmed.isEmpty ? nil : trimmed
    }
}

struct Vocabulary: Codable, Equatable {
    var version = 1
    var terms: [VocabularyTerm] = []

    enum VocabularyError: LocalizedError {
        case emptyTerm
        case duplicate(String)

        var errorDescription: String? {
            switch self {
            case .emptyTerm: return "The term can't be empty"
            case .duplicate(let text): return "'\(text)' is already in the vocabulary"
            }
        }
    }

    // MARK: - Storage

    /// Whole seconds: the file stores ISO 8601 dates, so a saved term reads back equal.
    static func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    /// `HEARSAY_VOCABULARY_PATH` overrides the location (tests, experiments).
    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["HEARSAY_VOCABULARY_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hearsay/vocabulary.json")
    }

    /// A missing file is an empty vocabulary.
    static func load(from url: URL = fileURL) throws -> Vocabulary {
        guard FileManager.default.fileExists(atPath: url.path) else { return Vocabulary() }
        let data = try Data(contentsOf: url)
        return try MeetingCoding.makeDecoder().decode(Vocabulary.self, from: data)
    }

    func save(to url: URL = Vocabulary.fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MeetingCoding.makeEncoder().encode(self).write(to: url, options: .atomic)
    }

    // MARK: - Editing

    @discardableResult
    mutating func add(_ text: String, aliases: [String] = [], note: String? = nil) throws -> VocabularyTerm {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VocabularyError.emptyTerm }
        if let existing = term(withText: trimmed) { throw VocabularyError.duplicate(existing.text) }
        let term = VocabularyTerm(text: trimmed, aliases: aliases, note: note)
        terms.append(term)
        return term
    }

    /// Replace the stored term with the same id. Fails if the new text collides with another term.
    mutating func update(_ term: VocabularyTerm) throws {
        var term = term
        term.text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.text.isEmpty else { throw VocabularyError.emptyTerm }
        if let other = self.term(withText: term.text), other.id != term.id {
            throw VocabularyError.duplicate(other.text)
        }
        term.setAliases(term.aliases)
        term.updatedAt = Self.now()
        if let index = terms.firstIndex(where: { $0.id == term.id }) {
            terms[index] = term
        } else {
            terms.append(term)
        }
    }

    mutating func remove(id: UUID) {
        terms.removeAll { $0.id == id }
    }

    // MARK: - Lookup

    func term(withText text: String) -> VocabularyTerm? {
        let key = Self.matchKey(text)
        return terms.first { Self.matchKey($0.text) == key }
    }

    /// Exact term text (ignoring case), else a unique id prefix.
    func find(_ reference: String) -> VocabularyTerm? {
        if let term = term(withText: reference) { return term }
        let prefix = reference.lowercased()
        guard prefix.count >= 4 else { return nil }
        let matches = terms.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Terms whose text, aliases or note contain `query` (case- and diacritic-insensitive).
    func search(_ query: String) -> [VocabularyTerm] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sorted }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return sorted.filter { term in
            ([term.text, term.note ?? ""] + term.aliases).contains { $0.range(of: trimmed, options: options) != nil }
        }
    }

    /// Alphabetical, for display.
    var sorted: [VocabularyTerm] {
        terms.sorted { $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending }
    }

    // MARK: - Applying

    /// Replace whole-word alias matches with their term ("human lair" → "HumanLayer").
    /// Case-insensitive; spaces and hyphens between an alias's words are interchangeable;
    /// the longest alias wins where several match.
    func applyAliases(to text: String) -> String {
        guard !text.isEmpty, let matcher = aliasMatcher else { return text }
        let source = text as NSString
        let matches = matcher.regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        var output = ""
        var cursor = 0
        for match in matches {
            let found = source.substring(with: match.range)
            guard let replacement = matcher.terms[Self.matchKey(found)] else { continue }
            // Already the full term (alias "Warp" of "Warp Terminal"): keeps a second pass a no-op.
            let rest = source.substring(from: match.range.location)
            if rest.range(of: replacement, options: [.anchored, .caseInsensitive]) != nil { continue }
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += replacement
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
    }

    private var aliasMatcher: (regex: NSRegularExpression, terms: [String: String])? {
        var replacements: [String: String] = [:]
        for term in terms {
            for alias in term.aliases {
                let key = Self.matchKey(alias)
                if !key.isEmpty, replacements[key] == nil { replacements[key] = term.text }
            }
        }
        guard !replacements.isEmpty else { return nil }
        // Longest first, so alternation prefers "human lair co" over "human lair".
        let alternatives = replacements.keys
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map { key in
                key.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "[\\s\\-]+")
            }
        let pattern = "(?<![\\p{L}\\p{N}_])(?:\(alternatives.joined(separator: "|")))(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return (regex, replacements)
    }

    /// Lowercased words joined by single spaces; how aliases are compared.
    static func matchKey(_ text: String) -> String {
        text.lowercased()
            .split { $0.isWhitespace || $0 == "-" }
            .joined(separator: " ")
    }

    /// For the LLM passes: the exact spellings to use, with what they may be heard as.
    /// Nil when there are no terms.
    func promptReference(limit: Int = 150) -> String? {
        guard !terms.isEmpty else { return nil }
        let lines = sorted.prefix(limit).map { term -> String in
            let heard = term.aliases.prefix(4).map { "\"\($0)\"" }.joined(separator: ", ")
            return heard.isEmpty ? "- \(term.text)" : "- \(term.text) (may be heard as \(heard))"
        }
        return """
        Names and terms that may appear. When one is clearly meant, spell it exactly like this:
        \(lines.joined(separator: "\n"))
        """
    }

    /// One term per line, `term: alias1, alias2` — FluidAudio's
    /// `CustomVocabularyContext.loadFromSimpleFormat` input for Parakeet boosting.
    func fluidAudioSimpleFormat() -> String {
        func clean(_ value: String) -> String {
            value.replacingOccurrences(of: ":", with: " ")
                .replacingOccurrences(of: ",", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        return sorted.map { term in
            let aliases = term.aliases.map(clean).filter { !$0.isEmpty }
            return aliases.isEmpty ? clean(term.text) : "\(clean(term.text)): \(aliases.joined(separator: ", "))"
        }
        .joined(separator: "\n") + (terms.isEmpty ? "" : "\n")
    }
}
