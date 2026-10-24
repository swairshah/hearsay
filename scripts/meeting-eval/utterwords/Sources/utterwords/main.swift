// Transcribe given time ranges of a 16 kHz track one by one (like Hearsay's live
// pipeline) and print per-word timings, optionally with CTC vocabulary boosting.
//   utterwords <audio> <ranges.json [[start,end],…]> <out.json> [--vocab terms.txt] [--model v2|v3]
import FluidAudio
import Foundation

struct Word: Codable { let word: String; let start: Double; let end: Double; let conf: Float }
struct Replacement: Codable { let original: String; let replacement: String; let score: Float? }
struct Utterance: Codable {
    let start: Double; let end: Double
    let text: String; let vocabText: String?
    let replacements: [Replacement]
    let words: [Word]
}
struct Output: Codable { let model: String; let seconds: Double; let vocabSeconds: Double; let utterances: [Utterance] }

func words(from tokens: [TokenTiming], offset: Double) -> [Word] {
    var out: [Word] = []
    var text = "", start = 0.0, end = 0.0, confs: [Float] = []
    func flush() {
        if !text.isEmpty { out.append(Word(word: text, start: start + offset, end: end + offset, conf: confs.reduce(0, +) / Float(max(confs.count, 1)))) }
    }
    for token in tokens {
        if token.token.hasPrefix(" ") || text.isEmpty {
            flush()
            text = token.token.trimmingCharacters(in: .whitespaces); start = token.startTime; confs = []
        } else {
            text += token.token
        }
        end = token.endTime; confs.append(token.confidence)
    }
    flush()
    return out
}

let args = CommandLine.arguments
let audioURL = URL(fileURLWithPath: args[1])
let ranges = try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let outURL = URL(fileURLWithPath: args[3])
let vocabPath = args.firstIndex(of: "--vocab").map { args[$0 + 1] }
let version: AsrModelVersion = (args.firstIndex(of: "--model").map { args[$0 + 1] } == "v2") ? .v2 : .v3

let samples = try AudioConverter().resampleAudioFile(audioURL)
let asr = AsrManager(config: .init())
try await asr.loadModels(try await AsrModels.downloadAndLoad(version: version))

var rescorer: VocabularyRescorer?
var spotter: CtcKeywordSpotter?
var vocab: CustomVocabularyContext?
if let vocabPath {
    let (context, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(from: vocabPath)
    let keywordSpotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
    rescorer = try await VocabularyRescorer.create(
        spotter: keywordSpotter, vocabulary: context, config: .default,
        ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctcModels.variant))
    spotter = keywordSpotter
    vocab = context
}

var utterances: [Utterance] = []
var asrSeconds = 0.0, vocabSeconds = 0.0
for range in ranges {
    let lo = max(0, Int(range[0] * 16_000)), hi = min(samples.count, Int(range[1] * 16_000))
    guard hi - lo > 1_600 else { continue }
    let slice = Array(samples[lo..<hi])
    var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let t0 = Date()
    let result = try await asr.transcribe(slice, decoderState: &state)
    asrSeconds += Date().timeIntervalSince(t0)

    var vocabText: String?
    var replacements: [Replacement] = []
    if let rescorer, let spotter, let vocab, let tokens = result.tokenTimings, !tokens.isEmpty {
        let t1 = Date()
        let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: slice, customVocabulary: vocab, minScore: nil)
        let config = ContextBiasingConstants.rescorerConfig(forVocabSize: vocab.terms.count)
        let output = rescorer.ctcTokenRescore(
            transcript: result.text, tokenTimings: tokens, logProbs: spot.logProbs,
            frameDuration: spot.frameDuration, cbw: config.cbw, marginSeconds: 0.5, minSimilarity: config.minSimilarity)
        vocabText = output.text
        replacements = output.replacements.filter(\.shouldReplace).map {
            Replacement(original: $0.originalWord, replacement: $0.replacementWord ?? "", score: $0.replacementScore)
        }
        vocabSeconds += Date().timeIntervalSince(t1)
    }
    utterances.append(Utterance(
        start: range[0], end: range[1], text: result.text, vocabText: vocabText,
        replacements: replacements, words: words(from: result.tokenTimings ?? [], offset: Double(lo) / 16_000)))
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted]
try encoder.encode(Output(model: "\(version)", seconds: asrSeconds, vocabSeconds: vocabSeconds, utterances: utterances)).write(to: outURL)
print("\(utterances.count) utterances, asr \(String(format: "%.1f", asrSeconds)) s, vocab \(String(format: "%.1f", vocabSeconds)) s")
