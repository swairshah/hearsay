# Hearsay System Hang Diagnosis

This document explains the system hang issue encountered with global hotkey monitoring and the fixes applied.

## Background

Hearsay now uses a split architecture:
- `CGEventTap` in `.listenOnly` mode for hold-to-record modifier transitions
- Carbon `RegisterEventHotKey` for toggle start/stop combo handling

This avoids putting toggle behavior on the event-tap input path.

## How CGEventTap Works

```
┌─────────────────────────────────────────────────────────────┐
│                      macOS Kernel                           │
│                                                             │
│  Keyboard → Event Queue → Event Tap → Window Server → Apps  │
│                              ↑                              │
│                         YOUR CALLBACK                       │
│                      (blocks the pipeline)                  │
└─────────────────────────────────────────────────────────────┘
```

With `.defaultTap`, your callback sits **in the middle** of the event pipeline. Every keystroke waits for your callback to return before reaching any application.
With `.listenOnly`, the callback receives a copy and cannot block the main input flow.

## Event Tap Modes

| Mode | Behavior | Risk Level |
|------|----------|------------|
| `.defaultTap` | Can intercept AND block/modify events | **HIGH** - Can freeze system |
| `.listenOnly` | Can only observe events (gets a copy) | **LOW** - Cannot freeze system |

### Why We Don't Need `.defaultTap` for Toggle Anymore

- Toggle combo detection moved to Carbon global hotkeys (`RegisterEventHotKey`)
- Carbon hotkeys are reliable when the app is menu-bar only / background
- Event tap is now only for hold-mode modifier transitions

### Why `.listenOnly` is Safer

```
.defaultTap:  Keyboard → [YOUR CODE] → Apps
              If callback blocks, NOTHING gets through
              
.listenOnly:  Keyboard → Apps (normal flow continues)
                  ↓
              YOUR CODE (gets a copy)
              If callback blocks, system continues normally
```

## What Causes a Hang

| Cause | Why it Freezes |
|-------|----------------|
| Callback doesn't return | Events queue up forever, all input frozen |
| Callback takes too long | System times out, may disable tap |
| Rapid disable/re-enable loop | Thrashing between states, system instability |
| Memory pressure from `passRetained` | System slows, callback gets slower, death spiral |
| Deadlock | Callback waits for main thread, main thread waits for callback |
| Exception in callback | Unclear return path, undefined behavior |

## Dangerous Patterns

```swift
// DANGEROUS - callback runs on a special system thread, not main thread
callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
    
    // ❌ BAD: Synchronous call to main thread - DEADLOCK RISK
    DispatchQueue.main.sync { 
        updateUI()  // Main thread might be waiting on us!
    }
    
    // ❌ BAD: Heavy computation - blocks ALL keyboard input
    let result = doExpensiveWork()
    
    // ❌ BAD: Retaining events - memory buildup over time
    return Unmanaged.passRetained(event)
    
    // ❌ BAD: Conditional return without else - might not return at all
    if someCondition {
        return nil
    }
    // Forgot return statement here - HANGS FOREVER
    
    // ❌ BAD: Throwing or crashing - undefined behavior
    try! riskyOperation()
}
```

## Safe Patterns

```swift
callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
    
    // ✅ GOOD: Async dispatch - non-blocking, returns immediately
    DispatchQueue.main.async { 
        self.handleHotkey()
    }
    
    // ✅ GOOD: Minimal work - just read the key code
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    
    // ✅ GOOD: passUnretained - no memory buildup
    return Unmanaged.passUnretained(event)
    
    // ✅ GOOD: Always return something - every code path returns
    guard condition else {
        return Unmanaged.passUnretained(event)
    }
    return Unmanaged.passUnretained(event)
}
```

## Fixes Applied

### 1. Memory Management: `passUnretained` vs `passRetained`

**Before (dangerous):**
```swift
return Unmanaged.passRetained(event)  // Retains event, can accumulate
```

**After (safe):**
```swift
return Unmanaged.passUnretained(event)  // No ownership, no accumulation
```

### 2. Async Dispatch for All Heavy Work

All recording start/stop actions are dispatched asynchronously:
```swift
DispatchQueue.main.async { [weak self] in
    self?.onRecordingStart?()
}
```

### 3. Trust Check Before Creating Tap

Don't create a tap if we don't have permission - leads to undefined behavior:
```swift
guard Self.hasAccessibilityPermission else {
    hotkeyLogger.error("Cannot start - no Accessibility permission")
    return false
}
```

### 4. Circuit Breaker Recovery for Disabled Taps

When the system disables the tap (under load), use bounded retries and restart logic:
```swift
if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    // count disable events in a time window
    // exponential backoff on re-enable
    // restart tap if disable events repeat
    return Unmanaged.passUnretained(event)
}
```

### 5. Move Tap to `.listenOnly`

Hold-mode tap no longer intercepts keyboard flow:
```swift
options: .listenOnly
```
This removes the primary system-freeze risk of `.defaultTap`.

### 6. State Machine Cleanup

- Debounce window to prevent rapid state transitions
- Clear state transitions with explicit handling for all cases
- Polling fallback when `keyDown` events are flaky

## Known Remaining Issues

### Hold Mode Still Depends on Event-Tap Delivery

Hold mode uses modifier `flagsChanged` events from the tap. If macOS disables taps repeatedly under heavy stress, hold mode can degrade temporarily while circuit-breaker recovery runs.

Toggle mode remains independent because it is handled by Carbon hotkeys.

### Hold Key / Toggle Modifier Overlap

**Problem:** Right Option is used for both:
1. Hold-to-record trigger (`holdKeyCode = 61`)
2. Part of Option+Space toggle combo (Option modifier)

**Symptom:** Pressing Right Option + Space starts hold mode immediately, then converts to toggle mode. Works but not ideal UX.

**Possible Solutions:**
1. Use different hold key (Right Command, Function key)
2. Add delay before starting hold mode to detect combos
3. Use Left Option for toggle, Right Option for hold (check keyCode 58 vs 61)

## Nuclear Option: Watchdog Timer

If hangs persist, add a watchdog that recreates the tap if callback seems stuck:

```swift
private var lastCallbackTime = Date()
private var watchdogTimer: Timer?

func startWatchdog() {
    watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
        guard let self = self else { return }
        if Date().timeIntervalSince(self.lastCallbackTime) > 2.0 && self.eventTap != nil {
            hotkeyLogger.warning("Watchdog: tap seems stuck, recreating...")
            self.stop()
            _ = self.start()
        }
    }
}

// In callback, update timestamp:
private func handleEvent(...) {
    lastCallbackTime = Date()
    // ... rest of handling
}
```

## Testing Recommendations

1. **Stress test:** Hold/release hotkey rapidly while typing
2. **Long session:** Leave app running for hours, check for degradation
3. **Background test:** Ensure toggle works without Settings window open
4. **Permission test:** Revoke/grant Accessibility permission while running
5. **System load:** Test while system is under heavy CPU/memory load

## References

- [Apple CGEventTap Documentation](https://developer.apple.com/documentation/coregraphics/cgeventtap)
- [Quartz Event Services](https://developer.apple.com/documentation/coregraphics/quartz_event_services)
- [NSEvent Global Monitors](https://developer.apple.com/documentation/appkit/nsevent/1535472-addglobalmonitorforevents)
