import AppKit
import Carbon.HIToolbox
import os.log

private let hotkeyLogger = Logger(subsystem: "com.swair.hearsay", category: "hotkey")

/// Monitors for global hotkeys using:
/// - CGEventTap flagsChanged for hold mode (modifier press/release)
/// - Carbon EventHotKey for toggle combo (reliable in menu-bar/background mode)
final class HotkeyMonitor {
    
    enum State {
        case idle
        case recordingHold    // Hold mode - release hold key to stop
        case recordingToggle  // Toggle mode - press toggle combo again to stop
    }
    
    // Keycodes (configurable)
    private var holdKeyCode: Int64 = 61  // Default: Right Option
    private var toggleStartKeyCode: Int64 = 49  // Default: Space
    private var toggleStartModifiers: UInt64 = 0  // Default: Option
    private var toggleStopKeyCode: Int64 = 49  // Kept for settings compatibility
    
    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?
    var onScreenshotRequested: (() -> Void)?
    
    private(set) var state: State = .idle
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdPollingTimer: Timer?
    private var tapRecoveryWorkItem: DispatchWorkItem?
    private var tapDisableTimestamps: [Date] = []
    private var tapRecoveryAttempts = 0
    
    private var hotKeyHandler: EventHandlerRef?
    private var toggleHotKeyRef: EventHotKeyRef?
    private let toggleHotKeyID: UInt32 = 1
    
    // Screenshot hotkey (Option+4)
    private var screenshotHotKeyRef: EventHotKeyRef?
    private let screenshotHotKeyID: UInt32 = 2
    private let screenshotKeyCode: UInt32 = 21  // '4' key
    
    private let tapDisableWindow: TimeInterval = 10.0
    private let maxTapDisableEventsBeforeRestart = 3
    private let maxTapRecoveryAttemptsBeforeRestart = 5
    
    // Track if hold key is held alone (no other modifiers/keys)
    private var rightOptionDownAlone = false
    private var holdModifierWasPressed = false
    
    init() {
        loadSettings()
    }
    
    deinit {
        stop()
        if let handler = hotKeyHandler {
            RemoveEventHandler(handler)
            hotKeyHandler = nil
        }
    }
    
    /// Reload hotkey settings from UserDefaults
    func loadSettings() {
        holdKeyCode = Int64(UserDefaults.standard.object(forKey: "holdKeyCode") as? Int ?? 61)
        toggleStartKeyCode = Int64(UserDefaults.standard.object(forKey: "toggleStartKeyCode") as? Int ?? 49)
        toggleStartModifiers = UInt64(UserDefaults.standard.object(forKey: "toggleStartModifiers") as? Int ?? Int(CGEventFlags.maskAlternate.rawValue))
        toggleStopKeyCode = Int64(UserDefaults.standard.object(forKey: "toggleStopKeyCode") as? Int ?? 49)
        hotkeyLogger.info("Hotkeys loaded: hold=\(self.holdKeyCode), toggleStart=\(self.toggleStartKeyCode)+\(self.toggleStartModifiers), toggleStop=\(self.toggleStopKeyCode)")
        
        if hotKeyHandler != nil {
            registerToggleHotKey()
        }
    }
    
    // MARK: - Public
    
    func start() -> Bool {
        installHotKeyHandlerIfNeeded()
        
        if toggleHotKeyRef == nil {
            registerToggleHotKey()
        }
        
        startHoldPolling()
        
        guard eventTap == nil else {
            return true
        }
        
        hotkeyLogger.info("Creating hold-mode event tap...")
        if createAndStartEventTap() {
            return true
        }
        
        if !Self.hasAccessibilityPermission {
            hotkeyLogger.warning("Hold event tap unavailable (accessibility not granted) - toggle hotkey remains active")
            return true
        }
        
        hotkeyLogger.error("Failed to create hold event tap despite accessibility permission")
        return false
    }
    
    func stop() {
        hotkeyLogger.info("HotkeyMonitor.stop() called")
        cancelTapRecovery()
        if holdPollingTimer != nil {
            hotkeyLogger.info("Invalidating polling timer")
            holdPollingTimer?.invalidate()
            holdPollingTimer = nil
        }
        destroyEventTap()
        unregisterToggleHotKey()
        unregisterScreenshotHotKey()
        holdModifierWasPressed = false
        rightOptionDownAlone = false
        state = .idle
    }
    
