import Foundation
import AVFoundation
import WhisperKit

/// Transcribes audio using WhisperKit models downloaded locally.
actor WhisperTranscriber: SpeechTranscribing {
    private let modelName: String
    private let downloadBase: URL

    private var whisperKit: WhisperKit?
    private var loadingTask: Task<WhisperKit, Error>?

    /// Whisper artifacts to filter out of transcription results.
    private static let artifacts: Set<String> = [
        "[BLANK_AUDIO]",
        "[NO_SPEECH]",
        "(blank audio)",
        "(no speech)",
        "[MUSIC]",
        "[APPLAUSE]",
        "[LAUGHTER]"
    ]

    init(modelName: String, downloadBase: URL = Constants.whisperModelsDirectory) {
        self.modelName = modelName
        self.downloadBase = downloadBase
    }

    func transcribe(audioURL: URL) async throws -> String {
        let whisperKit = try await loadModelIfNeeded()
        let audioBuffer = try Self.loadAudioBuffer(from: audioURL)
        guard !audioBuffer.isEmpty else {
            throw SpeechTranscriptionError.noOutput
        }

        let results = try await whisperKit.transcribe(audioArray: audioBuffer)
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let cleaned = Self.removeArtifacts(from: text)
        guard !cleaned.isEmpty else {
            throw SpeechTranscriptionError.noOutput
        }

        return cleaned
    }

    func prewarm() async {
        _ = try? await loadModelIfNeeded()
    }

    private func loadModelIfNeeded() async throws -> WhisperKit {
        if let whisperKit {
            return whisperKit
        }

        if let loadingTask {
            return try await loadingTask.value
        }

        let task = Task { () throws -> WhisperKit in
            try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
            let config = WhisperKitConfig(
                model: modelName,
                downloadBase: downloadBase,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: true
            )
            return try await WhisperKit(config)
        }

        loadingTask = task

        do {
            let loaded = try await task.value
            whisperKit = loaded
            loadingTask = nil
            return loaded
        } catch {
            loadingTask = nil
            throw SpeechTranscriptionError.failed(error.localizedDescription)
        }
    }

    // MARK: - Audio decoding

    private static func loadAudioBuffer(from audioURL: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: audioURL)
        let inputFormat = file.processingFormat

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw SpeechTranscriptionError.failed("Failed to create target audio format")
        }

        let inputFrameCapacity = AVAudioFrameCount(file.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCapacity) else {
            throw SpeechTranscriptionError.failed("Failed to allocate input buffer")
        }
        try file.read(into: inputBuffer)

        // Fast path: already Float32 16k mono
        if inputFormat.commonFormat == .pcmFormatFloat32,
           inputFormat.sampleRate == 16_000,
           inputFormat.channelCount == 1,
           let channelData = inputBuffer.floatChannelData?[0] {
            let count = Int(inputBuffer.frameLength)
            return Array(UnsafeBufferPointer(start: channelData, count: count))
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SpeechTranscriptionError.failed("Failed to create audio converter")
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw SpeechTranscriptionError.failed("Failed to allocate output buffer")
        }

        var providedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus -> AVAudioBuffer? in
            if providedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error {
            throw SpeechTranscriptionError.failed(conversionError?.localizedDescription ?? "Audio conversion failed")
        }

        guard let channelData = outputBuffer.floatChannelData?[0] else {
            throw SpeechTranscriptionError.failed("Converted buffer missing channel data")
        }

        let count = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData, count: count))
    }

    private static func removeArtifacts(from text: String) -> String {
        var cleaned = text
        for artifact in artifacts {
            cleaned = cleaned.replacingOccurrences(of: artifact, with: "")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
