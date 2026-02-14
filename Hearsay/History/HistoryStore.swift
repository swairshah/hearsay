import Foundation
import os.log

private let historyLogger = Logger(subsystem: "com.swair.hearsay", category: "history")

/// Persists transcription history to disk.
final class HistoryStore {
    
    static let shared = HistoryStore()
    
    private let maxItems = 100
    private(set) var items: [TranscriptionItem] = []
    
    /// Called when history changes
    var onHistoryChanged: (() -> Void)?
    
    private var historyFileURL: URL {
        Constants.historyDirectory.appendingPathComponent("history.json")
    }
    
    private init() {
        ensureDirectoryExists()
        load()
    }
    
    // MARK: - Public
    
    func add(_ item: TranscriptionItem) {
        items.insert(item, at: 0)
        
        // Trim to max size
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
        
        save()
        historyLogger.info("Added transcription: \(item.text.prefix(30))...")
        
        DispatchQueue.main.async {
            self.onHistoryChanged?()
        }
    }
    
    @discardableResult
    func add(text: String, durationSeconds: Double) -> TranscriptionItem {
        let item = TranscriptionItem(text: text, durationSeconds: durationSeconds)
        add(item)
        return item
    }
    
    func getAll() -> [TranscriptionItem] {
        items
    }
    
    func getRecent(_ count: Int = 10) -> [TranscriptionItem] {
        Array(items.prefix(count))
    }
    
    func clear() {
        items.removeAll()
        save()
        historyLogger.info("History cleared")
        
        DispatchQueue.main.async {
            self.onHistoryChanged?()
        }
    }
    
    func delete(_ item: TranscriptionItem) {
        items.removeAll { $0.id == item.id }
        save()
        
        DispatchQueue.main.async {
            self.onHistoryChanged?()
        }
    }
    
    func delete(at index: Int) {
        guard index >= 0 && index < items.count else { return }
        items.remove(at: index)
        save()
        
        DispatchQueue.main.async {
            self.onHistoryChanged?()
        }
    }
    
    // MARK: - Persistence
    
    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: Constants.historyDirectory,
            withIntermediateDirectories: true
        )
    }
    
    private func load() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else { 
            historyLogger.info("No history file found")
            return 
        }
        
        do {
            let data = try Data(contentsOf: historyFileURL)
            items = try JSONDecoder().decode([TranscriptionItem].self, from: data)
            historyLogger.info("Loaded \(self.items.count) history items")
        } catch {
            historyLogger.error("Failed to load history: \(error.localizedDescription)")
        }
    }
    
    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(items)
            try data.write(to: historyFileURL)
        } catch {
            historyLogger.error("Failed to save history: \(error.localizedDescription)")
        }
    }
}
