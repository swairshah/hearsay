import Foundation
import os.log

private let historyLogger = Logger(subsystem: "com.swair.hearsay", category: "history")

/// Persists transcription history to disk using chunked files for efficient access.
///
/// Each chunk file holds up to `entriesPerChunk` items. Chunks are numbered with
/// higher numbers being newer. An `index.json` file tracks the chunk order and counts.
final class HistoryStore {
    
    static let shared = HistoryStore()
    
    static let maxItemsKey = "maxHistoryItems"
    static let defaultMaxItems = 1000
    static let entriesPerChunk = 1000
    
    /// Estimated bytes per entry (for UI display)
    static let estimatedBytesPerEntry = 300
    
    // MARK: - Index
    
    struct ChunkMeta: Codable {
        let id: Int
        var count: Int
    }
    
    struct HistoryIndex: Codable {
        var nextChunkId: Int
        var chunks: [ChunkMeta]  // Ordered newest-first
        
        static let empty = HistoryIndex(nextChunkId: 0, chunks: [])
    }
    
    private(set) var index: HistoryIndex = .empty
    
    /// In-memory cache of the newest chunk only (for fast recent access)
    private var newestChunkItems: [TranscriptionItem]?
    
    /// Called when history changes
    var onHistoryChanged: (() -> Void)?
    
