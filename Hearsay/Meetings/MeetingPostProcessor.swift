import Foundation
import os.log

private let postLogger = Logger(subsystem: "com.swair.hearsay", category: "meeting-post")

/// Runs clean-up passes over a saved meeting transcript.
///
/// Passes rewrite `MeetingSegment.text` and never touch `originalText`, so any
/// pass can be undone (one level) or reverted to what the speech model heard.
/// Segments the user edited by hand are left alone.
final class MeetingPostProcessor {

    static let shared = MeetingPostProcessor()

    /// The app's local LLM (owned by AppDelegate).
    var cleanupManagerProvider: (() -> TextCleanupManager?)?

    enum Pass {
        /// Filler-word rules and text replacements from the Cleanup / Replacements panes.
        case cleanup
        /// Local LLM, one utterance at a time.
        case llm(prompt: String)

        var kind: MeetingProcessingPass.Kind {
            switch self {
            case .cleanup: return .cleanup
            case .llm: return .llm
            }
        }
    }

    enum PostProcessError: LocalizedError {
        case busy
        case meetingNotFound
        case modelUnavailable

        var errorDescription: String? {
            switch self {
            case .busy: return "Another clean-up pass is already running"
            case .meetingNotFound: return "The meeting could not be found"
            case .modelUnavailable: return "Download a post-processing model in Post Processing first"
            }
        }
    }

    private(set) var runningMeetingID: UUID?
    private var cancelRequested = false
    /// Per meeting: segment text before the last pass and what the pass wrote.
    private struct UndoSnapshot {
        var before: [UUID: (text: String, edited: Bool?)]
        var after: [UUID: String]
    }
    private var undoSnapshots: [UUID: UndoSnapshot] = [:]

    static let llmPromptKey = "meetingLLMPrompt"

    static let defaultLLMPrompt = """
    You clean up one utterance from a meeting transcript produced by speech recognition.

    Rules:
    1. Keep every sentence, the speaker's meaning, and their wording.
    2. Remove filler words (um, uh, you know, "like" used as filler), stutters and false starts.
    3. Fix punctuation and capitalization.
    4. Fix obvious misrecognitions of names, products and technical terms when the context makes the intended word clear.
    5. Do not summarize, answer questions, or add anything.

    Output only the cleaned utterance.
    """

