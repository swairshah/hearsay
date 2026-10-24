#!/usr/bin/env python3
"""Build a synthetic two-track meeting with known ground truth.

Uses macOS `say` voices as speakers: one voice is "you" on the microphone
track, the others are call participants on the system track. Optionally
leaks a quiet copy of the call into the mic track (speakers instead of
headphones) to exercise echo suppression.

    scripts/meeting-eval/make_fixture.py --out /tmp/fixture [--echo] [--overlap]

Writes microphone.wav, system.wav (16 kHz mono 16-bit) and expected.json.
Replay it through the live pipeline with:

    hearsay meeting start --replay-mic /tmp/fixture/microphone.wav \
        --replay-system /tmp/fixture/system.wav --speed 2
"""

import argparse
import array
import json
import os
import subprocess
import tempfile
import wave

RATE = 16000

# (speaker, voice, track, text). "me" is the local user on the mic track.
SCRIPT = [
    ("me", "Rishi", "mic", "Good morning everyone, thanks for joining. Let's go through the launch checklist."),
    ("alice", "Samantha", "system", "Morning. The onboarding flow is finished and the design review signed off yesterday."),
    ("bob", "Daniel", "system", "On the backend side we still have two open bugs in the billing service."),
    ("me", "Rishi", "mic", "How long do you think those billing bugs will take to fix?"),
    ("bob", "Daniel", "system", "Probably two days. One of them needs a database migration, so I want a careful rollout."),
    ("carol", "Karen", "system", "Marketing is ready to send the announcement email on Tuesday at nine in the morning."),
    ("alice", "Samantha", "system", "If billing slips, we should move the email to Thursday instead of rushing the migration."),
    ("me", "Rishi", "mic", "Agreed. Bob, please post an update tomorrow afternoon so we can decide by Wednesday."),
    ("carol", "Karen", "system", "I will prepare both versions of the email, one for Tuesday and one for Thursday."),
    ("bob", "Daniel", "system", "Sounds good. I will share the migration plan in the channel after this call."),
    ("me", "Rishi", "mic", "Great, that is everything for today. Thanks all."),
]

GAP_SECONDS = 0.9
LEAD_SECONDS = 1.5


def synthesize(voice, text):
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as handle:
        path = handle.name
    try:
        subprocess.run(
            ["say", "-v", voice, "--file-format=WAVE", "--data-format=LEI16@16000", "-o", path, text],
            check=True,
        )
        with wave.open(path, "rb") as wav:
            assert wav.getframerate() == RATE and wav.getnchannels() == 1 and wav.getsampwidth() == 2
            samples = array.array("h", wav.readframes(wav.getnframes()))
        return samples
    finally:
        os.unlink(path)


def write_wav(path, samples):
    with wave.open(path, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        wav.writeframes(samples.tobytes())


def mix_into(track, samples, offset, gain=1.0):
    needed = offset + len(samples)
    if len(track) < needed:
        track.extend([0] * (needed - len(track)))
    for index, value in enumerate(samples):
        mixed = track[offset + index] + int(value * gain)
        track[offset + index] = max(-32768, min(32767, mixed))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True)
    parser.add_argument("--echo", action="store_true", help="leak the call into the mic at -18 dB")
    parser.add_argument("--overlap", action="store_true", help="make some turns start before the previous one ends")
    parser.add_argument("--voice", action="append", default=[], metavar="SPEAKER=VOICE",
                        help="override a speaker's `say` voice, e.g. carol=Fred (repeatable)")
    args = parser.parse_args()
    voices = dict(item.split("=", 1) for item in args.voice)
    os.makedirs(args.out, exist_ok=True)

    mic = array.array("h")
    system = array.array("h")
    expected = []
    cursor = int(LEAD_SECONDS * RATE)

    for index, (speaker, voice, track, text) in enumerate(SCRIPT):
        audio = synthesize(voices.get(speaker, voice), text)
        start = cursor
        if args.overlap and index % 4 == 3:
            start = max(0, cursor - int(0.8 * RATE))
        mix_into(mic if track == "mic" else system, audio, start)
        if args.echo and track == "system":
            mix_into(mic, audio, start + int(0.03 * RATE), gain=0.125)
        expected.append({
            "speaker": speaker,
            "track": track,
            "start": round(start / RATE, 3),
            "end": round((start + len(audio)) / RATE, 3),
            "text": text,
        })
        cursor = start + len(audio) + int(GAP_SECONDS * RATE)

    total = cursor + int(LEAD_SECONDS * RATE)
    for track in (mic, system):
        track.extend([0] * (total - len(track)))

    write_wav(os.path.join(args.out, "microphone.wav"), mic)
    write_wav(os.path.join(args.out, "system.wav"), system)
    with open(os.path.join(args.out, "expected.json"), "w") as handle:
        json.dump({"echo": args.echo, "overlap": args.overlap, "turns": expected}, handle, indent=2)
    print(f"wrote {args.out} ({total / RATE:.1f} s, {len(expected)} turns, "
          f"{len({t['speaker'] for t in expected if t['track'] == 'system'})} remote speakers)")


if __name__ == "__main__":
    main()
