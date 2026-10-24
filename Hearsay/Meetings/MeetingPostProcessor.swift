import Foundation
import os.log

private let postLogger = Logger(subsystem: "com.swair.hearsay", category: "meeting-post")

/// Runs the clean-up pass over a saved meeting transcript.
///
/// The pass rewrites `MeetingSegment.text` and never touches `originalText`, so
/// the transcript can always be restored to what the speech model heard.
/// Segments the user edited by hand are left alone.
final class MeetingPostProcessor {

    static let shared = MeetingPostProcessor()

    enum Pass {
        /// Filler-word rules and text replacements from the Cleanup / Replacements panes.
        case cleanup

        var kind: MeetingProcessingPass.Kind {
            switch self {
            case .cleanup: return .cleanup
            }
        }
    }

    enum PostProcessError: LocalizedError {
        case busy
        case meetingNotFound

        var errorDescription: String? {
            switch self {
            case .busy: return "Wait for the current clean-up pass or speaker detection to finish"
            case .meetingNotFound: return "The meeting could not be found"
            }
        }
    }

    private(set) var runningMeetingID: UUID?

    /// Run `pass` over the meeting. `progress(done, total)` and `completion`
    /// (number of segments changed) are called on the main queue.
    func run(
        _ pass: Pass,
        on meetingID: UUID,
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        // Speaker detection may split lines underneath a pass.
        guard runningMeetingID == nil, !MeetingSpeakerTools.isRefining(meetingID) else {
            completion(.failure(PostProcessError.busy))
            return
        }
        guard let document = MeetingStore.shared.document(id: meetingID) else {
            completion(.failure(PostProcessError.meetingNotFound))
            return
        }

        runningMeetingID = meetingID
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
            }

            if changed > 0 {
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

    /// Put every segment back to exactly what the speech model produced.
    func revertToOriginal(_ meetingID: UUID) {
        MeetingStore.shared.modify(id: meetingID) { doc in
            for index in doc.segments.indices {
                doc.segments[index].text = doc.segments[index].originalText
                doc.segments[index].edited = nil
            }
            var passes = doc.processingPasses ?? []
            passes.append(MeetingProcessingPass(kind: .revert, date: Date(), changedSegments: doc.segments.count))
            doc.processingPasses = passes
        }
    }
}
