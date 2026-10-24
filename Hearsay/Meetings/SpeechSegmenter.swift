import Foundation

/// Splits one meeting track (16 kHz mono) into utterances using frame energy
/// against an adaptive noise floor. Cheap enough to run on every buffer, and
/// good enough here because each track carries mostly one source: the mic is
/// you, the system tap is the call.
///
/// Not thread-safe; owned by the meeting's processing queue.
final class SpeechSegmenter {

    struct Config {
        /// 30 ms at 16 kHz.
        var frameLength = 480
        /// RMS below this is never speech, however quiet the room is.
        var absoluteThreshold: Float
        /// Speech must be this many times louder than the running noise floor.
        var noiseMultiplier: Float = 3.0
        /// Consecutive loud frames needed to open an utterance (~90 ms).
        var startFrames = 3
        /// Audio kept from before the onset so first syllables aren't clipped (~300 ms).
        var preRollFrames = 10
        /// Quiet frames that close an utterance (~720 ms).
        var endSilenceFrames = 24
        /// Past ~12 s, close on a short breath instead, to keep the transcript moving.
        var softMaxFrames = 400
        var softEndSilenceFrames = 8
        /// Never let an utterance grow past ~25 s.
        var hardMaxFrames = 833
        /// Utterances with less than ~240 ms of actual speech are dropped as noise.
        var minSpeechFrames = 8

        static let microphone = Config(absoluteThreshold: 0.006)
        static let system = Config(absoluteThreshold: 0.003)
    }

    struct Segment {
        /// Increments per utterance; lets partial results be matched to finals.
        let ordinal: Int
        /// Position of the first sample on the track timeline.
        let startSample: Int
        let samples: [Float]

        var endSample: Int { startSample + samples.count }
        var startTime: TimeInterval { TimeInterval(startSample) / MeetingAudioIO.sampleRate }
        var endTime: TimeInterval { TimeInterval(endSample) / MeetingAudioIO.sampleRate }
        var duration: TimeInterval { TimeInterval(samples.count) / MeetingAudioIO.sampleRate }
    }

    let config: Config

    /// Samples consumed so far (the track's timeline position).
    private(set) var consumedSamples = 0
    /// Track position of the most recent speech frame, or nil before any speech.
    private(set) var lastSpeechSample: Int?
    /// RMS of the latest frame, for level meters.
    private(set) var level: Float = 0
    var isInUtterance: Bool { current != nil }

    private var partialFrame: [Float] = []
    private var preRoll: [[Float]] = []
    private var candidateRun = 0
    private var noiseFloor: Float = 0.002
    private var nextOrdinal = 0

    private var current: [Float]?
    private var currentStart = 0
    private var currentOrdinal = 0
    private var currentFrames = 0
    private var speechFrames = 0
    private var silenceRun = 0

    init(config: Config) {
        self.config = config
        partialFrame.reserveCapacity(config.frameLength)
    }

    /// Feed audio; returns any utterances that closed.
    func append(_ samples: [Float]) -> [Segment] {
        var closed: [Segment] = []
        var index = 0
        while index < samples.count {
            let take = min(config.frameLength - partialFrame.count, samples.count - index)
            partialFrame.append(contentsOf: samples[index..<(index + take)])
            index += take
            if partialFrame.count == config.frameLength {
                if let segment = processFrame(partialFrame) {
                    closed.append(segment)
                }
                partialFrame.removeAll(keepingCapacity: true)
            }
        }
        return closed
    }

    /// Close whatever is open (end of recording).
    func flush() -> Segment? {
        guard current != nil else { return nil }
        return closeCurrent(trimTrailingFrames: 0)
    }

    /// Snapshot of the open utterance, for interim ("partial") transcription.
    func openUtterance() -> Segment? {
        guard let current else { return nil }
        return Segment(ordinal: currentOrdinal, startSample: currentStart, samples: current)
    }

    // MARK: - Frames

    private func processFrame(_ frame: [Float]) -> Segment? {
        let rms = Self.rms(frame)
        level = rms
        consumedSamples += frame.count

        let threshold = max(config.absoluteThreshold, noiseFloor * config.noiseMultiplier)
        let isSpeech = rms > threshold
        if isSpeech {
            lastSpeechSample = consumedSamples
        } else {
            // Track the room/line noise from quiet frames only.
            noiseFloor = min(0.05, max(0.0003, noiseFloor * 0.97 + rms * 0.03))
        }

        if current != nil {
            return continueUtterance(with: frame, isSpeech: isSpeech)
        }

        preRoll.append(frame)
        if preRoll.count > config.preRollFrames {
            preRoll.removeFirst(preRoll.count - config.preRollFrames)
        }
        candidateRun = isSpeech ? candidateRun + 1 : 0
        if candidateRun >= config.startFrames {
            openUtterance(speechFrames: candidateRun)
        }
        return nil
    }

    private func openUtterance(speechFrames initialSpeech: Int) {
        let audio = preRoll.flatMap { $0 }
        current = audio
        currentStart = consumedSamples - audio.count
        currentOrdinal = nextOrdinal
        nextOrdinal += 1
        currentFrames = preRoll.count
        speechFrames = initialSpeech
        silenceRun = 0
        candidateRun = 0
        preRoll.removeAll()
    }

    private func continueUtterance(with frame: [Float], isSpeech: Bool) -> Segment? {
        current?.append(contentsOf: frame)
        currentFrames += 1
        if isSpeech {
            speechFrames += 1
            silenceRun = 0
        } else {
            silenceRun += 1
        }

        if silenceRun >= config.endSilenceFrames {
            // Keep ~300 ms of the tail; drop the rest of the silence.
            return closeCurrent(trimTrailingFrames: max(0, silenceRun - 10))
        }
        if currentFrames >= config.softMaxFrames, silenceRun >= config.softEndSilenceFrames {
            return closeCurrent(trimTrailingFrames: max(0, silenceRun - 4))
        }
        if currentFrames >= config.hardMaxFrames {
            return closeCurrent(trimTrailingFrames: 0)
        }
        return nil
    }

    private func closeCurrent(trimTrailingFrames: Int) -> Segment? {
        guard var audio = current else { return nil }
        let trim = min(audio.count, trimTrailingFrames * config.frameLength)
        audio.removeLast(trim)

        let segment = Segment(ordinal: currentOrdinal, startSample: currentStart, samples: audio)
        let hadEnoughSpeech = speechFrames >= config.minSpeechFrames

        current = nil
        currentFrames = 0
        speechFrames = 0
        silenceRun = 0
        return hadEnoughSpeech && !audio.isEmpty ? segment : nil
    }

    static func rms(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in frame {
            sum += sample * sample
        }
        return (sum / Float(frame.count)).squareRoot()
    }
}
