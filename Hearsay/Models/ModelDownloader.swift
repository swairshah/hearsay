import Foundation
import os.log
import WhisperKit

private let downloadLogger = Logger(subsystem: "com.swair.hearsay", category: "download")

/// Downloads models with progress reporting.
/// Supports both qwen_asr (file-by-file HuggingFace download) and WhisperKit variants.
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    
    static let shared = ModelDownloader()
    static let selectedModelDefaultsKey = "selectedModelId"
    
    enum Backend {
        case qwenASR
        case whisperKit
    }
    
    // Model definitions
    enum Model: String, CaseIterable {
        // qwen_asr models
        case small = "qwen3-asr-0.6b"
        case large = "qwen3-asr-1.7b"

        // WhisperKit models
        case whisperTinyEn = "openai_whisper-tiny.en"
        case whisperSmallEn = "openai_whisper-small.en"

        static var availableModels: [Model] {
            if Constants.supportsWhisperKitModels {
                return Self.allCases
            }
            return Self.allCases.filter { $0.backend == .qwenASR }
        }
        
        var backend: Backend {
            switch self {
            case .small, .large:
                return .qwenASR
            case .whisperTinyEn, .whisperSmallEn:
                return .whisperKit
            }
        }
        
        var displayName: String {
            switch self {
            case .small: return "Qwen Fast (0.6B)"
            case .large: return "Qwen Quality (1.7B)"
            case .whisperTinyEn: return "Whisper tiny.en"
            case .whisperSmallEn: return "Whisper small.en"
            }
        }
        
        var description: String {
            switch self {
            case .small: return "Quick transcription, smaller size"
            case .large: return "Better accuracy, larger size"
            case .whisperTinyEn: return "Fastest local transcription (English)"
            case .whisperSmallEn: return "Better accuracy than tiny.en (English)"
            }
        }
        
        var huggingFaceId: String? {
            switch self {
            case .small: return "Qwen/Qwen3-ASR-0.6B"
            case .large: return "Qwen/Qwen3-ASR-1.7B"
            case .whisperTinyEn, .whisperSmallEn: return nil
            }
        }

        var whisperVariant: String? {
            switch self {
            case .whisperTinyEn, .whisperSmallEn:
                return rawValue
            case .small, .large:
                return nil
            }
        }

        /// Cache path under Constants.whisperModelsRootDirectory
        var whisperCachePathComponents: [String]? {
            switch self {
            case .whisperTinyEn:
                // WhisperKit currently caches under:
                //   <downloadBase>/models/argmaxinc/whisperkit-coreml/openai_whisper-tiny.en
                return ["argmaxinc", "whisperkit-coreml", "openai_whisper-tiny.en"]
            case .whisperSmallEn:
                return ["argmaxinc", "whisperkit-coreml", "openai_whisper-small.en"]
            case .small, .large:
                return nil
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
            case .whisperTinyEn, .whisperSmallEn:
                return []
            }
        }
        
        var estimatedSize: Int64 {
            switch self {
            case .small: return 1_288_000_000  // ~1.2 GB
            case .large: return 3_400_000_000  // ~3.4 GB
            case .whisperTinyEn: return 75_000_000 // ~75 MB
            case .whisperSmallEn: return 466_000_000 // ~466 MB
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
    private var whisperDownloadTask: Task<Void, Never>?
    private var completionHandler: ((Bool) -> Void)?
    
    private override init() {
        super.init()
    }
    
    // MARK: - Public API
    
    func selectedModelPreference() -> Model? {
        guard let raw = UserDefaults.standard.string(forKey: Self.selectedModelDefaultsKey),
              let model = Model(rawValue: raw),
              Model.availableModels.contains(model) else {
            return nil
        }
        return model
    }
    
    func setSelectedModelPreference(_ model: Model) {
        guard Model.availableModels.contains(model) else {
            return
        }
        UserDefaults.standard.set(model.rawValue, forKey: Self.selectedModelDefaultsKey)
    }
    
    /// Check if a model is installed
    func isModelInstalled(_ model: Model) -> Bool {
        switch model.backend {
        case .qwenASR:
            let modelDir = Constants.modelsDirectory.appendingPathComponent(model.rawValue)
            for file in model.files {
                let filePath = modelDir.appendingPathComponent(file)
                if !FileManager.default.fileExists(atPath: filePath.path) {
                    return false
                }
            }
            return true
        case .whisperKit:
            // Primary expected cache path for current WhisperKit versions
            if let cachePathComponents = model.whisperCachePathComponents {
                let modelPath = cachePathComponents.reduce(Constants.whisperModelsRootDirectory) { partialURL, component in
                    partialURL.appendingPathComponent(component, isDirectory: true)
                }
                if FileManager.default.fileExists(atPath: modelPath.path) {
                    return true
                }
            }

            // Backward-compatible fallback for older folder layouts
            let legacyPathComponents: [String]
            switch model {
            case .whisperTinyEn:
                legacyPathComponents = ["openai", "whisper-tiny.en"]
            case .whisperSmallEn:
                legacyPathComponents = ["openai", "whisper-small.en"]
            case .small, .large:
                legacyPathComponents = []
            }

            if !legacyPathComponents.isEmpty {
                let legacyPath = legacyPathComponents.reduce(Constants.whisperModelsRootDirectory) { partialURL, component in
                    partialURL.appendingPathComponent(component, isDirectory: true)
                }
                return FileManager.default.fileExists(atPath: legacyPath.path)
            }

            return false
        }
    }
    
    /// Get list of installed models
    func installedModels() -> [Model] {
        Model.availableModels.filter { isModelInstalled($0) }
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
        currentFile = ""
        fileProgress = 0
        overallProgress = 0
        downloadedBytes = 0
        totalBytes = model.estimatedSize
        completionHandler = completion

        if isModelInstalled(model) {
            downloadLogger.info("Model already installed: \(model.rawValue)")
            downloadComplete()
            return
        }

        switch model.backend {
        case .qwenASR:
            // Create model directory
            let modelDir = Constants.modelsDirectory.appendingPathComponent(model.rawValue)
            try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

            // Create session
            let config = URLSessionConfiguration.default
            downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)

            // Start downloading first file
            downloadNextFile()

        case .whisperKit:
            try? FileManager.default.createDirectory(at: Constants.whisperModelsDirectory, withIntermediateDirectories: true)
            downloadWhisperModel(model)
        }
    }
    
    /// Cancel current download
    func cancel() {
        currentTask?.cancel()
        whisperDownloadTask?.cancel()
        downloadSession?.invalidateAndCancel()
        isDownloading = false
        error = "Download cancelled"
        completionHandler?(false)
    }
    
    // MARK: - Private

    private func downloadWhisperModel(_ model: Model) {
        guard let variant = model.whisperVariant else {
            error = "Invalid Whisper variant"
            downloadFailed()
            return
        }

        currentFile = model.displayName
        fileProgress = 0
        overallProgress = 0

        whisperDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await WhisperKit.download(variant: variant, downloadBase: Constants.whisperModelsDirectory) { progress in
                    let fraction = progress.fractionCompleted
                    DispatchQueue.main.async {
                        self.fileProgress = fraction
                        self.overallProgress = fraction
                        self.downloadedBytes = Int64(Double(model.estimatedSize) * fraction)
                        self.totalBytes = model.estimatedSize
                    }
                }

                DispatchQueue.main.async {
                    self.downloadComplete()
                }
            } catch {
                if Task.isCancelled { return }
                DispatchQueue.main.async {
                    self.error = "Failed to download \(model.displayName): \(error.localizedDescription)"
                    self.downloadFailed()
                }
            }
        }
    }
    
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
        
        guard let huggingFaceId = model.huggingFaceId else {
            error = "Missing HuggingFace ID for \(model.displayName)"
            downloadFailed()
            return
        }

        let urlString = "https://huggingface.co/\(huggingFaceId)/resolve/main/\(filename)"
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

        switch model.backend {
        case .qwenASR:
            // Simple progress: based on file count
            let filesComplete = Double(currentFileIndex)
            let totalFiles = Double(max(1, model.files.count))
            let currentFileContribution = fileProgress / totalFiles
            overallProgress = (filesComplete / totalFiles) + currentFileContribution
        case .whisperKit:
            overallProgress = fileProgress
        }
    }
    
    private func downloadComplete() {
        downloadLogger.info("Download complete")
        isDownloading = false
        isComplete = true
        fileProgress = 1.0
        overallProgress = 1.0
        completionHandler?(true)

        completionHandler = nil
        currentTask = nil
        whisperDownloadTask = nil
    }
    
    private func downloadFailed() {
        downloadLogger.error("Download failed: \(self.error ?? "unknown")")
        isDownloading = false
        completionHandler?(false)

        completionHandler = nil
        currentTask = nil
        whisperDownloadTask = nil
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
