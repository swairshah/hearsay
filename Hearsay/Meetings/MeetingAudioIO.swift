import AVFoundation
import Foundation

/// Small audio file helpers for meeting recording.
enum MeetingAudioIO {

    static let sampleRate: Double = 16_000

    static var monoFloatFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// 16 kHz mono 16-bit WAV — the same format dictation records, which every
    /// speech backend (qwen_asr, WhisperKit, Parakeet) reads.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let format = monoFloatFormat
        let file = try AVAudioFile(forWriting: url, settings: pcm16Settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = makeBuffer(samples, format: format) else {
            throw SpeechTranscriptionError.failed("Unable to allocate audio buffer")
        }
        try file.write(from: buffer)
    }

    static func makeBuffer(_ samples: [Float], format: AVAudioFormat = monoFloatFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    channel.update(from: base, count: samples.count)
                }
            }
        }
        return buffer
    }

    private static var pcm16Settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
    }

    /// A CAF track writer (16-bit PCM). CAF stays readable if the app dies mid-write.
    static func makeTrackWriter(at url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: pcm16Settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Read any audio file as 16 kHz mono Float32.
    static func readMonoSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(max(4096, Int(format.sampleRate)))
        let resampler = Resampler()
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * sampleRate / format.sampleRate) + 1024)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            samples.append(contentsOf: resampler.convert(buffer))
        }
        return samples
    }

    /// Compress a finished CAF track to AAC (~8x smaller). Returns the new file.
    static func compressToAAC(_ source: URL) async throws -> URL {
        let destination = source.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SpeechTranscriptionError.failed("AAC export is unavailable")
        }
        export.outputURL = destination
        export.outputFileType = .m4a

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            throw export.error ?? SpeechTranscriptionError.failed("AAC export failed")
        }
        try? FileManager.default.removeItem(at: source)
        return destination
    }

    /// Converts arbitrary PCM buffers to 16 kHz mono Float32.
    final class Resampler {
        private var converter: AVAudioConverter?
        private var sourceFormat: AVAudioFormat?
        private let target = MeetingAudioIO.monoFloatFormat

        func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
            let format = buffer.format
            if format.sampleRate == target.sampleRate, format.channelCount == 1, format.commonFormat == .pcmFormatFloat32,
               let channel = buffer.floatChannelData?[0] {
                return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }

            if sourceFormat != format {
                converter = AVAudioConverter(from: format, to: target)
                sourceFormat = format
            }
            guard let converter else { return [] }

            let ratio = target.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil, let channel = output.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
    }
}
