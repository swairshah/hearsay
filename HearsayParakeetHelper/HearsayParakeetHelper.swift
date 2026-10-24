import AVFoundation
import Darwin
import FluidAudio
import Foundation

private struct HelperRequest: Codable {
    let id: Int
    let command: String
    let model: String?
    let audioPath: String?
    /// `diarize_assign`: `[start, end]` pairs in seconds from the session start.
    var ranges: [[Double]]? = nil
}

private struct HelperResponse: Codable {
    let id: Int
    let ok: Bool
    let text: String?
    let error: String?
    /// `diarize_assign`: dominant speaker slot per range, or -1 for "no speech found".
    var speakers: [Int]? = nil
}

private enum HelperError: Error, LocalizedError {
    case invalidModel(String?)
    case missingAudioPath
    case notInitialized
    case unsupportedCommand(String)
    case warmupAudioAllocationFailed
    case diarizerNotStarted
    case missingRanges

    var errorDescription: String? {
        switch self {
        case .invalidModel(let model):
            return "Invalid Parakeet model: \(model ?? "nil")"
        case .missingAudioPath:
            return "Missing audio path"
        case .notInitialized:
            return "Parakeet model is not initialized"
        case .unsupportedCommand(let command):
            return "Unsupported command: \(command)"
        case .warmupAudioAllocationFailed:
            return "Unable to allocate Parakeet warmup audio"
        case .diarizerNotStarted:
            return "Diarization session has not been started"
        case .missingRanges:
            return "Missing ranges"
        }
    }
}

private enum HelperParakeetModel: String {
    case englishV2 = "parakeet-tdt-0.6b-v2-coreml"
    case multilingualV3 = "parakeet-tdt-0.6b-v3-coreml"

    var asrVersion: AsrModelVersion {
        switch self {
        case .englishV2: return .v2
        case .multilingualV3: return .v3
        }
    }
}

