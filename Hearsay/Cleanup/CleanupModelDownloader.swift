import Foundation
import os.log

private let logger = Logger(subsystem: "com.swair.hearsay", category: "cleanup-download")

/// Downloads and manages the local LLM cleanup model (GGUF format from HuggingFace).
/// Follows the same pattern as ModelDownloader for speech models.
final class CleanupModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    
    static let shared = CleanupModelDownloader()
    
    // MARK: - Model Definitions
    
    enum CleanupModel: String, CaseIterable {
        case qwen35_0_8b = "Qwen3.5-0.8B-Q4_K_M"
        
        var displayName: String {
            switch self {
            case .qwen35_0_8b: return "Qwen 3.5 0.8B (Fast cleanup)"
            }
        }
        
        var description: String {
            switch self {
            case .qwen35_0_8b: return "Removes filler words, fixes punctuation"
            }
        }
        
        var fileName: String {
            switch self {
            case .qwen35_0_8b: return "Qwen3.5-0.8B-Q4_K_M.gguf"
            }
        }
        
        var downloadURL: URL {
            switch self {
            case .qwen35_0_8b:
                return URL(string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf")!
            }
        }
        
        var estimatedSize: Int64 {
            switch self {
            case .qwen35_0_8b: return 535_000_000  // ~535 MB
            }
        }
        
        var estimatedSizeString: String {
            ByteCountFormatter.string(fromByteCount: estimatedSize, countStyle: .file)
        }
        
        var maxTokenCount: Int32 {
            switch self {
            case .qwen35_0_8b: return 2048
            }
        }
    }
    
    // MARK: - State
    
    @Published var isDownloading = false
    @Published var progress: Double = 0  // 0–1
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var error: String?
    @Published var isComplete = false
    
    private var downloadSession: URLSession?
    private var currentTask: URLSessionDownloadTask?
    private var currentModel: CleanupModel?
    private var completionHandler: ((Bool) -> Void)?
    
    static let enabledDefaultsKey = "cleanupEnabled"
    
    private override init() {
        super.init()
    }
    
    // MARK: - Paths
    
    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Hearsay/CleanupModels", isDirectory: true)
    }
    
    func modelPath(for model: CleanupModel) -> URL {
        Self.modelsDirectory.appendingPathComponent(model.fileName)
    }
    
    // MARK: - Public API
    
    /// Whether cleanup is enabled by user preference
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey) }
    }
    
    /// Check if the cleanup model is downloaded
    func isModelInstalled(_ model: CleanupModel = .qwen35_0_8b) -> Bool {
        FileManager.default.fileExists(atPath: modelPath(for: model).path)
    }
    
    /// Start downloading the cleanup model
    func download(_ model: CleanupModel = .qwen35_0_8b, completion: @escaping (Bool) -> Void) {
        guard !isDownloading else {
            completion(false)
            return
        }
        
        logger.info("Starting cleanup model download: \(model.rawValue)")
        
        // Reset state
        isDownloading = true
        isComplete = false
        error = nil
        progress = 0
        downloadedBytes = 0
        totalBytes = model.estimatedSize
        currentModel = model
        completionHandler = completion
        
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
        
        // Skip if already downloaded
        if isModelInstalled(model) {
            logger.info("Cleanup model already installed, skipping download")
            isDownloading = false
            isComplete = true
            progress = 1.0
            completion(true)
            return
        }
        
        // Create session and start download
        let config = URLSessionConfiguration.default
        downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        currentTask = downloadSession?.downloadTask(with: model.downloadURL)
        currentTask?.resume()
    }
    
    /// Cancel current download
    func cancel() {
        currentTask?.cancel()
        downloadSession?.invalidateAndCancel()
        isDownloading = false
        error = "Download cancelled"
        completionHandler?(false)
    }
    
    /// Delete the downloaded model
    func deleteModel(_ model: CleanupModel = .qwen35_0_8b) {
        let path = modelPath(for: model)
        try? FileManager.default.removeItem(at: path)
        isComplete = false
        logger.info("Deleted cleanup model: \(model.rawValue)")
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let model = currentModel else { return }
        
        let destPath = modelPath(for: model)
        
        do {
            try? FileManager.default.removeItem(at: destPath)
            try FileManager.default.moveItem(at: location, to: destPath)
            
            logger.info("Cleanup model saved: \(destPath.lastPathComponent)")
            
            isDownloading = false
            isComplete = true
            progress = 1.0
            completionHandler?(true)
        } catch {
            self.error = "Failed to save model: \(error.localizedDescription)"
            isDownloading = false
            completionHandler?(false)
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        downloadedBytes = totalBytesWritten
        if totalBytesExpectedToWrite > 0 {
            totalBytes = totalBytesExpectedToWrite
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            self.error = error.localizedDescription
            isDownloading = false
            completionHandler?(false)
        }
    }
}
