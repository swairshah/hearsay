import XCTest
@testable import Hearsay

final class VocabularyTests: XCTestCase {

    private func makeVocabulary() throws -> Vocabulary {
        var vocabulary = Vocabulary()
        try vocabulary.add("HumanLayer", aliases: ["human lair", "humanlair", " Human Lair "], note: "Dexter's company")
        try vocabulary.add("Vaibhav", aliases: ["vibov", "vybhav"])
        try vocabulary.add("Warp", aliases: ["worp"])
        try vocabulary.add("Boundary ML", aliases: ["boundary"])
        try vocabulary.add("Boundary ML Cloud", aliases: ["boundary cloud"])
        return vocabulary
    }

    func testRoundTripThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-\(UUID().uuidString)/vocabulary.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(try Vocabulary.load(from: url), Vocabulary(), "missing file is empty")
        let vocabulary = try makeVocabulary()
        try vocabulary.save(to: url)
        XCTAssertEqual(try Vocabulary.load(from: url), vocabulary)
    }

    func testAliasesAreTrimmedAndDeduplicated() throws {
        let vocabulary = try makeVocabulary()
        XCTAssertEqual(vocabulary.term(withText: "humanlayer")?.aliases, ["human lair", "humanlair"])
    }

    func testDuplicateTermsAreRejected() throws {
        var vocabulary = try makeVocabulary()
        XCTAssertThrowsError(try vocabulary.add("  humanlayer "))
        XCTAssertThrowsError(try vocabulary.add("   "))
        var warp = try XCTUnwrap(vocabulary.term(withText: "Warp"))
        warp.text = "HumanLayer"
        XCTAssertThrowsError(try vocabulary.update(warp))
    }

    func testFindByTextOrIDPrefix() throws {
        let vocabulary = try makeVocabulary()
        let term = try XCTUnwrap(vocabulary.find("VAIBHAV"))
        XCTAssertEqual(vocabulary.find(term.shortID)?.id, term.id)
        XCTAssertNil(vocabulary.find("abc"), "short prefixes don't match ids")
        XCTAssertNil(vocabulary.find("Nobody"))
    }

    func testSearchCoversTextAliasesAndNote() throws {
        let vocabulary = try makeVocabulary()
        XCTAssertEqual(vocabulary.search("dexter").map(\.text), ["HumanLayer"])
        XCTAssertEqual(vocabulary.search("VIBOV").map(\.text), ["Vaibhav"])
        XCTAssertEqual(vocabulary.search("boundary").map(\.text), ["Boundary ML", "Boundary ML Cloud"])
        XCTAssertEqual(vocabulary.search("").count, 5)
    }

    func testApplyAliasesReplacesWholeWordsIgnoringCase() throws {
        let vocabulary = try makeVocabulary()
        XCTAssertEqual(
            vocabulary.applyAliases(to: "I'm the co-founder over at Human Lair, and Vibov runs it."),
            "I'm the co-founder over at HumanLayer, and Vaibhav runs it."
        )
        XCTAssertEqual(vocabulary.applyAliases(to: "WORP terminal"), "Warp terminal")
        XCTAssertEqual(vocabulary.applyAliases(to: "human-lair and human   lair"), "HumanLayer and HumanLayer")
    }

    func testApplyAliasesNeverTouchesPartsOfWords() throws {
        let vocabulary = try makeVocabulary()
        XCTAssertEqual(vocabulary.applyAliases(to: "worpsmith and boundaryless"), "worpsmith and boundaryless")
        XCTAssertEqual(vocabulary.applyAliases(to: "humanlairs"), "humanlairs")
    }

    func testLongestAliasWins() throws {
        let vocabulary = try makeVocabulary()
        XCTAssertEqual(vocabulary.applyAliases(to: "on boundary cloud today"), "on Boundary ML Cloud today")
        XCTAssertEqual(vocabulary.applyAliases(to: "on boundary today"), "on Boundary ML today")
    }

    func testApplyingTwiceIsANoOp() throws {
        let vocabulary = try makeVocabulary()
        let once = vocabulary.applyAliases(to: "We use boundary at work.")
        XCTAssertEqual(once, "We use Boundary ML at work.")
        XCTAssertEqual(vocabulary.applyAliases(to: once), once, "alias inside its own term must not grow it")
    }

    func testEmptyVocabularyLeavesTextAlone() {
        XCTAssertEqual(Vocabulary().applyAliases(to: "human lair"), "human lair")
        XCTAssertNil(Vocabulary().promptReference())
    }

    func testFluidAudioFormatAndPromptReference() throws {
        let vocabulary = try makeVocabulary()
        let lines = vocabulary.fluidAudioSimpleFormat().split(separator: "\n")
        XCTAssertEqual(lines.first, "Boundary ML: boundary")
        XCTAssertTrue(lines.contains("HumanLayer: human lair, humanlair"))
        let reference = try XCTUnwrap(vocabulary.promptReference())
        XCTAssertTrue(reference.contains("- HumanLayer (may be heard as \"human lair\", \"humanlair\")"))
    }
}