    var maxItems: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.maxItemsKey)
        return stored > 0 ? stored : Self.defaultMaxItems
    }
    
    var totalCount: Int {
        index.chunks.reduce(0) { $0 + $1.count }
    }
    
    private var historyDir: URL { Constants.historyDirectory }
    
    private var indexFileURL: URL {
        historyDir.appendingPathComponent("index.json")
    }
    
    private init() {
        ensureDirectoryExists()
        migrateIfNeeded()
        loadIndex()
    }
    
    // MARK: - Public API
    
    func add(_ item: TranscriptionItem) {
        // Load newest chunk into cache if needed
        if newestChunkItems == nil {
            if let newest = index.chunks.first {
                newestChunkItems = loadChunk(id: newest.id)
            } else {
                newestChunkItems = []
            }
        }
        
        newestChunkItems!.insert(item, at: 0)
        
        // Check if the newest chunk is full
        if newestChunkItems!.count > Self.entriesPerChunk {
            // Save current newest chunk (it's now full)
            if let newest = index.chunks.first {
                saveChunk(id: newest.id, items: newestChunkItems!)
                index.chunks[0].count = newestChunkItems!.count
            }
            
            // Start a new chunk for future entries - move overflow to new chunk
            // Actually: keep first entriesPerChunk in a new chunk, rest stays in old
            let newChunkId = index.nextChunkId
            let keepItems = Array(newestChunkItems!.prefix(1))  // Just the new item
            let oldItems = Array(newestChunkItems!.dropFirst(1))
            
            // Save the old chunk with its items
            if let oldIdx = index.chunks.firstIndex(where: { $0.id == index.chunks.first?.id }) {
                saveChunk(id: index.chunks[oldIdx].id, items: oldItems)
                index.chunks[oldIdx].count = oldItems.count
            }
            
            // Create new chunk
            saveChunk(id: newChunkId, items: keepItems)
            index.chunks.insert(ChunkMeta(id: newChunkId, count: keepItems.count), at: 0)
            index.nextChunkId = newChunkId + 1
            newestChunkItems = keepItems
        } else {
            // Update count in index
            if index.chunks.isEmpty {
                let newId = index.nextChunkId
                index.chunks.insert(ChunkMeta(id: newId, count: newestChunkItems!.count), at: 0)
                index.nextChunkId = newId + 1
            } else {
                index.chunks[0].count = newestChunkItems!.count
            }
            
            // Save newest chunk
            saveChunk(id: index.chunks[0].id, items: newestChunkItems!)
        }
        
        // Enforce max items limit
        trimToMax()
        
        saveIndex()
        historyLogger.info("Added transcription: \(item.text.prefix(30))...")
        
        DispatchQueue.main.async {
            self.onHistoryChanged?()
        }
    }
    
    @discardableResult
    func add(text: String, durationSeconds: Double, audioFilePath: String? = nil) -> TranscriptionItem {
        let item = TranscriptionItem(text: text, durationSeconds: durationSeconds, audioFilePath: audioFilePath)
        add(item)
        return item
    }
    
    /// Get the most recent N items (reads only what's needed).
    func getRecent(_ count: Int = 10) -> [TranscriptionItem] {
        return getItems(offset: 0, limit: count)
    }
    
    /// Paginated access: get `limit` items starting at `offset`.
    func getItems(offset: Int, limit: Int) -> [TranscriptionItem] {
        var result: [TranscriptionItem] = []
        var remaining = limit
        var skipped = 0
        
        for chunkMeta in index.chunks {
            // Skip chunks entirely if offset hasn't been reached
            if skipped + chunkMeta.count <= offset {
                skipped += chunkMeta.count
                continue
            }
            
            let items = loadChunk(id: chunkMeta.id)
            let startInChunk = max(0, offset - skipped)
            let available = items.count - startInChunk
            let take = min(remaining, available)
            
            if take > 0 {
                result.append(contentsOf: items[startInChunk..<(startInChunk + take)])
                remaining -= take
            }
            
            skipped += chunkMeta.count
            
            if remaining <= 0 { break }
        }
        
        return result
    }
    
    /// Get all items (loads all chunks). Use sparingly.
    func getAll() -> [TranscriptionItem] {
        return getItems(offset: 0, limit: totalCount)
    }
    
    func clear() {
        // Delete all chunk files
        for chunk in index.chunks {
            try? FileManager.default.removeItem(at: chunkFileURL(id: chunk.id))
        }
        index = HistoryIndex(nextChunkId: 0, chunks: [])
        newestChunkItems = nil
        saveIndex()
        historyLogger.info("History cleared")
        
        DispatchQueue.main.async {
            self.onHistoryChanged?()
        }
    }
    
    func delete(_ item: TranscriptionItem) {
        for (chunkIdx, chunkMeta) in index.chunks.enumerated() {
            var items = loadChunk(id: chunkMeta.id)
            if let itemIdx = items.firstIndex(where: { $0.id == item.id }) {
                items.remove(at: itemIdx)
                if items.isEmpty {
                    // Remove empty chunk
                    try? FileManager.default.removeItem(at: chunkFileURL(id: chunkMeta.id))
                    index.chunks.remove(at: chunkIdx)
                    if chunkIdx == 0 { newestChunkItems = nil }
                } else {
                    saveChunk(id: chunkMeta.id, items: items)
                    index.chunks[chunkIdx].count = items.count
                    if chunkIdx == 0 { newestChunkItems = items }
                }
                saveIndex()
                
                DispatchQueue.main.async {
                    self.onHistoryChanged?()
                }
                return
            }
        }
    }
    
    func delete(at globalIndex: Int) {
        let items = getItems(offset: globalIndex, limit: 1)
        if let item = items.first {
            delete(item)
        }
    }
    
    // MARK: - Chunk I/O
    
    private func chunkFileURL(id: Int) -> URL {
        historyDir.appendingPathComponent("chunk_\(String(format: "%04d", id)).json")
    }
    
    private func loadChunk(id: Int) -> [TranscriptionItem] {
        // Use cache for newest chunk
        if let first = index.chunks.first, first.id == id, let cached = newestChunkItems {
            return cached
        }
        
        let url = chunkFileURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([TranscriptionItem].self, from: data)
        } catch {
            historyLogger.error("Failed to load chunk \(id): \(error.localizedDescription)")
            return []
        }
    }
    
    private func saveChunk(id: Int, items: [TranscriptionItem]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(items)
            try data.write(to: chunkFileURL(id: id))
        } catch {
            historyLogger.error("Failed to save chunk \(id): \(error.localizedDescription)")
        }
    }
    
    // MARK: - Index I/O
    
    private func loadIndex() {
        guard FileManager.default.fileExists(atPath: indexFileURL.path) else {
            historyLogger.info("No history index found")
            return
        }
        
        do {
            let data = try Data(contentsOf: indexFileURL)
            index = try JSONDecoder().decode(HistoryIndex.self, from: data)
            historyLogger.info("Loaded history index: \(self.totalCount) items in \(self.index.chunks.count) chunks")
        } catch {
            historyLogger.error("Failed to load history index: \(error.localizedDescription)")
        }
    }
    
    private func saveIndex() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(index)
            try data.write(to: indexFileURL)
        } catch {
            historyLogger.error("Failed to save history index: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Trimming
    
    private func trimToMax() {
        let max = maxItems
        guard totalCount > max else { return }
        
        // Remove oldest chunks until within limit
        while index.chunks.count > 1 && totalCount > max {
            let oldest = index.chunks.removeLast()
            try? FileManager.default.removeItem(at: chunkFileURL(id: oldest.id))
            historyLogger.info("Removed old chunk \(oldest.id) (\(oldest.count) items)")
        }
        
        // If still over limit, trim the oldest remaining chunk
        if totalCount > max, let lastIdx = index.chunks.indices.last {
            var items = loadChunk(id: index.chunks[lastIdx].id)
            let excess = totalCount - max
            if excess < items.count {
                items = Array(items.dropLast(excess))
                saveChunk(id: index.chunks[lastIdx].id, items: items)
                index.chunks[lastIdx].count = items.count
            }
        }
    }
    
    // MARK: - Migration
    
    /// Migrate from old single-file history.json to chunked format.
    private func migrateIfNeeded() {
        let oldFile = historyDir.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: oldFile.path) else { return }
        
        // Don't migrate if index already exists
        guard !FileManager.default.fileExists(atPath: indexFileURL.path) else {
            // Old file exists alongside new format — clean it up
            try? FileManager.default.removeItem(at: oldFile)
            return
        }
        
        historyLogger.info("Migrating from single-file history to chunked format...")
        
        do {
            let data = try Data(contentsOf: oldFile)
            let allItems = try JSONDecoder().decode([TranscriptionItem].self, from: data)
            
            // Split into chunks (items are already newest-first)
            var chunkId = 0
            var chunks: [ChunkMeta] = []
            
            for chunkStart in stride(from: 0, to: allItems.count, by: Self.entriesPerChunk) {
                let end = min(chunkStart + Self.entriesPerChunk, allItems.count)
                let chunkItems = Array(allItems[chunkStart..<end])
                saveChunk(id: chunkId, items: chunkItems)
                chunks.append(ChunkMeta(id: chunkId, count: chunkItems.count))
                chunkId += 1
            }
            
            index = HistoryIndex(nextChunkId: chunkId, chunks: chunks)
            saveIndex()
            
            // Remove old file
            try FileManager.default.removeItem(at: oldFile)
            historyLogger.info("Migration complete: \(allItems.count) items in \(chunks.count) chunks")
        } catch {
            historyLogger.error("Migration failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Helpers
    
    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: Constants.historyDirectory,
            withIntermediateDirectories: true
        )
    }
}
