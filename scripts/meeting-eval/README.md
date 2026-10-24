# Meeting pipeline evaluation

Synthetic meetings with known ground truth, replayed through the live
meeting pipeline (segmentation → transcription → echo removal → diarization).

```bash
# 1. Build a fixture: `say` voices as speakers, mic and call on separate tracks.
scripts/meeting-eval/make_fixture.py --out /tmp/fx/clean
scripts/meeting-eval/make_fixture.py --out /tmp/fx/echo --echo --overlap   # mic hears the call; turns overlap
scripts/meeting-eval/make_fixture.py --out /tmp/fx/distinct --voice carol=Fred

# 2. Replay it through a running Hearsay (no microphone or call needed).
hearsay meeting start --replay-mic /tmp/fx/clean/microphone.wav \
    --replay-system /tmp/fx/clean/system.wav --speed 2
hearsay meeting status          # wait for "Not recording"

# 3. Score it.
hearsay meetings show latest --format json > /tmp/fx/clean/actual.json
scripts/meeting-eval/score.py /tmp/fx/clean/expected.json /tmp/fx/clean/actual.json
```

`score.py` reports word error rate (per track), call-side speaker attribution
accuracy after mapping diarizer labels to the true speakers, and how much echo
leaked into the "You" lines. `--max-wer` / `--min-speaker-accuracy` make it
exit non-zero for use as a regression gate.

Synthetic voices are cleaner than real calls: treat these numbers as an upper
bound and a regression check, then sanity-check with a real recorded call
(replay the `microphone.m4a` / `system.m4a` saved next to any meeting).

UI checks without Screen Recording permission: launch the app with
`HEARSAY_DEBUG_API=1`, open a meeting with `hearsay meetings open <id> --view reader`,
then `POST /v1/debug/snapshot` on the local API renders Hearsay's windows to PNGs.

## Accurate pass experiment (offline)

Re-processes a saved meeting the slow way and compares it with the live
transcript, without changing the app:

- each live utterance is re-transcribed to get per-word timings (`utterwords`),
- speakers are detected over the whole call track at once (FluidAudio offline
  pyannote + VBx), each word gets a speaker, and lines split where it changes,
- local LLMs are asked to name the speakers from the conversation.

```bash
# Tools: FluidAudio's CLI (speaker detection) and utterwords (word timings).
# Both build against the FluidAudio checkout from an Xcode build of the app.
swift build -c release --package-path build/SourcePackages/checkouts/FluidAudio \
    --scratch-path /tmp/fa --product fluidaudiocli
swift build -c release --package-path scripts/meeting-eval/utterwords --scratch-path /tmp/uw

scripts/meeting-eval/accurate_pass.py latest --out /tmp/pass \
    --fluidaudio /tmp/fa/release/fluidaudiocli --utterwords /tmp/uw/release/utterwords \
    --llm "gguf:$HOME/Library/Application Support/Hearsay/CleanupModels/Qwen3.5-0.8B-Q4_K_M.gguf"
open /tmp/pass/comparison.html     # live and accurate side by side

# Same comparison on a fixture, scored against ground truth.
scripts/meeting-eval/make_fixture.py --out /tmp/fx/b2b --gap 0.15 --voice carol=Fred
scripts/meeting-eval/compare_fixture.py /tmp/fx/b2b \
    --fluidaudio /tmp/fa/release/fluidaudiocli --utterwords /tmp/uw/release/utterwords
```

`--vocab terms.txt` (with `--rerun-text`) tries FluidAudio's CTC vocabulary
boosting. With default thresholds it replaced many ordinary words with
vocabulary terms ("work" → "Warp", "such" → "Zach"), so it is not used.
