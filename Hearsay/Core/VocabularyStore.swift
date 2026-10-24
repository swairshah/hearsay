import Foundation
import os.log

private let vocabularyLogger = Logger(subsystem: "com.swair.hearsay", category: "vocabulary")

extension Notification.Name {
    /// Posted on the main queue when the vocabulary changes (in the app or on disk).
    static let vocabularyChanged = Notification.Name("HearsayVocabularyChanged")
}

/// The app's view of `vocabulary.json`. Thread-safe; re-reads the file when its
/// modification date changes, so `hearsay vocab` edits apply to the next
/// transcription without a restart.
final class VocabularyStore: @unchecked Sendable {

    static let shared = VocabularyStore()

    private let lock = NSLock()
    private var cached = Vocabulary()
    private var cachedModificationDate: Date?
    private var watcher: DispatchSourceFileSystemObject?

    private init() {}

    var current: Vocabulary {
        lock.withLock {
            reloadIfChangedLocked()
            return cached
        }
    }

    func save(_ vocabulary: Vocabulary) throws {
        try lock.withLock {
            try vocabulary.save()
            cached = vocabulary
            cachedModificationDate = Self.modificationDate()
        }
        postChanged()
    }

    func applyAliases(to text: String) -> String {
        current.applyAliases(to: text)
    }

    /// Watch the Hearsay folder so open UI refreshes after CLI edits.
    func startWatching() {
        guard watcher == nil else { return }
        let directory = Vocabulary.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let changed = self.lock.withLock { self.reloadIfChangedLocked() }
            if changed { self.postChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    /// Returns true when a different file was loaded.
    @discardableResult
    private func reloadIfChangedLocked() -> Bool {
        let date = Self.modificationDate()
        guard date != cachedModificationDate else { return false }
        cachedModificationDate = date
        do {
            cached = try Vocabulary.load()
        } catch {
            // Keep the last good copy; a half-written or hand-broken file shouldn't wipe it.
            vocabularyLogger.error("Failed to read vocabulary: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    private static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Vocabulary.fileURL.path))?[.modificationDate] as? Date
    }

    private func postChanged() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .vocabularyChanged, object: nil)
        } else {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .vocabularyChanged, object: nil) }
        }
    }
}
