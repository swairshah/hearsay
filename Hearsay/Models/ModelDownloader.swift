import Foundation
import os.log
import WhisperKit

private let downloadLogger = Logger(subsystem: "com.swair.hearsay", category: "download")

enum ModelDownloaderError: LocalizedError {
    case busy
    case invalidModel
    case deletionIncomplete

    var errorDescription: String? {
        switch self {
        case .busy:
            return "A download is in progress."
        case .invalidModel:
            return "Unsupported model."
        case .deletionIncomplete:
            return "Some model files could not be removed."
        }
    }
}

/// Downloads models with progress reporting.
/// Supports qwen_asr, WhisperKit, and FluidAudio/Parakeet variants.
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    
    static let shared = ModelDownloader()
    static let selectedModelDefaultsKey = "selectedModelId"
    
    enum Backend {
        case qwenASR
        case whisperKit
        case parakeet
    }
    
    // Model definitions
    enum Model: String, CaseIterable {
        // qwen_asr models
        case small = "qwen3-asr-0.6b"
        case large = "qwen3-asr-1.7b"

        // WhisperKit models
        case whisperTinyEn = "openai_whisper-tiny.en"
        case whisperSmallEn = "openai_whisper-small.en"

        // FluidAudio Parakeet models
        case parakeetEnglishV2 = "parakeet-tdt-0.6b-v2-coreml"
        case parakeetMultilingualV3 = "parakeet-tdt-0.6b-v3-coreml"

        static var availableModels: [Model] {
            Self.allCases.filter { model in
                switch model.backend {
                case .qwenASR:
                    return true
                case .whisperKit:
                    return Constants.supportsWhisperKitModels
                case .parakeet:
                    return Constants.supportsParakeetModels
                }
            }
        }
        
        var backend: Backend {
            switch self {
            case .small, .large:
                return .qwenASR
            case .whisperTinyEn, .whisperSmallEn:
                return .whisperKit
            case .parakeetEnglishV2, .parakeetMultilingualV3:
                return .parakeet
            }
        }
        
        var displayName: String {
            switch self {
            case .small: return "Qwen Fast (0.6B)"
            case .large: return "Qwen Quality (1.7B)"
            case .whisperTinyEn: return "Whisper tiny.en"
            case .whisperSmallEn: return "Whisper small.en"
            case .parakeetEnglishV2:
                return ParakeetModel.englishV2.displayName
            case .parakeetMultilingualV3:
                return ParakeetModel.multilingualV3.displayName
            }
        }
        
        var description: String {
            switch self {
            case .small: return "Quick transcription, smaller size"
            case .large: return "Better accuracy, larger size"
            case .whisperTinyEn: return "Fastest local transcription (English)"
            case .whisperSmallEn: return "Better accuracy than tiny.en (English)"
            case .parakeetEnglishV2:
                return ParakeetModel.englishV2.description
            case .parakeetMultilingualV3:
                return ParakeetModel.multilingualV3.description
            }
        }
        
        var huggingFaceId: String? {
            switch self {
            case .small: return "Qwen/Qwen3-ASR-0.6B"
            case .large: return "Qwen/Qwen3-ASR-1.7B"
            case .whisperTinyEn, .whisperSmallEn, .parakeetEnglishV2, .parakeetMultilingualV3: return nil
            }
        }

        var whisperVariant: String? {
            switch self {
            case .whisperTinyEn, .whisperSmallEn:
                return rawValue
            case .small, .large, .parakeetEnglishV2, .parakeetMultilingualV3:
                return nil
            }
        }

        var parakeetModel: ParakeetModel? {
            ParakeetModel(rawValue: rawValue)
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
            case .small, .large, .parakeetEnglishV2, .parakeetMultilingualV3:
                return nil
            }
        }

        /// Legacy cache path components for older WhisperKit folder layouts.
        var whisperLegacyCachePathComponents: [String]? {
            switch self {
            case .whisperTinyEn:
                return ["openai", "whisper-tiny.en"]
            case .whisperSmallEn:
                return ["openai", "whisper-small.en"]
            case .small, .large, .parakeetEnglishV2, .parakeetMultilingualV3:
                return nil
            }
        }

        /// All on-disk cache directories (current + legacy) where this Whisper model may live.
        /// Single source of truth for both install detection and deletion.
        var whisperCacheDirectories: [URL] {
            let root = Constants.whisperModelsRootDirectory
            return [whisperCachePathComponents, whisperLegacyCachePathComponents]
                .compactMap { $0 }
                .map { components in
                    components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
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
            case .whisperTinyEn, .whisperSmallEn, .parakeetEnglishV2, .parakeetMultilingualV3:
                return []
            }
        }
        
        var estimatedSize: Int64 {
            switch self {
            case .small: return 1_288_000_000  // ~1.2 GB
            case .large: return 3_400_000_000  // ~3.4 GB
            case .whisperTinyEn: return 75_000_000 // ~75 MB
            case .whisperSmallEn: return 466_000_000 // ~466 MB
            case .parakeetEnglishV2:
                return ParakeetModel.englishV2.estimatedSize
            case .parakeetMultilingualV3:
                return ParakeetModel.multilingualV3.estimatedSize
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
    private var parakeetDownloadTask: Task<Void, Never>?
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

    /// Clear the persisted active-model preference (e.g. after deleting the active model with none left).
    func clearSelectedModelPreference() {
        UserDefaults.standard.removeObject(forKey: Self.selectedModelDefaultsKey)
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
            // Installed if any current/legacy cache directory exists.
            return model.whisperCacheDirectories.contains { directory in
                FileManager.default.fileExists(atPath: directory.path)
            }
        case .parakeet:
            guard let parakeetModel = model.parakeetModel else {
                return false
            }

            return parakeetModel.cachedDirectories().contains { directory in
                ParakeetModel.containsCompiledModel(in: directory)
            }
        }
    }
    
    /// Get list of installed models
    func installedModels() -> [Model] {
        Model.availableModels.filter { isModelInstalled($0) }
    }

    /// Delete an installed model's files from disk. Backend-specific.
    /// Throws if removal fails or the model is still detected as installed afterward.
    func delete(_ model: Model) async throws {
        guard !isDownloading else {
            throw ModelDownloaderError.busy
        }

        downloadLogger.info("Deleting model \(model.rawValue)")

        do {
            switch model.backend {
            case .qwenASR:
                let modelDir = Constants.modelsDirectory.appendingPathComponent(model.rawValue)
                if FileManager.default.fileExists(atPath: modelDir.path) {
                    try FileManager.default.removeItem(at: modelDir)
                }

            case .whisperKit:
                for directory in model.whisperCacheDirectories
                where FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }

            case .parakeet:
                guard let parakeetModel = model.parakeetModel else {
                    throw ModelDownloaderError.invalidModel
                }
                // Removes all cached dirs and stops the helper if this model is active.
                try await ParakeetClient.shared.deleteCaches(parakeetModel)
            }

            // Verify the model is actually gone.
            if isModelInstalled(model) {
                throw ModelDownloaderError.deletionIncomplete
            }
        } catch {
            downloadLogger.error("Failed to delete \(model.rawValue): \(error.localizedDescription)")
            DiagnosticLog.shared.event(
                "model.delete_failed",
                level: .error,
                fields: ["model": model.rawValue, "backend": "\(model.backend)"]
                    .merging(DiagnosticLog.shared.errorFields(for: error)) { current, _ in current }
            )
            throw error
        }

        DiagnosticLog.shared.event("model.deleted", fields: [
            "model": model.rawValue,
            "backend": "\(model.backend)"
        ])
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
        case .parakeet:
            try? FileManager.default.createDirectory(at: Constants.fluidAudioCacheDirectory, withIntermediateDirectories: true)
            setenv("XDG_CACHE_HOME", Constants.fluidAudioCacheDirectory.path, 1)
            downloadParakeetModel(model)
        }
    }
    
    /// Cancel current download
    func cancel() {
        currentTask?.cancel()
        whisperDownloadTask?.cancel()
        parakeetDownloadTask?.cancel()
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

    private func downloadParakeetModel(_ model: Model) {
        guard let parakeetModel = model.parakeetModel else {
            error = "Invalid Parakeet variant"
            downloadFailed()
            return
        }

        currentFile = model.displayName
        fileProgress = 0
        overallProgress = 0

        parakeetDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await ParakeetClient.shared.ensureLoaded(parakeetModel) { progress in
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
        case .whisperKit, .parakeet:
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
        parakeetDownloadTask = nil
    }
    
    private func downloadFailed() {
        downloadLogger.error("Download failed: \(self.error ?? "unknown")")
        isDownloading = false
        completionHandler?(false)

        completionHandler = nil
        currentTask = nil
        whisperDownloadTask = nil
        parakeetDownloadTask = nil
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
