import AppKit
import ApplicationServices
import CoreAudio
import os.log

private let detectorLogger = Logger(subsystem: "com.swair.hearsay", category: "call-detector")

/// Notices when a call app starts or stops using the microphone, so Hearsay
/// can offer to record (and later, to stop).
///
/// Uses Core Audio's per-process "is running input" flag (macOS 14+). Browsers
/// only count when a window title looks like a meeting (Meet, Zoom, Teams),
/// because plenty of web pages use the mic for other things.
final class MeetingCallDetector {

    struct Call: Equatable {
        /// "Zoom", "Google Meet", …
        let name: String
        let bundleIdentifier: String
    }

    var onCallStarted: ((Call) -> Void)?
    var onCallEnded: ((Call) -> Void)?

    private(set) var activeCall: Call?
    private var timer: Timer?
    private var candidate: Call?
    private var candidateHits = 0
    private var missingPolls = 0

    private static let pollInterval: TimeInterval = 3
    /// Polls in a row before a call counts as started / ended.
    private static let startPolls = 2
    private static let endPolls = 4

    private static let nativeApps: [(prefix: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.cisco.webex", "Webex"),
        ("com.webex.", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack huddle"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.hnc.Discord", "Discord"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("com.skype.skype", "Skype"),
        ("com.ringcentral", "RingCentral"),
        ("com.gotomeeting", "GoTo Meeting"),
    ]

    /// Browser helper bundle prefixes → the main app's bundle id (for window titles).
    private static let browsers: [(prefix: String, app: String)] = [
        ("com.google.Chrome", "com.google.Chrome"),
        ("company.thebrowser", "company.thebrowser.Browser"),
        ("com.brave.Browser", "com.brave.Browser"),
        ("com.microsoft.edgemac", "com.microsoft.edgemac"),
        ("org.mozilla.firefox", "org.mozilla.firefox"),
        ("com.vivaldi.Vivaldi", "com.vivaldi.Vivaldi"),
        ("com.apple.WebKit", "com.apple.Safari"),
        ("com.apple.Safari", "com.apple.Safari"),
    ]

    private static let meetingTitleHints: [(needle: String, name: String)] = [
        ("Meet - ", "Google Meet"),
        ("Google Meet", "Google Meet"),
        ("Zoom Meeting", "Zoom"),
        ("Microsoft Teams", "Microsoft Teams"),
        ("| Microsoft Teams", "Microsoft Teams"),
        ("Webex", "Webex"),
        ("Whereby", "Whereby"),
        ("Jitsi Meet", "Jitsi"),
    ]

    func start() {
        guard timer == nil else { return }
        guard #available(macOS 14.0, *) else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer.tolerance = 1
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activeCall = nil
        candidate = nil
        candidateHits = 0
        missingPolls = 0
    }

    private func poll() {
        guard #available(macOS 14.0, *) else { return }
        let current = Self.detectCall()

        if let activeCall {
            if current == activeCall {
                missingPolls = 0
            } else {
                missingPolls += 1
                if missingPolls >= Self.endPolls {
                    detectorLogger.notice("Call ended: \(activeCall.name, privacy: .public)")
                    self.activeCall = nil
                    missingPolls = 0
                    onCallEnded?(activeCall)
                }
            }
            return
        }

        guard let current else {
            candidate = nil
            candidateHits = 0
            return
        }
        if current == candidate {
            candidateHits += 1
        } else {
            candidate = current
            candidateHits = 1
        }
        if candidateHits >= Self.startPolls {
            detectorLogger.notice("Call detected: \(current.name, privacy: .public)")
            activeCall = current
            candidate = nil
            candidateHits = 0
            onCallStarted?(current)
        }
    }

    // MARK: - Detection

    @available(macOS 14.0, *)
    private static func detectCall() -> Call? {
        let ownBundle = Bundle.main.bundleIdentifier ?? "com.swair.hearsay"
        let inputBundles = processesUsingMicrophone().filter { !$0.hasPrefix(ownBundle) }

        for bundle in inputBundles {
            if let match = nativeApps.first(where: { bundle.hasPrefix($0.prefix) }) {
                return Call(name: match.name, bundleIdentifier: bundle)
            }
        }
        for bundle in inputBundles {
            guard let browser = browsers.first(where: { bundle.hasPrefix($0.prefix) }),
                  let name = meetingNameFromWindowTitles(appBundleIdentifier: browser.app) else { continue }
            return Call(name: name, bundleIdentifier: browser.app)
        }
        return nil
    }

    /// Bundle ids of processes currently recording from an input device.
    @available(macOS 14.0, *)
    private static func processesUsingMicrophone() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        return objects.compactMap { object in
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { return nil }

            var bundle: CFString = "" as CFString
            var bundleSize = UInt32(MemoryLayout<CFString>.size)
            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = withUnsafeMutablePointer(to: &bundle) { pointer in
                AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, pointer)
            }
            guard status == noErr else { return nil }
            let identifier = bundle as String
            return identifier.isEmpty ? nil : identifier
        }
    }

    /// Reads the browser's window titles via Accessibility (Hearsay already has it).
    private static func meetingNameFromWindowTitles(appBundleIdentifier: String) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier)
        for app in apps {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for window in windows {
                var title: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                      let text = title as? String else { continue }
                if let hint = meetingTitleHints.first(where: { text.contains($0.needle) }) {
                    return hint.name
                }
            }
        }
        return nil
    }
}
