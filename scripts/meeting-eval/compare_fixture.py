#!/usr/bin/env python3
"""Score the live-style and accurate-pass speaker labelling on a synthetic fixture.

Both start from the same utterances: expected call turns closer together than
the live segmenter's ~0.7 s hangover are merged into one, as the app would hear
them. Then:

- live: one label per utterance from streaming Sortformer (what the app does),
- accurate: a label per word from whole-recording diarization, split at changes
  (accurate_pass.py).

    scripts/meeting-eval/compare_fixture.py /tmp/fixture \\
        --fluidaudio …/fluidaudiocli --utterwords …/utterwords
"""

import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import accurate_pass as ap  # noqa: E402

HANGOVER = 0.72  # SpeechSegmenter: 24 silent 30 ms frames end an utterance


def live_ranges(turns, track):
    ranges = []
    for turn in sorted((t for t in turns if t["track"] == track), key=lambda t: t["start"]):
        if ranges and turn["start"] - ranges[-1][1] < HANGOVER:
            ranges[-1][1] = max(ranges[-1][1], turn["end"])
        else:
            ranges.append([turn["start"], turn["end"]])
    return ranges


def sortformer(fluidaudio, wav, out_json):
    ap.run([fluidaudio, "sortformer", wav, "--output", out_json])
    return [{"speaker": str(s["speakerIndex"]), "start": s["startTimeSeconds"], "end": s["endTimeSeconds"]}
            for s in json.load(open(out_json))["segments"]]


def score(fixture, document_path):
    out = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "score.py"),
                          os.path.join(fixture, "expected.json"), document_path, "--json"],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("fixture")
    parser.add_argument("--fluidaudio", required=True)
    parser.add_argument("--utterwords", required=True)
    args = parser.parse_args()
    out = os.path.join(args.fixture, "compare")
    os.makedirs(out, exist_ok=True)

    turns = json.load(open(os.path.join(args.fixture, "expected.json")))["turns"]
    system_wav = os.path.join(args.fixture, "system.wav")
    mic_wav = os.path.join(args.fixture, "microphone.wav")
    system_utts, _, _ = ap.utterance_words(args.utterwords, system_wav, live_ranges(turns, "system"),
                                           os.path.join(out, "system-words.json"))
    mic_utts, _, _ = ap.utterance_words(args.utterwords, mic_wav, live_ranges(turns, "mic"),
                                        os.path.join(out, "mic-words.json"))

    # Live-style: one streaming-diarizer label per utterance.
    streaming = sortformer(args.fluidaudio, system_wav, os.path.join(out, "sortformer.json"))
    live_segments = []
    for utterance in system_utts:
        votes = {}
        for turn in streaming:
            seconds = min(utterance["end"], turn["end"]) - max(utterance["start"], turn["start"])
            if seconds > 0:
                votes[turn["speaker"]] = votes.get(turn["speaker"], 0) + seconds
        label = f"s{int(max(votes, key=votes.get)) + 1}" if votes else "them"
        live_segments.append({"speakerID": label, "channel": "system", "start": utterance["start"],
                              "end": utterance["end"], "text": utterance["text"], "originalText": utterance["text"]})
    live_segments += [{"speakerID": "me", "channel": "microphone", "start": u["start"], "end": u["end"],
                       "text": u["text"], "originalText": u["text"]} for u in mic_utts]
    live = {"segments": live_segments, "speakers": []}
    json.dump(live, open(os.path.join(out, "live.json"), "w"), indent=2)

    # Accurate pass.
    offline, _ = ap.diarize(args.fluidaudio, system_wav, os.path.join(out, "offline.json"))
    lines, speakers = ap.assemble(live, mic_utts, system_utts, offline)
    json.dump(ap.to_document(live, lines, speakers), open(os.path.join(out, "accurate.json"), "w"), indent=2)

    rows = []
    for name in ("live", "accurate"):
        report = score(args.fixture, os.path.join(out, f"{name}.json"))
        rows.append((name, report["speakers"]["accuracy"], len(report["speakers"]["predicted_labels"]),
                     len(report["speakers"]["true"]), report["segments"]["visible"], report["wer"]["overall"]))
    print(f"{'':10} {'speaker acc':>11} {'labels':>7} {'true':>5} {'lines':>6} {'WER':>6}")
    for name, accuracy, labels, true, lines_count, wer in rows:
        print(f"{name:10} {accuracy:11.1%} {labels:7d} {true:5d} {lines_count:6d} {wer:6.1%}")
    print(f"utterances: {len(system_utts)} call, {len(mic_utts)} mic, from {len(turns)} spoken turns")


if __name__ == "__main__":
    main()
