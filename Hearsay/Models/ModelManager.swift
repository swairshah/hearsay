import Foundation

/// Manages model downloading, installation, and updates.
final class ModelManager {
    
    static let shared = ModelManager()
    
    private let manifestURL = URL(string: "https://models.hearsay.app/manifest.json")!
    
    private init() {}
    
    // MARK: - Installed Models
    
    func installedModels() -> [URL] {
        let modelsDir = Constants.modelsDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: modelsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        
        return contents.filter { url in
            // Check if it's a directory containing model files
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return false
            }
            
            // Check for vocab.json (required for all models)
            let vocabPath = url.appendingPathComponent("vocab.json")
            return FileManager.default.fileExists(atPath: vocabPath.path)
        }
    }
    
    func isModelInstalled(_ modelId: String) -> Bool {
        let modelPath = Constants.modelsDirectory.appendingPathComponent(modelId)
        return FileManager.default.fileExists(atPath: modelPath.path)
    }
    
    // MARK: - Remote Models
    
    func fetchAvailableModels() async throws -> [ModelInfo] {
        let (data, _) = try await URLSession.shared.data(from: manifestURL)
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        return manifest.models
    }
    
    // MARK: - Download
    
    func download(
        _ model: ModelInfo,
        progress: @escaping (Double) -> Void
    ) async throws {
        // TODO: Implement actual download with progress
        // This would:
        // 1. Download the tar.gz file
        // 2. Verify checksum
        // 3. Extract to models directory
        // 4. Report progress throughout
        
        throw NSError(domain: "ModelManager", code: 1, 
                     userInfo: [NSLocalizedDescriptionKey: "Download not yet implemented"])
    }
    
    // MARK: - Delete
    
    func delete(_ modelId: String) throws {
        let modelPath = Constants.modelsDirectory.appendingPathComponent(modelId)
        try FileManager.default.removeItem(at: modelPath)
    }
}
