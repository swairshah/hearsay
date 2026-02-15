import AppKit
import Carbon.HIToolbox
import os.log

private let hotkeyLogger = Logger(subsystem: "com.swair.hearsay", category: "hotkey")

/// Monitors for global hotkeys using CGEventTap.
/// This requires Accessibility permissions.
/// 
/// Two recording modes:
/// 1. Hold mode: Hold a modifier key → release to transcribe
/// 2. Toggle mode: Press a key combo to start → press stop key or Escape to stop
final class HotkeyMonitor {
    
    enum State {
        case idle
        case recordingHold    // Hold mode - release Right Option to stop
        case recordingToggle  // Toggle mode - press Escape/Space/Right Option to stop
    }
    
    // Keycodes (configurable)
    private var holdKeyCode: Int64 = 61  // Default: Right Option
    private var toggleStartKeyCode: Int64 = 49  // Default: Space
    private var toggleStartModifiers: UInt64 = 0  // Default: Option
    private var toggleStopKeyCode: Int64 = 49  // Default: Space
    private let kVK_Escape: Int64 = 53
    
    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?
    
    private(set) var state: State = .idle
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // Track if Right Option is held alone (no other modifiers/keys)
    private var rightOptionDownAlone = false
    // Track if Right Option is currently held (for combo detection)
    private var rightOptionHeld = false
    
    init() {
        loadSettings()
    }
    
    /// Reload hotkey settings from UserDefaults
    func loadSettings() {
        holdKeyCode = Int64(UserDefaults.standard.object(forKey: "holdKeyCode") as? Int ?? 61)
        toggleStartKeyCode = Int64(UserDefaults.standard.object(forKey: "toggleStartKeyCode") as? Int ?? 49)
        toggleStartModifiers = UInt64(UserDefaults.standard.object(forKey: "toggleStartModifiers") as? Int ?? Int(CGEventFlags.maskAlternate.rawValue))
        toggleStopKeyCode = Int64(UserDefaults.standard.object(forKey: "toggleStopKeyCode") as? Int ?? 49)
        hotkeyLogger.info("Hotkeys loaded: hold=\(self.holdKeyCode), toggleStart=\(self.toggleStartKeyCode)+\(self.toggleStartModifiers), toggleStop=\(self.toggleStopKeyCode)")
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Public
    
    func start() -> Bool {
        guard eventTap == nil else { 
            hotkeyLogger.info("Event tap already exists")
            return true 
        }
        
        hotkeyLogger.info("Creating event tap...")
        
        // Monitor flags changed (modifiers) AND key down/up (for Space, Escape)
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) |
                                      (1 << CGEventType.keyDown.rawValue) |
                                      (1 << CGEventType.keyUp.rawValue)
        
        // Create event tap
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
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
        
        hotkeyLogger.info("Event tap started - listening for hold key \(self.holdKeyCode) or toggle combo")
        return true
    }
    
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        state = .idle
    }
    
    // MARK: - Event Handling
    
    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle tap disabled (system can disable it under heavy load)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            hotkeyLogger.warning("Event tap was disabled, re-enabling...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }
        
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        
        // Handle key down/up for Space and Escape
        if type == .keyDown {
            return handleKeyDown(keyCode: keyCode, event: event)
        } else if type == .keyUp {
            return handleKeyUp(keyCode: keyCode, event: event)
        }
        
        // Handle modifier flags changed
        guard type == .flagsChanged else { return Unmanaged.passRetained(event) }
        
        let flags = event.flags
        let optionPressed = flags.contains(.maskAlternate)
        let otherModifiers = flags.contains(.maskCommand) || 
                            flags.contains(.maskControl) || 
                            flags.contains(.maskShift)
        
        hotkeyLogger.debug("FlagsChanged: keyCode=\(keyCode), option=\(optionPressed), otherMods=\(otherModifiers), state=\(String(describing: self.state))")
        
        // Check if our hold key is a modifier that's currently pressed
        let holdKeyIsPressed = isModifierKeyPressed(keyCode: holdKeyCode, flags: flags)
        
        // === IDLE STATE ===
        if state == .idle {
            // Hold key pressed alone - start HOLD mode
            if keyCode == holdKeyCode && holdKeyIsPressed && !otherModifiers {
                hotkeyLogger.info("HOLD KEY DOWN - starting HOLD recording")
                rightOptionDownAlone = true
                rightOptionHeld = true
                state = .recordingHold
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStart?()
                }
            }
        }
        // === HOLD RECORDING STATE ===
        else if state == .recordingHold {
            // Hold key released - stop recording
            if keyCode == holdKeyCode && !holdKeyIsPressed {
                hotkeyLogger.info("HOLD KEY UP - stopping HOLD recording")
                rightOptionDownAlone = false
                rightOptionHeld = false
                state = .idle
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStop?()
                }
            }
            // Other modifier pressed - cancel
            else if otherModifiers && rightOptionDownAlone {
                hotkeyLogger.info("Other modifier pressed - canceling HOLD recording")
                rightOptionDownAlone = false
                rightOptionHeld = false
                state = .idle
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStop?()
                }
            }
        }
        // === TOGGLE RECORDING STATE ===
        else if state == .recordingToggle {
            // Hold key pressed again - stop recording
            if keyCode == holdKeyCode && holdKeyIsPressed {
                hotkeyLogger.info("HOLD KEY - stopping TOGGLE recording")
                state = .idle
                rightOptionHeld = false
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStop?()
                }
                return nil  // Consume event
            }
            // Track hold key release in toggle mode
            if keyCode == holdKeyCode && !holdKeyIsPressed {
                rightOptionHeld = false
            }
        }
        
        return Unmanaged.passRetained(event)
    }
    
    private func handleKeyDown(keyCode: Int64, event: CGEvent) -> Unmanaged<CGEvent>? {
        let currentModifiers = event.flags.rawValue & (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue)
        
        // Check for toggle START combo (key + modifiers) when IDLE
        if state == .idle && keyCode == toggleStartKeyCode {
            // Check if required modifiers match (allow extra modifiers)
            let requiredMods = toggleStartModifiers & (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue)
            if (currentModifiers & requiredMods) == requiredMods && requiredMods != 0 {
                hotkeyLogger.info("TOGGLE START COMBO - starting TOGGLE recording")
                state = .recordingToggle
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStart?()
                }
                return nil  // Consume the key
            }
        }
        
        // Toggle STOP key pressed during TOGGLE recording - stop
        if keyCode == toggleStopKeyCode && state == .recordingToggle {
            hotkeyLogger.info("TOGGLE STOP KEY - stopping TOGGLE recording")
            state = .idle
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingStop?()
            }
            return nil  // Consume event
        }
        
        // Escape pressed during TOGGLE recording - stop
        if keyCode == kVK_Escape && state == .recordingToggle {
            hotkeyLogger.info("ESCAPE - stopping TOGGLE recording")
            state = .idle
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingStop?()
            }
            return nil  // Consume event
        }
        
        return Unmanaged.passRetained(event)
    }
    
    private func handleKeyUp(keyCode: Int64, event: CGEvent) -> Unmanaged<CGEvent>? {
        return Unmanaged.passRetained(event)
    }
    
    // MARK: - Helpers
    
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
