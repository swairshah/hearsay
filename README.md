<h1>  <img src="assets/icon_128.png" alt="Hearsay icon" width="30"/> Hearsay</h1>

**Local speech-to-text for macOS.** Hold a key, speak, release — your words appear right where your cursor is. Everything runs on your Mac. 

![Demo](assets/demo.gif)

## Install

**[⬇ Download the latest release](https://github.com/swairshah/hearsay/releases/latest)** — open the DMG and drag Hearsay to Applications.

Or with Homebrew:

```bash
brew install --cask swairshah/tap/hearsay
```

## How to use

| Action | Default shortcut |
|--------|-----|
| **Record** | Hold **Right Option (⌥)** and speak |
| **Transcribe** | Release the key — text is pasted at your cursor |
| **Hands-free mode** | **⌥Space** to toggle recording, **Space** or **Esc** to stop |
| **Screenshot while recording** | **⌥4** to select a region, **⌥3** for the full screen — images are referenced in your transcript |

All shortcuts (and the Hold vs. Toggle activation style) are customizable in **Settings → Keyboard Shortcuts**.

Transcribed text is pasted at your cursor and copied to the clipboard — both behaviors can be toggled in Settings.

Every transcription is saved locally in **History** — find recent ones in the menu bar dropdown, or open the Hearsay window and click any line to copy it again. If a transcription ever fails, the audio is kept and you can retry it from History with one click.

## Recording meetings

Choose **Record Meeting** in the menu bar (or the Meetings pane). The menu bar icon turns red while it records. Hearsay captures two tracks and transcribes them as the meeting goes:

- **Your microphone**, labelled *You*
- **The call audio** (whatever your Mac plays: Zoom, Meet, Teams…), split into *Speaker 1*, *Speaker 2*, … by an on-device diarization model. Rename speakers in the **Speakers** view.

When you stop, Hearsay detects speakers again over the whole call recording (a few seconds) and splits lines where one person picks up right after another. **Re-detect Speakers** (or `hearsay meetings refine <id>`) runs the same pass on older meetings.

Everything stays on your Mac. Call audio needs macOS 14.2+ and the *System Audio Recording* permission, and speaker detection needs Apple Silicon.

- **Live transcript** with words appearing while people talk (Parakeet and Whisper models)
- **Calendar** of recorded days; pick a day to list its meetings, or search across all meetings
- **Three views**: Transcript (timeline, editable), Reader (selectable document), Speakers (talk time, rename, merge)
- **Clean-up**: filler-word rules run by themselves when a meeting ends; "Show Original Text" and "Restore Original Transcript" are in the … menu
- **Copy** the transcript, or **share / export Markdown**
- **Reminders**: asks whether the meeting is over after a few silent minutes, stops by itself after a longer silence, and offers to record when a call app starts using the mic

If you use speakers instead of headphones, your mic hears the call too. Hearsay removes those duplicate lines.

From the terminal (works for agents too):

```bash
hearsay meeting start | stop | status
hearsay meetings                      # recent meetings
hearsay meetings show latest          # Markdown transcript
hearsay meetings search "pricing"     # across every meeting
```

## Vocabulary

List the names and terms your meetings use (people, companies, products, jargon) in the **Vocabulary** pane, with how the speech model tends to mishear them. Hearsay swaps those mishearings for the right spelling in dictation and meeting transcripts, and gives the list to the LLM clean-up passes as a spelling reference.

```bash
hearsay vocab add HumanLayer --alias "human lair" --note "Dexter's company"
hearsay vocab edit HumanLayer --add-alias humanlair
hearsay vocab search human
hearsay vocab remove HumanLayer
hearsay vocab export --format fluidaudio   # term: alias, alias (one per line)
```

The list lives in `~/Library/Application Support/Hearsay/vocabulary.json`; CLI edits apply to the next transcription, with or without the app running.

## First launch

1. Grant **Microphone** permission when prompted
2. Grant **Accessibility** permission (System Settings → Privacy & Security → Accessibility)
3. Pick a speech model to download:
   - **Parakeet** — English and multilingual, Apple Silicon (recommended)
   - **Qwen** — fast and high-quality, works on all Macs including Intel
   - **Whisper** — English transcription (Apple Silicon)

You can download, switch between, and delete models anytime from the **Models** tab.

## The Hearsay window

Everything lives in one window with a sidebar:

- **Settings** — clipboard/paste behavior, sound effects, dock icon, history size, and keyboard shortcuts
- **Models** — download, activate, and delete speech models: Qwen Fast (0.6B) / Quality (1.7B), Whisper tiny.en / small.en, Parakeet English (v2) / Multilingual (v3)
- **Microphone** — pick your input device
- **Replacements** — automatic text substitutions applied to transcripts
- **Vocabulary** — names and terms to spell right, with how they tend to be misheard
- **Cleanup** & **Post Processing** — rules and LLM-powered polishing for transcribed text
- **Meetings** — calendar of recorded meetings, live and saved transcripts, search, clean-up, export
- **History** — every transcription, click a line to copy it, retry failed ones
- **Permissions** — check and fix Microphone/Accessibility access

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon or Intel

## For developers

- Hearsay ships with a `hearsay` CLI (`hearsay dictate`, `hearsay history`, `hearsay logs`, …). Apps and editor extensions can use Hearsay as a local dictation provider — see the [Local API Integration Guide](docs/local-api-integration-guide.md).
- Speech backends: [qwen-asr](https://github.com/antirez/qwen-asr) by antirez, [WhisperKit](https://github.com/argmaxinc/WhisperKit), and NVIDIA Parakeet via [FluidAudio](https://github.com/FluidInference/FluidAudio).
- Build instructions and architecture: [DEVELOPMENT.md](DEVELOPMENT.md)

## License

MIT
