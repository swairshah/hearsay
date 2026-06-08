import AppKit
import os.log

private let clipboardLogger = Logger(subsystem: "com.swair.hearsay", category: "clipboard")

/// Represents text copied to the clipboard during a recording, with its timestamp
/// relative to recording start. Woven into the transcript at the point it was copied.
struct CapturedClip {
    let text: String
    let timestamp: TimeInterval  // Seconds since recording started
}

/// Watches the system clipboard during a recording session and captures any text
/// the user copies (Cmd+C), so it can be interleaved into the transcript at the
/// position it occurred — mirroring how `ScreenshotManager` handles screenshots.
///
/// There is no public "pasteboard changed" notification on macOS, so we poll
/// `NSPasteboard.changeCount` — a cheap integer read that does NOT touch the
/// clipboard data. We only read the (heavier) string contents when the count
/// actually changes, i.e. only when the user really copied something. The poll
/// timer runs ONLY while recording, so there is zero cost when idle.
final class ClipboardManager {

    static let shared = ClipboardManager()

    /// Text copied during the current recording session, with timestamps.
    private(set) var currentSessionClips: [CapturedClip] = []

    /// When the current recording session started.
    private var sessionStartTime: Date?

    /// `changeCount` baseline so we only capture copies made after recording started.
    private var lastChangeCount: Int = 0

    private var pollTimer: Timer?

    /// How often to check the clipboard for changes while recording.
    private let pollInterval: TimeInterval = 0.25

    /// Fired on the main thread each time a copy is captured, with the new clip count.
    var onClipCaptured: ((Int) -> Void)?

    private init() {}

    // MARK: - Session Management

    /// Start watching the clipboard. Clears previous clips and snapshots the current
    /// `changeCount` so pre-existing clipboard contents are not captured.
    func startSession() {
        currentSessionClips.removeAll()
        sessionStartTime = Date()
        lastChangeCount = NSPasteboard.general.changeCount

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        clipboardLogger.info("Clipboard session started (baseline changeCount=\(self.lastChangeCount))")
    }

    /// Stop watching and return the clips captured during the session.
    func endSession() -> [CapturedClip] {
        pollTimer?.invalidate()
        pollTimer = nil
        let clips = currentSessionClips
        sessionStartTime = nil
        clipboardLogger.info("Clipboard session ended with \(clips.count) clip(s)")
        return clips
    }

    /// Number of clips captured in the current session.
    var clipCount: Int {
        currentSessionClips.count
    }

    // MARK: - Polling

    private func poll() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        // Only string copies are captured; ignore images/files/etc.
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clipboardLogger.info("Clipboard changed but held no usable text; ignoring")
            return
        }

        let timestamp: TimeInterval
        if let startTime = sessionStartTime {
            timestamp = Date().timeIntervalSince(startTime)
        } else {
            timestamp = 0
        }

        currentSessionClips.append(CapturedClip(text: text, timestamp: timestamp))
        let count = currentSessionClips.count
        clipboardLogger.info("Captured clip #\(count) (\(text.count) chars) at \(timestamp)s")
        onClipCaptured?(count)
    }
}