private actor ParakeetRunner {
    private var asr: AsrManager?
    private var models: AsrModels?
    private var currentModel: HelperParakeetModel?
    private var warmedModels = Set<HelperParakeetModel>()

    func handle(_ request: HelperRequest) async throws -> HelperResponse {
        let model = try request.model.map { rawValue in
            guard let model = HelperParakeetModel(rawValue: rawValue) else {
                throw HelperError.invalidModel(request.model)
            }
            return model
        }

        switch request.command {
        case "load":
            guard let model else { throw HelperError.invalidModel(request.model) }
            try await ensureLoaded(model)
            return HelperResponse(id: request.id, ok: true, text: nil, error: nil)

        case "prewarm":
            guard let model else { throw HelperError.invalidModel(request.model) }
            try await prewarm(model)
            return HelperResponse(id: request.id, ok: true, text: nil, error: nil)

        case "transcribe":
            guard let model else { throw HelperError.invalidModel(request.model) }
            guard let audioPath = request.audioPath else { throw HelperError.missingAudioPath }
            try await ensureLoaded(model)
            let text = try await transcribe(URL(fileURLWithPath: audioPath))
            return HelperResponse(id: request.id, ok: true, text: text, error: nil)

        case "diarize_start":
            try await diarization.start()
            return HelperResponse(id: request.id, ok: true, text: nil, error: nil)

        case "diarize_push":
            guard let audioPath = request.audioPath else { throw HelperError.missingAudioPath }
            try diarization.push(audioURL: URL(fileURLWithPath: audioPath))
            return HelperResponse(id: request.id, ok: true, text: nil, error: nil)

        case "diarize_file":
            guard let audioPath = request.audioPath else { throw HelperError.missingAudioPath }
            try await diarization.processFile(URL(fileURLWithPath: audioPath))
            return HelperResponse(id: request.id, ok: true, text: nil, error: nil)

        case "diarize_finish":
            try diarization.finish()
            return HelperResponse(id: request.id, ok: true, text: nil, error: nil)

        case "diarize_assign":
            guard let ranges = request.ranges else { throw HelperError.missingRanges }
            let speakers = try diarization.assign(ranges: ranges)
            return HelperResponse(id: request.id, ok: true, text: nil, error: nil, speakers: speakers)

        default:
            throw HelperError.unsupportedCommand(request.command)
        }
    }

    private let diarization = DiarizationSession()

    private func ensureLoaded(_ model: HelperParakeetModel) async throws {
        if currentModel == model, asr != nil {
            return
        }

        if currentModel != model {
            asr = nil
            models = nil
        }

        let downloadedModels = try await AsrModels.downloadAndLoad(version: model.asrVersion)
        models = downloadedModels

        let manager = AsrManager(config: .init())
        try await manager.loadModels(downloadedModels)
        asr = manager
        currentModel = model
    }

    private func prewarm(_ model: HelperParakeetModel) async throws {
        try await ensureLoaded(model)
        guard !warmedModels.contains(model), let asr else {
            return
        }

        let warmupURL = try Self.makeWarmupAudioFile()
        defer { try? FileManager.default.removeItem(at: warmupURL) }

        var decoderState = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
        _ = try await asr.transcribe(warmupURL, decoderState: &decoderState)

        warmedModels.insert(model)
    }

    private func transcribe(_ url: URL) async throws -> String {
        guard let asr else {
            throw HelperError.notInitialized
        }

        var decoderState = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(url, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeWarmupAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hearsay-parakeet-warmup-\(UUID().uuidString).wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000) else {
            throw HelperError.warmupAudioAllocationFailed
        }

        buffer.frameLength = 24_000
        if let samples = buffer.floatChannelData?[0] {
            let sampleRate = Float(format.sampleRate)
            let frequency: Float = 220
            let amplitude: Float = 0.003
            for index in 0..<Int(buffer.frameLength) {
                let phase = 2 * Float.pi * frequency * Float(index) / sampleRate
                samples[index] = sin(phase) * amplitude
            }
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

/// Streaming speaker diarization (NVIDIA Sortformer via FluidAudio) for the
/// remote side of a meeting. The app pushes system-audio chunks as they are
/// recorded and asks which speaker slot dominated each transcribed segment.
private final class DiarizationSession {
    private static let config = SortformerConfig.balancedV2_1

    private var models: SortformerModels?
    private var diarizer: SortformerDiarizer?

    /// Loads (downloading on first use) the Sortformer models and resets the session.
    func start() async throws {
        let models = try await loadModels()
        let diarizer = SortformerDiarizer(config: Self.config)
        diarizer.initialize(models: models)
        self.diarizer = diarizer
    }

    func push(audioURL: URL) throws {
        guard let diarizer else { throw HelperError.diarizerNotStarted }
        let samples = try Self.readMonoSamples(audioURL)
        guard !samples.isEmpty else { return }
        try diarizer.addAudio(samples, sourceSampleRate: nil)
        // `process()` consumes at most one model chunk per call; drain them all.
        while try diarizer.process() != nil {}
    }

    /// Diarize a whole recording in one pass (used to re-run speaker detection).
    func processFile(_ url: URL) async throws {
        let models = try await loadModels()
        let diarizer = SortformerDiarizer(config: Self.config)
        diarizer.initialize(models: models)
        _ = try diarizer.processComplete(audioFileURL: url, finalizeOnCompletion: true)
        self.diarizer = diarizer
    }

    func finish() throws {
        guard let diarizer else { throw HelperError.diarizerNotStarted }
        _ = try diarizer.finalizeSession()
    }

    /// For each `[start, end]`, the speaker slot with the most overlapping speech
    /// (finalized or still tentative), or -1 when nobody overlaps enough.
    func assign(ranges: [[Double]]) throws -> [Int] {
        guard let diarizer else { throw HelperError.diarizerNotStarted }
        let speakers = diarizer.timeline.speakers

        return ranges.map { range in
            guard range.count == 2, range[1] > range[0] else { return -1 }
            let start = Float(range[0])
            let end = Float(range[1])

            var best = -1
            var bestOverlap: Float = 0
            for (slot, speaker) in speakers {
                var overlap: Float = 0
                for segment in speaker.finalizedSegments + speaker.tentativeSegments {
                    overlap += max(0, min(end, segment.endTime) - max(start, segment.startTime))
                }
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    best = slot
                }
            }

            // Require a meaningful share of the segment before trusting the label.
            let minimum = min(0.4, (end - start) * 0.2)
            return bestOverlap >= minimum ? best : -1
        }
    }

    private func loadModels() async throws -> SortformerModels {
        if let models { return models }
        let loaded = try await SortformerModels.loadFromHuggingFace(
            config: Self.config,
            cacheDirectory: Self.cacheDirectory()
        )
        models = loaded
        return loaded
    }

    /// Keep diarizer models next to the ASR models (Hearsay sets XDG_CACHE_HOME).
    private static func cacheDirectory() -> URL? {
        guard let root = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"], !root.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("fluidaudio/Models", isDirectory: true)
    }

    private static func readMonoSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            return []
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        if format.sampleRate == 16_000, format.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: count))
        }
        let converter = AudioConverter(sampleRate: 16_000)
        return try converter.resampleAudioFile(url)
    }
}

@main
private enum HearsayParakeetHelper {
    static func main() async {
        let runner = ParakeetRunner()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let protocolOutput = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)

        while let line = readLine() {
            guard let data = line.data(using: .utf8) else {
                continue
            }

            do {
                let request = try decoder.decode(HelperRequest.self, from: data)
                let response: HelperResponse
                do {
                    response = try await runner.handle(request)
                } catch {
                    response = HelperResponse(
                        id: request.id,
                        ok: false,
                        text: nil,
                        error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                }

                try write(response, to: protocolOutput, encoder: encoder)
            } catch {
                let response = HelperResponse(
                    id: -1,
                    ok: false,
                    text: nil,
                    error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
                try? write(response, to: protocolOutput, encoder: encoder)
            }
        }
    }

    private static func write(_ response: HelperResponse, to output: FileHandle, encoder: JSONEncoder) throws {
        let data = try encoder.encode(response)
        output.write(data)
        output.write(Data([0x0A]))
    }
}