    /// Enable screenshot hotkey (call when recording starts)
    func enableScreenshotHotKey() {
        registerScreenshotHotKey()
    }
    
    /// Disable screenshot hotkey (call when recording stops)
    func disableScreenshotHotKey() {
        unregisterScreenshotHotKey()
    }
    
    // MARK: - Event Tap Lifecycle
    
    private func createAndStartEventTap() -> Bool {
        // Hold mode relies on modifier transitions only.
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            hotkeyLogger.error("Failed to create event tap - Accessibility permission required!")
            return false
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        tapRecoveryAttempts = 0
        tapDisableTimestamps.removeAll()
        
        hotkeyLogger.info("Event tap started - listening for hold key \(self.holdKeyCode) and toggle combo")
        return true
    }
    
    private func destroyEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
    }
    
    private func cancelTapRecovery() {
        tapRecoveryWorkItem?.cancel()
        tapRecoveryWorkItem = nil
        tapRecoveryAttempts = 0
        tapDisableTimestamps.removeAll()
    }
    
    private func restartEventTap(reason: String) {
        tapRecoveryWorkItem?.cancel()
        
        let delay: TimeInterval = min(0.5 * pow(2.0, Double(max(0, tapRecoveryAttempts - 1))), 3.0)
        hotkeyLogger.warning("Restarting hold event tap in \(delay)s (\(reason), attempt \(self.tapRecoveryAttempts))")
        
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.destroyEventTap()
            
            guard Self.hasAccessibilityPermission else {
                hotkeyLogger.error("Skipping hold event tap restart - accessibility permission missing")
                return
            }
            
            if self.createAndStartEventTap() {
                hotkeyLogger.info("Hold event tap restart succeeded")
            } else {
                self.tapRecoveryAttempts += 1
                self.restartEventTap(reason: "restart failed")
            }
        }
        
        tapRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    
    private var pollCount: Int = 0
    
    private func startHoldPolling() {
        if holdPollingTimer != nil { return }
        
        let initialFlags = CGEventSource.flagsState(.combinedSessionState)
        holdModifierWasPressed = isHoldKeyDownInSessionState(flags: initialFlags)
        
        hotkeyLogger.info("Starting hold polling timer")
        holdPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            self?.pollHoldState()
        }
    }
    
    private func pollHoldState() {
        pollCount += 1
        // Log every 10 seconds (500 polls at 0.02s interval) to confirm polling is alive
        if pollCount % 500 == 0 {
            print("HEARTBEAT #\(pollCount) state=\(state)")
            hotkeyLogger.info("Poll heartbeat #\(self.pollCount), state=\(String(describing: self.state))")
        }
        
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let holdKeyDown = isHoldKeyDownInSessionState(flags: flags)
        let holdJustPressed = holdKeyDown && !holdModifierWasPressed
        let holdJustReleased = !holdKeyDown && holdModifierWasPressed
        defer { holdModifierWasPressed = holdKeyDown }
        
        let otherModifiers = hasOtherModifierFlags(flags, excludingHoldKeyCode: holdKeyCode)
        
        if state == .idle {
            if holdJustPressed && !otherModifiers {
                hotkeyLogger.info("HOLD KEY DOWN (poll) - starting HOLD recording")
                rightOptionDownAlone = true
                state = .recordingHold
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStart?()
                }
            }
            return
        }
        
        if state == .recordingHold {
            if holdJustReleased {
                hotkeyLogger.info("HOLD KEY UP (poll) - stopping HOLD recording")
                rightOptionDownAlone = false
                state = .idle
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStop?()
                }
            } else if otherModifiers && rightOptionDownAlone {
                hotkeyLogger.info("Other modifier pressed (poll) - canceling HOLD recording")
                rightOptionDownAlone = false
                state = .idle
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStop?()
                }
            }
            return
        }
        
        if state == .recordingToggle && holdJustReleased {
            rightOptionDownAlone = false
        }
    }
    
    // MARK: - Event Handling
    
    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            handleTapDisabled(type: type)
            return Unmanaged.passUnretained(event)
        }
        
        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
        
        let flags = event.flags
        let otherModifiers = flags.contains(.maskCommand) ||
                             flags.contains(.maskControl) ||
                             flags.contains(.maskShift)
        
        let holdKeyIsPressed = isModifierKeyPressed(keyCode: holdKeyCode, flags: flags)
        let holdJustPressed = holdKeyIsPressed && !holdModifierWasPressed
        let holdJustReleased = !holdKeyIsPressed && holdModifierWasPressed
        defer { holdModifierWasPressed = holdKeyIsPressed }
        
        if state == .idle {
            // Use modifier transition rather than strict keycode equality.
            // This is more reliable across keyboards/layouts for right-side modifiers.
            if holdJustPressed && !otherModifiers {
                hotkeyLogger.info("HOLD KEY DOWN - starting HOLD recording")
                rightOptionDownAlone = true
                state = .recordingHold
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStart?()
                }
            }
        } else if state == .recordingHold {
            if holdJustReleased {
                hotkeyLogger.info("HOLD KEY UP - stopping HOLD recording")
                rightOptionDownAlone = false
                state = .idle
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStop?()
                }
            } else if otherModifiers && rightOptionDownAlone {
                hotkeyLogger.info("Other modifier pressed - canceling HOLD recording")
                rightOptionDownAlone = false
                state = .idle
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStop?()
                }
            }
        } else if state == .recordingToggle {
            if holdJustReleased {
                rightOptionDownAlone = false
            }
        }
        
        return Unmanaged.passUnretained(event)
    }
    
    private func handleTapDisabled(type: CGEventType) {
        let now = Date()
        tapDisableTimestamps.append(now)
        tapDisableTimestamps.removeAll { now.timeIntervalSince($0) > tapDisableWindow }
        tapRecoveryAttempts += 1
        
        let tooManyDisableEvents = tapDisableTimestamps.count >= maxTapDisableEventsBeforeRestart
        let tooManyAttempts = tapRecoveryAttempts >= maxTapRecoveryAttemptsBeforeRestart
        
        if tooManyDisableEvents || tooManyAttempts {
            restartEventTap(reason: "tap disabled repeatedly (\(type.rawValue))")
            return
        }
        
        let delay: TimeInterval = min(0.05 * pow(2.0, Double(max(0, tapRecoveryAttempts - 1))), 0.5)
        hotkeyLogger.warning("Event tap disabled (\(type.rawValue)); re-enabling in \(delay)s (attempt \(self.tapRecoveryAttempts))")
        
        tapRecoveryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if let tap = self.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        tapRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    
    // MARK: - Carbon Hotkey
    
    private func installHotKeyHandlerIfNeeded() {
        guard hotKeyHandler == nil else { return }
        
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData = userData else { return noErr }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                
                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                
                if result == noErr {
                    if hotKeyID.id == monitor.toggleHotKeyID {
                        monitor.handleToggleHotKeyPressed()
                    } else if hotKeyID.id == monitor.screenshotHotKeyID {
                        monitor.handleScreenshotHotKeyPressed()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )
        
        if status != noErr {
            hotkeyLogger.error("Failed to install hotkey handler: status=\(status)")
        }
    }
    
    private func registerToggleHotKey() {
        unregisterToggleHotKey()
        
        guard toggleStartKeyCode > 0 else { return }
        
        let carbonModifiers = carbonModifiersFromCGFlags(toggleStartModifiers)
        let hotKeyID = EventHotKeyID(signature: fourCharCode("HSY1"), id: toggleHotKeyID)
        
        let status = RegisterEventHotKey(
            UInt32(toggleStartKeyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &toggleHotKeyRef
        )
        
        if status != noErr {
            hotkeyLogger.error("Failed to register toggle hotkey: keyCode=\(self.toggleStartKeyCode), modifiers=\(self.toggleStartModifiers), status=\(status)")
        } else {
            hotkeyLogger.info("Registered toggle hotkey: keyCode=\(self.toggleStartKeyCode), carbonModifiers=\(carbonModifiers)")
        }
    }
    
    private func unregisterToggleHotKey() {
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }
    }
    
    // MARK: - Screenshot Hotkey (Option+4)
    
    private func registerScreenshotHotKey() {
        unregisterScreenshotHotKey()
        
        let hotKeyID = EventHotKeyID(signature: fourCharCode("HSY2"), id: screenshotHotKeyID)
        
        // Option modifier
        let carbonModifiers = UInt32(optionKey)
        
        let status = RegisterEventHotKey(
            screenshotKeyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &screenshotHotKeyRef
        )
        
        if status != noErr {
            hotkeyLogger.error("Failed to register screenshot hotkey: status=\(status)")
        } else {
            hotkeyLogger.info("Registered screenshot hotkey: Option+4")
        }
    }
    
    private func unregisterScreenshotHotKey() {
        if let ref = screenshotHotKeyRef {
            UnregisterEventHotKey(ref)
            screenshotHotKeyRef = nil
            hotkeyLogger.info("Unregistered screenshot hotkey")
        }
    }
    
    private func handleScreenshotHotKeyPressed() {
        // Only trigger if we're currently recording
        guard state == .recordingHold || state == .recordingToggle else {
            hotkeyLogger.info("Screenshot hotkey pressed but not recording - ignoring")
            return
        }
        
        hotkeyLogger.info("SCREENSHOT HOTKEY - triggering screenshot capture")
        DispatchQueue.main.async { [weak self] in
            self?.onScreenshotRequested?()
        }
    }
    
    private func handleToggleHotKeyPressed() {
        if state == .idle {
            hotkeyLogger.info("TOGGLE HOTKEY - starting TOGGLE recording")
            state = .recordingToggle
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingStart?()
            }
            return
        }
        
        if state == .recordingHold {
            hotkeyLogger.info("TOGGLE HOTKEY - converting HOLD to TOGGLE recording")
            state = .recordingToggle
            rightOptionDownAlone = false
            return
        }
        
        if state == .recordingToggle {
            hotkeyLogger.info("TOGGLE HOTKEY - stopping TOGGLE recording")
            state = .idle
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingStop?()
            }
        }
    }
    
    // MARK: - Helpers
    
    private func carbonModifiersFromCGFlags(_ flags: UInt64) -> UInt32 {
        let mask = CGEventFlags.maskCommand.rawValue |
                   CGEventFlags.maskAlternate.rawValue |
                   CGEventFlags.maskShift.rawValue |
                   CGEventFlags.maskControl.rawValue
        let filtered = flags & mask
        
        var carbon: UInt32 = 0
        if (filtered & CGEventFlags.maskCommand.rawValue) != 0 { carbon |= UInt32(cmdKey) }
        if (filtered & CGEventFlags.maskAlternate.rawValue) != 0 { carbon |= UInt32(optionKey) }
        if (filtered & CGEventFlags.maskShift.rawValue) != 0 { carbon |= UInt32(shiftKey) }
        if (filtered & CGEventFlags.maskControl.rawValue) != 0 { carbon |= UInt32(controlKey) }
        return carbon
    }
    
    private func fourCharCode(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) + UInt32($1) }
    }
    
    /// Check if a modifier key is currently pressed based on flags
    private func isModifierKeyPressed(keyCode: Int64, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 61, 58:  // Right/Left Option
            return flags.contains(.maskAlternate)
        case 54, 55:  // Right/Left Command
            return flags.contains(.maskCommand)
        case 62, 59:  // Right/Left Control
            return flags.contains(.maskControl)
        case 60, 56:  // Right/Left Shift
            return flags.contains(.maskShift)
        default:
            return false
        }
    }
    
    private func hasOtherModifierFlags(_ flags: CGEventFlags, excludingHoldKeyCode keyCode: Int64) -> Bool {
        var others: CGEventFlags = []
        
        if ![54, 55].contains(keyCode) { others.insert(.maskCommand) }
        if ![58, 61].contains(keyCode) { others.insert(.maskAlternate) }
        if ![56, 60].contains(keyCode) { others.insert(.maskShift) }
        if ![59, 62].contains(keyCode) { others.insert(.maskControl) }
        
        return flags.intersection(others).isEmpty == false
    }
    
    private func isHoldKeyDownInSessionState(flags: CGEventFlags) -> Bool {
        switch holdKeyCode {
        case 54, 55, 56, 58, 59, 60, 61, 62:
            return isModifierKeyPressed(keyCode: holdKeyCode, flags: flags)
        default:
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(holdKeyCode))
        }
    }
    
    // MARK: - Permissions
    
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }
    
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
