import Foundation

enum SpeechTranscriptionError: Error, LocalizedError {
    case noOutput
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noOutput:
            return "No transcription output"
        case .failed(let message):
            return "Transcription failed: \(message)"
        }
    }
}

protocol SpeechTranscribing {
    func transcribe(audioURL: URL) async throws -> String
}
