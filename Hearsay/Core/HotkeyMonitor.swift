import AppKit
import Carbon.HIToolbox
import os.log

private let hotkeyLogger = Logger(subsystem: "com.swair.hearsay", category: "hotkey")

/// Monitors for RIGHT Option key press/release globally using CGEventTap.
/// This requires Accessibility permissions.
/// 
/// Two recording modes:
/// 1. Hold mode: Hold Right Option → release to transcribe
/// 2. Toggle mode: Press Space + Right Option → press Escape/Space/Right Option to stop
final class HotkeyMonitor {
    
    enum State {
        case idle
        case recordingHold    // Hold mode - release Right Option to stop
        case recordingToggle  // Toggle mode - press Escape/Space/Right Option to stop
    }
    
    // Keycodes
    private let kVK_RightOption: Int64 = 61
    private let kVK_LeftOption: Int64 = 58
    private let kVK_Space: Int64 = 49
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
    
    init() {}
    
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
        
        hotkeyLogger.info("Event tap started - listening for RIGHT Option (hold) or Space+Right Option (toggle)")
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
        
        // === IDLE STATE ===
        if state == .idle {
            // Right Option pressed alone - start HOLD mode
            if keyCode == kVK_RightOption && optionPressed && !otherModifiers {
                hotkeyLogger.info("RIGHT OPTION DOWN - starting HOLD recording")
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
            // Right Option released - stop recording
            if keyCode == kVK_RightOption && !optionPressed {
                hotkeyLogger.info("RIGHT OPTION UP - stopping HOLD recording")
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
            // Right Option pressed - stop recording
            if keyCode == kVK_RightOption && optionPressed {
                hotkeyLogger.info("RIGHT OPTION - stopping TOGGLE recording")
                state = .idle
                rightOptionHeld = false
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStop?()
                }
                return nil  // Consume event
            }
            // Track Right Option release in toggle mode
            if keyCode == kVK_RightOption && !optionPressed {
                rightOptionHeld = false
            }
        }
        
        return Unmanaged.passRetained(event)
    }
    
    private func handleKeyDown(keyCode: Int64, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Space pressed during HOLD recording - switch to TOGGLE mode
        if keyCode == kVK_Space && state == .recordingHold {
            hotkeyLogger.info("SPACE during HOLD - switching to TOGGLE mode")
            state = .recordingToggle
            rightOptionDownAlone = false
            return nil  // Consume the space
        }
        
        // Space pressed during TOGGLE recording - stop
        if keyCode == kVK_Space && state == .recordingToggle {
            hotkeyLogger.info("SPACE - stopping TOGGLE recording")
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
    
    // MARK: - Permissions
    
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }
    
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
