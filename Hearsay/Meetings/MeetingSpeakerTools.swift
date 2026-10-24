import Foundation
import os.log

private let speakerToolsLogger = Logger(subsystem: "com.swair.hearsay", category: "meeting-speakers")

extension Notification.Name {
    /// Posted on main when speaker refinement starts or ends; `object` is the meeting's UUID.
    static let meetingSpeakerRefinementChanged = Notification.Name("meetingSpeakerRefinementChanged")
}

/// Speaker operations on saved meetings.
enum MeetingSpeakerTools {

    enum ToolError: LocalizedError {
        case noCallAudio
        case meetingNotFound
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .noCallAudio: return "This meeting has no saved call audio to analyse."
            case .meetingNotFound: return "The meeting could not be found."
            case .alreadyRunning: return "Wait for the current speaker detection or clean-up pass to finish."
            }
        }
    }

    /// Meetings whose speakers are being refined right now (main thread).
    private(set) static var refining = Set<UUID>()

    static func isRefining(_ meetingID: UUID) -> Bool { refining.contains(meetingID) }

    /// Detect speakers over the whole saved call track and relabel the call
    /// lines, splitting a line where the speaker changes mid-way. Runs after
    /// every recording and from "Re-detect Speakers". Lines assigned by hand
    /// keep their speaker. Completion runs on main.
    /// `audioURL` overrides the saved call track (the recorder passes the
    /// uncompressed track when audio isn't being kept).
    static func refineSpeakers(
        meetingID: UUID,
        audioURL: URL? = nil,
        completion: ((Result<MeetingSpeakerRefinement.Outcome, Error>) -> Void)? = nil
    ) {
        guard !refining.contains(meetingID), MeetingPostProcessor.shared.runningMeetingID != meetingID else {
            completion?(.failure(ToolError.alreadyRunning))
            return
        }
        guard let document = MeetingStore.shared.document(id: meetingID) else {
            completion?(.failure(ToolError.meetingNotFound))
            return
        }
        guard let audioURL = audioURL ?? document.audio?.system.map({
            MeetingPaths.directory(for: meetingID).appendingPathComponent($0)
        }) else {
            completion?(.failure(ToolError.noCallAudio))
            return
        }
        let targets = document.segments.filter { $0.channel == .system && $0.manualSpeaker != true }
        let wordModel = installedParakeetModel()

        setRefining(meetingID, true)
        let started = Date()
        Task {
            let diarizer = MeetingDiarizer()
            do {
                let result = try await diarizer.refine(
                    audioURL: audioURL,
                    ranges: targets.map { $0.start...$0.end },
                    wordModel: wordModel
                )
                await diarizer.shutdown()

                await MainActor.run {
                    var words: [UUID: [MeetingSpeakerRefinement.Word]] = [:]
                    if let perSegment = result.words {
                        for (segment, list) in zip(targets, perSegment) { words[segment.id] = list }
                    }
                    var outcome = MeetingSpeakerRefinement.Outcome()
                    // Applied to the latest copy: the user may have edited or
                    // picked speakers while this ran.
                    MeetingStore.shared.modify(id: meetingID) { doc in
                        outcome = MeetingSpeakerRefinement.apply(to: &doc, turns: result.turns, words: words)
                    }
                    speakerToolsLogger.notice("Refined speakers for \(meetingID.uuidString.prefix(8), privacy: .public): \(outcome.speakers) speakers, \(outcome.splitLines) lines split, \(outcome.relabelledLines) relabelled in \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public)s (words: \(wordModel != nil))")
                    setRefining(meetingID, false)
                    completion?(.success(outcome))
                }
            } catch {
                await diarizer.shutdown()
                speakerToolsLogger.error("Speaker refinement failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    setRefining(meetingID, false)
                    completion?(.failure(error))
                }
            }
        }
    }

    private static func setRefining(_ meetingID: UUID, _ active: Bool) {
        if active { refining.insert(meetingID) } else { refining.remove(meetingID) }
        NotificationCenter.default.post(name: .meetingSpeakerRefinementChanged, object: meetingID)
    }

    /// Word timings come from Parakeet whichever speech model is active; without
    /// an installed Parakeet model, lines are relabelled but not split.
    private static func installedParakeetModel() -> String? {
        let downloader = ModelDownloader.shared
        let candidates: [ModelDownloader.Model] = [.parakeetMultilingualV3, .parakeetEnglishV2]
        return candidates.first { downloader.isModelInstalled($0) }?.rawValue
    }
}
