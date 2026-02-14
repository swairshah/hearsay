# Hearsay

Local speech-to-text for macOS. Hold Option to record, release to transcribe.

## Features

- **Hold-to-record**: Press and hold Option (⌥) key to record
- **Auto-transcribe**: Release to transcribe using local AI
- **Auto-paste**: Transcription is inserted at your cursor
- **Clipboard sync**: Also copies to clipboard
- **100% local**: No internet required, everything runs on your Mac

## Requirements

- macOS 13.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for project generation
- Xcode 16.0+ (or just command-line tools)
- A Qwen3-ASR model

## Setup

### 1. Build the transcription engine

```bash
cd ~/work/misc/qwen-asr
make blas
```

### 2. Download a model

```bash
cd ~/work/misc/qwen-asr
./download_model.sh
# Choose the 0.6B model for speed or 1.7B for quality
```

### 3. Build and run Hearsay

```bash
cd ~/work/projects/hearsay
./run.sh
```

### 4. Grant permissions

When prompted, grant:
- **Microphone access**: For recording your voice
- **Accessibility access**: For detecting Option key and pasting text

## Usage

1. Click the waveform icon in your menu bar to see options
2. Position your cursor where you want text
3. Hold **Option (⌥)** key — recording starts immediately
4. Speak your message
5. Release **Option** — transcription happens automatically
6. Text appears at your cursor (and in clipboard)

## Model Location

By default, Hearsay looks for models in:
- `~/Library/Application Support/Hearsay/Models/`
- Development: `~/work/misc/qwen-asr/qwen3-asr-0.6b/`

## Project Structure

```
hearsay/
├── Hearsay/
│   ├── main.swift              # App entry
│   ├── AppDelegate.swift       # Main coordinator
│   ├── Constants.swift         # Configuration
│   ├── Core/
│   │   ├── HotkeyMonitor.swift # Option key detection
│   │   ├── AudioRecorder.swift # Mic recording
│   │   ├── Transcriber.swift   # Runs qwen_asr
│   │   └── TextInserter.swift  # Paste at cursor
│   ├── UI/
│   │   ├── StatusBarController.swift
│   │   ├── RecordingWindow.swift
│   │   └── RecordingIndicator.swift
│   ├── History/
│   │   ├── HistoryStore.swift
│   │   └── TranscriptionItem.swift
│   └── Models/
│       ├── ModelManager.swift
│       └── ModelInfo.swift
├── project.yml                 # XcodeGen config
├── run.sh                      # Build & run script
└── README.md
```

## Development

Generate Xcode project:
```bash
xcodegen generate
open Hearsay.xcodeproj
```

Build from command line:
```bash
./run.sh
```

## License

MIT
