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
    
    private(set) var state: State = .idle
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    private var hotKeyHandler: EventHandlerRef?
    private var toggleHotKeyRef: EventHotKeyRef?
    private let toggleHotKeyID: UInt32 = 1
    
    // Track if hold key is held alone (no other modifiers/keys)
    private var rightOptionDownAlone = false
    // Track if hold key is currently held
    private var rightOptionHeld = false
    
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
        
        if eventTap != nil {
            registerToggleHotKey()
        }
    }
    
    // MARK: - Public
    
    func start() -> Bool {
        guard eventTap == nil else {
            hotkeyLogger.info("Event tap already exists")
            return true
        }
        guard Self.hasAccessibilityPermission else {
            hotkeyLogger.error("Cannot start hotkey monitor - Accessibility permission not granted")
            return false
        }
        
        hotkeyLogger.info("Creating event tap...")
        
        // Hold mode relies on modifier transitions only.
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
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
        
        installHotKeyHandlerIfNeeded()
        registerToggleHotKey()
        
        hotkeyLogger.info("Event tap started - listening for hold key \(self.holdKeyCode) and toggle combo")
        return true
    }
    
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        unregisterToggleHotKey()
        eventTap = nil
        runLoopSource = nil
        state = .idle
    }
    
    // MARK: - Event Handling
    
    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            hotkeyLogger.warning("Event tap was disabled, re-enabling...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        
        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
        
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let optionPressed = flags.contains(.maskAlternate)
        let otherModifiers = flags.contains(.maskCommand) ||
                             flags.contains(.maskControl) ||
                             flags.contains(.maskShift)
        
        hotkeyLogger.debug("FlagsChanged: keyCode=\(keyCode), option=\(optionPressed), otherMods=\(otherModifiers), state=\(String(describing: self.state))")
        
        let holdKeyIsPressed = isModifierKeyPressed(keyCode: holdKeyCode, flags: flags)
        
        if state == .idle {
            if keyCode == holdKeyCode && holdKeyIsPressed && !otherModifiers {
                hotkeyLogger.info("HOLD KEY DOWN - starting HOLD recording")
                rightOptionDownAlone = true
                rightOptionHeld = true
                state = .recordingHold
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStart?()
                }
            }
        } else if state == .recordingHold {
            if keyCode == holdKeyCode && !holdKeyIsPressed {
                hotkeyLogger.info("HOLD KEY UP - stopping HOLD recording")
                rightOptionDownAlone = false
                rightOptionHeld = false
                state = .idle
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStop?()
                }
            } else if otherModifiers && rightOptionDownAlone {
                hotkeyLogger.info("Other modifier pressed - canceling HOLD recording")
                rightOptionDownAlone = false
                rightOptionHeld = false
                state = .idle
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStop?()
                }
            }
        } else if state == .recordingToggle {
            if keyCode == holdKeyCode && !holdKeyIsPressed {
                rightOptionHeld = false
            }
        }
        
        return Unmanaged.passUnretained(event)
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
                
                if result == noErr && hotKeyID.id == monitor.toggleHotKeyID {
                    monitor.handleToggleHotKeyPressed()
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
        var hotKeyID = EventHotKeyID(signature: fourCharCode("HSY1"), id: toggleHotKeyID)
        
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
    
    // MARK: - Permissions
    
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }
    
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
