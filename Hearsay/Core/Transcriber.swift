import Foundation

/// Runs the bundled qwen_asr binary to transcribe audio files.
final class Transcriber {
    
    enum TranscriptionError: Error, LocalizedError {
        case binaryNotFound
        case modelNotFound(String)
        case transcriptionFailed(String)
        case noOutput
        
        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Transcription engine not found in app bundle"
            case .modelNotFound(let path):
                return "Model not found at: \(path)"
            case .transcriptionFailed(let message):
                return "Transcription failed: \(message)"
            case .noOutput:
                return "No transcription output"
            }
        }
    }
    
    private let modelPath: String
    
    /// Initialize with a model directory path
    init(modelPath: String) {
        self.modelPath = modelPath
    }
    
    /// Convenience initializer using default model
    convenience init?() {
        let modelDir = Constants.modelsDirectory.appendingPathComponent(Constants.defaultModelId)
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            return nil
        }
        self.init(modelPath: modelDir.path)
    }
    
    // MARK: - Public
    
    /// Transcribe an audio file and return the text
    func transcribe(audioURL: URL) async throws -> String {
        let binaryURL = try findBinary()
        
        // Verify model exists
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw TranscriptionError.modelNotFound(modelPath)
        }
        
        // Build command
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "-d", modelPath,
            "-i", audioURL.path,
            "--silent"
        ]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        print("Transcriber: Running \(binaryURL.path) -d \(modelPath) -i \(audioURL.path)")
        
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()
                
                process.terminationHandler = { _ in
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                    
                    if process.terminationStatus != 0 {
                        print("Transcriber: Error - \(errorOutput)")
                        continuation.resume(throwing: TranscriptionError.transcriptionFailed(errorOutput))
                        return
                    }
                    
                    if output.isEmpty {
                        continuation.resume(throwing: TranscriptionError.noOutput)
                        return
                    }
                    
                    print("Transcriber: Success - \"\(output)\"")
                    continuation.resume(returning: output)
                }
            } catch {
                continuation.resume(throwing: TranscriptionError.transcriptionFailed(error.localizedDescription))
            }
        }
    }
    
    // MARK: - Private
    
    private func findBinary() throws -> URL {
        // Look for qwen_asr in the app bundle's MacOS directory
        let bundle = Bundle.main
        
        // Try MacOS directory first
        if let binaryURL = bundle.executableURL?.deletingLastPathComponent().appendingPathComponent("qwen_asr"),
           FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            return binaryURL
        }
        
        // Try Resources directory
        if let binaryURL = bundle.url(forResource: "qwen_asr", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            return binaryURL
        }
        
        // Development fallback: look in parent project directory
        let devPath = bundle.bundlePath
            .components(separatedBy: "/")
            .prefix(while: { $0 != "DerivedData" && $0 != "Build" })
            .joined(separator: "/")
        let devBinary = URL(fileURLWithPath: devPath)
            .appendingPathComponent("qwen-asr/qwen_asr")
        
        if FileManager.default.isExecutableFile(atPath: devBinary.path) {
            print("Transcriber: Using development binary at \(devBinary.path)")
            return devBinary
        }
        
        // Also check hardcoded dev path
        let hardcodedDev = URL(fileURLWithPath: "/Users/swair/work/misc/qwen-asr/qwen_asr")
        if FileManager.default.isExecutableFile(atPath: hardcodedDev.path) {
            print("Transcriber: Using development binary at \(hardcodedDev.path)")
            return hardcodedDev
        }
        
        throw TranscriptionError.binaryNotFound
    }
    
    // MARK: - Model Discovery
    
    static func availableModels() -> [URL] {
        let modelsDir = Constants.modelsDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: modelsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        
        return contents.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }
    
    static var hasAnyModel: Bool {
        !availableModels().isEmpty
    }
}