    static var llmPrompt: String {
        get {
            let stored = UserDefaults.standard.string(forKey: llmPromptKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (stored?.isEmpty == false) ? stored! : defaultLLMPrompt
        }
        set { UserDefaults.standard.set(newValue, forKey: llmPromptKey) }
    }

    var isLLMAvailable: Bool {
        CleanupModelDownloader.shared.isModelInstalled() && cleanupManagerProvider?() != nil
    }

    func canUndo(_ meetingID: UUID) -> Bool {
        undoSnapshots[meetingID] != nil
    }

    func cancel() {
        cancelRequested = true
    }

    /// Run `pass` over the meeting. `progress(done, total)` and `completion`
    /// (number of segments changed) are called on the main queue.
    func run(
        _ pass: Pass,
        on meetingID: UUID,
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        guard runningMeetingID == nil else {
            completion(.failure(PostProcessError.busy))
            return
        }
        guard let document = MeetingStore.shared.document(id: meetingID) else {
            completion(.failure(PostProcessError.meetingNotFound))
            return
        }

        runningMeetingID = meetingID
        cancelRequested = false
        let snapshot = document.segments
        let targets = document.segments.indices.filter {
            document.segments[$0].suppressed != true && document.segments[$0].edited != true
        }

        Task { @MainActor in
            defer { self.runningMeetingID = nil }
            var changed = 0

            switch pass {
            case .cleanup:
                MeetingStore.shared.modify(id: meetingID) { doc in
                    for index in targets where index < doc.segments.count {
                        let updated = TranscriptProcessor.process(doc.segments[index].text)
                        if updated != doc.segments[index].text, !updated.isEmpty {
                            doc.segments[index].text = updated
                            changed += 1
                        }
                    }
                }
                progress(targets.count, targets.count)

            case .llm(let prompt):
                guard let manager = self.cleanupManagerProvider?(), CleanupModelDownloader.shared.isModelInstalled() else {
                    completion(.failure(PostProcessError.modelUnavailable))
                    return
                }
                if !manager.isReady {
                    await manager.loadModel()
                }
                guard manager.isReady else {
                    completion(.failure(PostProcessError.modelUnavailable))
                    return
                }

                var done = 0
                for index in targets {
                    if self.cancelRequested { break }
                    let segmentID = snapshot[index].id
                    let text = snapshot[index].text
                    done += 1
                    // One- and two-word replies rarely need an LLM.
                    guard text.split(whereSeparator: \.isWhitespace).count >= 3 else {
                        progress(done, targets.count)
                        continue
                    }
                    if let cleaned = await manager.clean(text: text, prompt: prompt), cleaned != text {
                        MeetingStore.shared.modify(id: meetingID) { doc in
                            if let position = doc.segments.firstIndex(where: { $0.id == segmentID }),
                               doc.segments[position].edited != true {
                                doc.segments[position].text = cleaned
                            }
                        }
                        changed += 1
                    }
                    progress(done, targets.count)
                }
            }

            if changed > 0 {
                let after = MeetingStore.shared.document(id: meetingID)?.segments ?? []
                self.undoSnapshots[meetingID] = Self.makeUndo(before: snapshot, after: after)
                MeetingStore.shared.modify(id: meetingID) { doc in
                    var passes = doc.processingPasses ?? []
                    passes.append(MeetingProcessingPass(kind: pass.kind, date: Date(), changedSegments: changed))
                    doc.processingPasses = passes
                }
            }
            postLogger.notice("Meeting pass \(String(describing: pass.kind), privacy: .public) changed \(changed) segments")
            completion(.success(changed))
        }
    }

    /// Restore the transcript as it was before the last pass. Lines the user
    /// changed since the pass (and speaker changes) are kept.
    func undoLastPass(_ meetingID: UUID) {
        guard let snapshot = undoSnapshots.removeValue(forKey: meetingID) else { return }
        MeetingStore.shared.modify(id: meetingID) { doc in
            for index in doc.segments.indices {
                let id = doc.segments[index].id
                guard let before = snapshot.before[id], snapshot.after[id] == doc.segments[index].text else { continue }
                doc.segments[index].text = before.text
                doc.segments[index].edited = before.edited
            }
        }
    }

    private static func makeUndo(before: [MeetingSegment], after: [MeetingSegment]) -> UndoSnapshot {
        let afterTexts = Dictionary(after.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var snapshot = UndoSnapshot(before: [:], after: [:])
        for segment in before where afterTexts[segment.id] != nil && afterTexts[segment.id] != segment.text {
            snapshot.before[segment.id] = (segment.text, segment.edited)
            snapshot.after[segment.id] = afterTexts[segment.id]
        }
        return snapshot
    }

    /// Put every segment back to exactly what the speech model produced.
    func revertToOriginal(_ meetingID: UUID) {
        guard let document = MeetingStore.shared.document(id: meetingID) else { return }
        MeetingStore.shared.modify(id: meetingID) { doc in
            for index in doc.segments.indices {
                doc.segments[index].text = doc.segments[index].originalText
                doc.segments[index].edited = nil
            }
            var passes = doc.processingPasses ?? []
            passes.append(MeetingProcessingPass(kind: .revert, date: Date(), changedSegments: doc.segments.count))
            doc.processingPasses = passes
        }
        if let reverted = MeetingStore.shared.document(id: meetingID) {
            undoSnapshots[meetingID] = Self.makeUndo(before: document.segments, after: reverted.segments)
        }
    }
}
