import Foundation

/// Information about an available model.
struct ModelInfo: Codable, Identifiable {
    let id: String           // e.g., "qwen3-asr-0.6b"
    let name: String         // e.g., "Fast (0.6B)"
    let description: String  // Brief description
    let size: Int64          // Size in bytes
    let url: URL             // Download URL
    let checksum: String     // SHA256
    let version: String      // e.g., "1.0.0"
    let minAppVersion: String // Minimum app version required
    
    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Manifest containing all available models.
struct ModelManifest: Codable {
    let version: String
    let models: [ModelInfo]
}
