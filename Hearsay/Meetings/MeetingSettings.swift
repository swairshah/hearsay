import Foundation

/// User preferences for meeting recording (UserDefaults-backed).
enum MeetingSettings {
    private static let silenceReminderKey = "meetingSilenceReminderMinutes"
    private static let autoStopKey = "meetingAutoStopSilenceMinutes"
    private static let suggestOnCallsKey = "meetingSuggestRecordingOnCalls"
    private static let keepAudioKey = "meetingKeepAudio"
    private static let speakerDetectionKey = "meetingSpeakerDetection"
    private static let suppressEchoKey = "meetingSuppressEcho"
    private static let livePreviewKey = "meetingLivePreview"
    private static let askAfterGoodbyesKey = "meetingAskAfterGoodbyes"

    static let silenceReminderChoices = [0, 2, 3, 5, 10]
    static let autoStopChoices = [0, 10, 15, 30, 60]

    /// Ask "still in a meeting?" after this many silent minutes (0 = never).
    static var silenceReminderMinutes: Int {
        get { integer(silenceReminderKey, default: 3) }
        set { UserDefaults.standard.set(newValue, forKey: silenceReminderKey) }
    }

    /// Stop recording by itself after this many silent minutes (0 = never).
    static var autoStopSilenceMinutes: Int {
        get { integer(autoStopKey, default: 15) }
        set { UserDefaults.standard.set(newValue, forKey: autoStopKey) }
    }

    /// Ask whether to stop when someone says goodbye and the call goes quiet.
    static var askAfterGoodbyes: Bool {
        get { bool(askAfterGoodbyesKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: askAfterGoodbyesKey) }
    }

    /// Offer to record when Zoom, Teams, Meet, … start using the microphone.
    static var suggestRecordingOnCalls: Bool {
        get { bool(suggestOnCallsKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: suggestOnCallsKey) }
    }

    /// Keep the compressed audio tracks next to the transcript.
    static var keepAudio: Bool {
        get { bool(keepAudioKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: keepAudioKey) }
    }

    /// Split the call audio into individual speakers (Apple Silicon).
    static var speakerDetection: Bool {
        get { bool(speakerDetectionKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: speakerDetectionKey) }
    }

    /// Hide mic segments that are just the call playing through your speakers.
    static var suppressEcho: Bool {
        get { bool(suppressEchoKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: suppressEchoKey) }
    }

    /// Show words while someone is still talking (extra transcription work).
    static var livePreview: Bool {
        get { bool(livePreviewKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: livePreviewKey) }
    }

    private static func integer(_ key: String, default value: Int) -> Int {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.integer(forKey: key)
    }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.bool(forKey: key)
    }
}
