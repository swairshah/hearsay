# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Hearsay

A macOS menu bar app for local speech-to-text. Hold Right Option to record, release to transcribe, text auto-pastes at cursor. Runs entirely offline using a bundled `qwen_asr` binary + Qwen3-ASR model.

## Build & Run

**Always use the run script:**
```bash
./run.sh
```

This generates the Xcode project (via XcodeGen), builds with `xcodebuild`, bundles the `qwen_asr` binary into the app, resets accessibility permissions, and launches. Do NOT use `open Hearsay.app` directly — it causes accessibility permission issues after rebuilds.

**Quick permission fix (no rebuild):**
```bash
./fix-permissions.sh
```

**Regenerate Xcode project after modifying `project.yml`:**
```bash
xcodegen generate
```

**Watch logs:**
```bash
log stream --predicate 'subsystem == "com.swair.hearsay"' --level debug
```

## Architecture

The app uses a callback-driven architecture. `AppDelegate` is the central coordinator — it owns all components and wires them together via closures (no delegates, no Combine, no SwiftUI).

**Recording flow:**
1. `HotkeyMonitor` detects Right Option key via `CGEventTap` (requires Accessibility permission) → calls `onRecordingStart`/`onRecordingStop`
2. `AppDelegate` tells `AudioRecorder` to start/stop → records 16kHz mono WAV via `AVAudioEngine` with sample rate conversion
3. `AppDelegate` tells `Transcriber` to process the WAV → spawns the bundled `qwen_asr` binary as a `Process` with `--silent` flag
4. `TextInserter` copies result to clipboard and simulates Cmd+V via `CGEvent` to paste at cursor
5. `HistoryStore` (singleton) persists to `~/Library/Application Support/Hearsay/History/history.json`

**Two recording modes** (both managed by `HotkeyMonitor.State`):
- **Hold**: Hold Right Option → release to stop
- **Toggle**: Hold Right Option + tap Space → press Space/Escape/Right Option to stop

**UI is AppKit throughout** — no SwiftUI. The recording indicator is a floating `NSPanel` (`RecordingWindow`) containing a custom `RecordingIndicator` view with waveform bars and animated dots. `StatusBarController` manages the menu bar item and dropdown menu.

## Key Conventions

- All dimensions, colors, and timing constants live in `Constants.swift`
- Logging uses `os.log` with subsystem `com.swair.hearsay` and per-file categories
- No third-party dependencies — pure AppKit + AVFoundation + system frameworks
- The app uses `main.swift` for entry (not `@main` attribute), manually creating `NSApplication` and `AppDelegate`
- Code signing is disabled (`CODE_SIGN_IDENTITY: "-"`, `ENABLE_HARDENED_RUNTIME: false`)

## Dependencies

- **XcodeGen** — generates `Hearsay.xcodeproj` from `project.yml`
- **qwen_asr binary** — built separately from `~/work/misc/qwen-asr/` (`make blas`), copied into app bundle by `run.sh`
- **Model files** — looked up at `~/Library/Application Support/Hearsay/Models/` (production) or `~/work/misc/qwen-asr/qwen3-asr-0.6b/` (dev fallback, hardcoded in `AppDelegate` and `Transcriber`)

## Permissions

The app requires **Microphone** (for recording) and **Accessibility** (for CGEventTap global hotkey + CGEvent paste simulation). After rebuilds, accessibility permission must be re-granted — `run.sh` handles the reset via `tccutil`.
