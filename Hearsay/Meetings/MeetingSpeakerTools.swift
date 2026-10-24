import Foundation

/// Speaker operations on saved meetings.
enum MeetingSpeakerTools {

    enum ToolError: LocalizedError {
        case noCallAudio
        case meetingNotFound

        var errorDescription: String? {
            switch self {
            case .noCallAudio: return "This meeting has no saved call audio to analyse."
            case .meetingNotFound: return "The meeting could not be found."
            }
        }
    }

    /// Diarize the saved system track from scratch and relabel every call
    /// segment that wasn't assigned by hand. Diarized speakers go back to
    /// "Speaker N" because slot numbers can change between runs.
    /// Completion runs on main with the number of call speakers found.
    static func redetectSpeakers(meetingID: UUID, completion: @escaping (Result<Int, Error>) -> Void) {
        guard let document = MeetingStore.shared.document(id: meetingID) else {
            completion(.failure(ToolError.meetingNotFound))
            return
        }
        guard let systemFile = document.audio?.system else {
            completion(.failure(ToolError.noCallAudio))
            return
        }
        let audioURL = MeetingPaths.directory(for: meetingID).appendingPathComponent(systemFile)
        let targets = document.segments
            .filter { $0.channel == .system && $0.manualSpeaker != true }
            .map { ($0.id, $0.start...$0.end) }

        Task {
            let diarizer = MeetingDiarizer()
            do {
                try await diarizer.diarizeFile(audioURL)
                let slots = await diarizer.assign(targets.map(\.1))
                await diarizer.shutdown()

                await MainActor.run {
                    var found = Set<Int>()
                    MeetingStore.shared.modify(id: meetingID) { doc in
                        // Reset diarizer slots ("s1"…), except ones that lines
                        // assigned by hand still point at.
                        let handPicked = Set(doc.segments.filter { $0.manualSpeaker == true }.map(\.speakerID))
                        doc.speakers.removeAll {
                            $0.kind == .remote && $0.id.hasPrefix("s") && Int($0.id.dropFirst()) != nil && !handPicked.contains($0.id)
                        }
                        for ((segmentID, _), slot) in zip(targets, slots) {
                            // Re-check: the user may have picked a speaker while this ran.
                            guard let index = doc.segments.firstIndex(where: { $0.id == segmentID }),
                                  doc.segments[index].manualSpeaker != true else { continue }
                            if let slot {
                                found.insert(slot)
                                let speakerID = MeetingSpeaker.remoteID(forSlot: slot)
                                if doc.speaker(id: speakerID) == nil {
                                    doc.speakers.append(MeetingSpeaker.remote(slot: slot))
                                }
                                doc.segments[index].speakerID = speakerID
                            } else {
                                doc.segments[index].speakerID = MeetingSpeaker.themID
                            }
                        }
                    }
                    completion(.success(found.count))
                }
            } catch {
                await diarizer.shutdown()
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }
}
