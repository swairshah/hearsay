# Hearsay

Local speech-to-text for macOS. Hold Right Option to record, release to transcribe, auto-paste at cursor.

**100% local** — no cloud, no data leaves your Mac.

![Demo](assets/demo.gif)

## Install

```bash
brew install --cask swairshah/tap/hearsay
```

Or download from [Releases](https://github.com/swairshah/hearsay/releases).

## Usage

| Action | How |
|--------|-----|
| **Record** | Hold **Right Option (⌥)** |
| **Transcribe** | Release the key |
| **Toggle mode** | **Right Option + Space** to start, **Space** or **Escape** to stop |

Transcribed text is automatically pasted at your cursor and copied to clipboard.

## First Launch

1. Grant **Microphone** permission when prompted
2. Grant **Accessibility** permission (System Settings → Privacy & Security → Accessibility)
3. Choose a model to download:
   - **Fast (0.6B)** — 1.3 GB, quick transcription
   - **Quality (1.7B)** — 3.4 GB, better accuracy

Models are stored in `~/Library/Application Support/Hearsay/Models/`

## Requirements

- macOS 13.0 (Ventura) or later
- Works on both Apple Silicon and Intel Macs

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for build instructions and technical details.

## License

MIT
