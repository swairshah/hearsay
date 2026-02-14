import Foundation
import os.log

private let downloadLogger = Logger(subsystem: "com.swair.hearsay", category: "download")

/// Downloads models from HuggingFace with progress reporting.
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    
    static let shared = ModelDownloader()
    
    // Model definitions
    enum Model: String, CaseIterable {
        case small = "qwen3-asr-0.6b"
        case large = "qwen3-asr-1.7b"
        
        var displayName: String {
            switch self {
            case .small: return "Fast (0.6B)"
            case .large: return "Quality (1.7B)"
            }
        }
        
        var description: String {
            switch self {
            case .small: return "Quick transcription, smaller size"
            case .large: return "Better accuracy, larger size"
            }
        }
        
        var huggingFaceId: String {
            switch self {
            case .small: return "Qwen/Qwen3-ASR-0.6B"
            case .large: return "Qwen/Qwen3-ASR-1.7B"
            }
        }
        
        var files: [String] {
            switch self {
            case .small:
                return [
                    "config.json",
                    "generation_config.json",
                    "model.safetensors",
                    "vocab.json",
                    "merges.txt"
                ]
            case .large:
                return [
                    "config.json",
                    "generation_config.json",
                    "model.safetensors.index.json",
                    "model-00001-of-00002.safetensors",
                    "model-00002-of-00002.safetensors",
                    "vocab.json",
                    "merges.txt"
                ]
            }
        }
        
        var estimatedSize: Int64 {
            switch self {
            case .small: return 1_288_000_000  // ~1.2 GB
            case .large: return 3_400_000_000  // ~3.4 GB
            }
        }
        
        var estimatedSizeString: String {
            ByteCountFormatter.string(fromByteCount: estimatedSize, countStyle: .file)
        }
    }
    
    // Download state
    @Published var isDownloading = false
    @Published var currentFile: String = ""
    @Published var fileProgress: Double = 0  // 0-1 for current file
    @Published var overallProgress: Double = 0  // 0-1 for all files
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var error: String?
    @Published var isComplete = false
    
    private var currentModel: Model?
    private var currentFileIndex = 0
    private var filesToDownload: [String] = []
    private var downloadSession: URLSession?
    private var currentTask: URLSessionDownloadTask?
    private var completionHandler: ((Bool) -> Void)?
    
    private override init() {
        super.init()
    }
    
    // MARK: - Public API
    
    /// Check if a model is installed
    func isModelInstalled(_ model: Model) -> Bool {
        let modelDir = Constants.modelsDirectory.appendingPathComponent(model.rawValue)
        
        // Check if all required files exist
        for file in model.files {
            let filePath = modelDir.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: filePath.path) {
                return false
            }
        }
        return true
    }
    
    /// Get list of installed models
    func installedModels() -> [Model] {
        Model.allCases.filter { isModelInstalled($0) }
    }
    
    /// Start downloading a model
    func download(_ model: Model, completion: @escaping (Bool) -> Void) {
        guard !isDownloading else {
            completion(false)
            return
        }
        
        downloadLogger.info("Starting download of \(model.rawValue)")
        
        // Reset state
        isDownloading = true
        isComplete = false
        error = nil
        currentModel = model
        currentFileIndex = 0
        filesToDownload = model.files
        downloadedBytes = 0
        totalBytes = model.estimatedSize
        completionHandler = completion
        
        // Create model directory
        let modelDir = Constants.modelsDirectory.appendingPathComponent(model.rawValue)
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        
        // Create session
        let config = URLSessionConfiguration.default
        downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        
        // Start downloading first file
        downloadNextFile()
    }
    
    /// Cancel current download
    func cancel() {
        currentTask?.cancel()
        downloadSession?.invalidateAndCancel()
        isDownloading = false
        error = "Download cancelled"
        completionHandler?(false)
    }
    
    // MARK: - Private
    
    private func downloadNextFile() {
        guard let model = currentModel, currentFileIndex < filesToDownload.count else {
            // All files downloaded
            downloadComplete()
            return
        }
        
        let filename = filesToDownload[currentFileIndex]
        currentFile = filename
        fileProgress = 0
        
        let modelDir = Constants.modelsDirectory.appendingPathComponent(model.rawValue)
        let destPath = modelDir.appendingPathComponent(filename)
        
        // Skip if already exists
        if FileManager.default.fileExists(atPath: destPath.path) {
            downloadLogger.info("Skipping \(filename) (already exists)")
            currentFileIndex += 1
            updateOverallProgress()
            downloadNextFile()
            return
        }
        
        let urlString = "https://huggingface.co/\(model.huggingFaceId)/resolve/main/\(filename)"
        guard let url = URL(string: urlString) else {
            error = "Invalid URL for \(filename)"
            downloadFailed()
            return
        }
        
        downloadLogger.info("Downloading \(filename) from \(urlString)")
        
        currentTask = downloadSession?.downloadTask(with: url)
        currentTask?.resume()
    }
    
    private func updateOverallProgress() {
        guard let model = currentModel else { return }
        
        // Simple progress: based on file count (not ideal but works)
        let filesComplete = Double(currentFileIndex)
        let totalFiles = Double(model.files.count)
        let currentFileContribution = fileProgress / totalFiles
        
        overallProgress = (filesComplete / totalFiles) + currentFileContribution
    }
    
    private func downloadComplete() {
        downloadLogger.info("Download complete!")
        isDownloading = false
        isComplete = true
        overallProgress = 1.0
        completionHandler?(true)
    }
    
    private func downloadFailed() {
        downloadLogger.error("Download failed: \(self.error ?? "unknown")")
        isDownloading = false
        completionHandler?(false)
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let model = currentModel else { return }
        
        let filename = filesToDownload[currentFileIndex]
        let modelDir = Constants.modelsDirectory.appendingPathComponent(model.rawValue)
        let destPath = modelDir.appendingPathComponent(filename)
        
        do {
            // Remove existing file if any
            try? FileManager.default.removeItem(at: destPath)
            
            // Move downloaded file to destination
            try FileManager.default.moveItem(at: location, to: destPath)
            
            downloadLogger.info("Saved \(filename)")
            
            // Move to next file
            currentFileIndex += 1
            updateOverallProgress()
            downloadNextFile()
            
        } catch {
            self.error = "Failed to save \(filename): \(error.localizedDescription)"
            downloadFailed()
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        
        if totalBytesExpectedToWrite > 0 {
            fileProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        }
        
        downloadedBytes += bytesWritten
        updateOverallProgress()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            // Don't report cancellation as error
            if (error as NSError).code == NSURLErrorCancelled {
                return
            }
            self.error = error.localizedDescription
            downloadFailed()
        }
    }
}
