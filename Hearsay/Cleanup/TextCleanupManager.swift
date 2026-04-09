import Foundation
import LLM
import os.log

private let logger = Logger(subsystem: "com.swair.hearsay", category: "cleanup")

/// Manages the local LLM for post-transcription text cleanup.
/// Handles model loading, inference with timeout, and lifecycle management.
final class TextCleanupManager {
    
    enum State {
        case idle
        case loading
        case ready
        case error(String)
    }
    
    private(set) var state: State = .idle
    private var llm: LLM?
    
    /// Callback for state changes (called on main thread)
    var onStateChanged: ((State) -> Void)?
    
    private static let timeoutSeconds: TimeInterval = 15.0
    
    // MARK: - Init
    
    init() {}
    
    deinit {
        shutdown()
    }
    
    // MARK: - Public API
    
    /// Whether a model is loaded and ready for inference
    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }
    
    /// Load the cleanup model if it's downloaded
    func loadModel(_ model: CleanupModelDownloader.CleanupModel = .qwen35_0_8b) async {
        // Already loaded
        if llm != nil, case .ready = state { return }
        
        // Already loading
        if case .loading = state { return }
        
        let path = CleanupModelDownloader.shared.modelPath(for: model)
        guard FileManager.default.fileExists(atPath: path.path) else {
            logger.info("Cleanup model not downloaded, skipping load")
            return
        }
        
        setState(.loading)
        logger.info("Loading cleanup model: \(model.rawValue)")
        
        let loadedModel = await Task.detached { () -> LLM? in
            guard let llm = LLM(from: path, maxTokenCount: model.maxTokenCount) else {
                return nil
            }
            llm.useResolvedTemplate(systemPrompt: TextCleaner.defaultPrompt)
            return llm
        }.value
        
        guard let loadedModel else {
            logger.error("Failed to load cleanup model")
            setState(.error("Failed to load cleanup model"))
            return
        }
        
        loadedModel.temp = 0.1
        loadedModel.update = { (_: String?) in }
        loadedModel.postprocess = { (_: String) in }
        
        llm = loadedModel
        setState(.ready)
        logger.info("Cleanup model ready: \(model.displayName)")
    }
    
    /// Run cleanup on transcribed text
    func clean(text: String, prompt: String? = nil) async -> String? {
        guard let llm = llm, isReady else {
            logger.info("Cleanup model not ready, skipping cleanup")
            return nil
        }
        
        let activePrompt = prompt ?? CleanupSettings.prompt
        let formattedInput = TextCleaner.formatInput(text)
        
        llm.useResolvedTemplate(systemPrompt: activePrompt)
        llm.history = []
        
        let start = Date()
        
        do {
            let rawOutput = try await withTimeout(seconds: Self.timeoutSeconds) {
                await llm.respond(to: formattedInput, thinking: .suppressed)
                return llm.output
            }
            
            let elapsed = Date().timeIntervalSince(start)
            logger.info("Cleanup finished in \(String(format: "%.2f", elapsed))s")
            
            let cleaned = TextCleaner.sanitize(rawOutput)
            
            // Discard unusable output
            if cleaned.isEmpty || cleaned == "..." {
                logger.warning("Cleanup produced unusable output, returning original")
                return nil
            }
            
            return cleaned
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            logger.error("Cleanup failed after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Unload the model to free memory
    func unloadModel() {
        llm = nil
        setState(.idle)
        logger.info("Cleanup model unloaded")
    }
    
    /// Shut down the llama backend entirely
    func shutdown() {
        unloadModel()
        LLM.shutdownBackend()
        logger.info("Cleanup backend shut down")
    }
    
    // MARK: - Private
    
    private func setState(_ newState: State) {
        state = newState
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onStateChanged?(self.state)
        }
    }
    
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
