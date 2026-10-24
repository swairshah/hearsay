#!/usr/bin/env python3
"""Score a Hearsay meeting transcript against a fixture's ground truth.

    hearsay meetings show latest --format json > /tmp/meeting.json
    scripts/meeting-eval/score.py /tmp/fixture/expected.json /tmp/meeting.json

Reports word error rate (overall and per track), speaker attribution
accuracy for the call side (after mapping diarizer labels to true speakers),
and whether call audio leaking into the mic was suppressed.
"""

import argparse
import json
import re
import sys
from collections import defaultdict


def words(text):
    return re.findall(r"[a-z0-9']+", text.lower())


def wer(reference, hypothesis):
    ref, hyp = words(reference), words(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0
    previous = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        current = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r != h))
        previous = current
    return previous[-1] / len(ref)


def overlap(a_start, a_end, b_start, b_end):
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("expected")
    parser.add_argument("meeting")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--max-wer", type=float, help="exit 1 if overall WER is above this")
    parser.add_argument("--min-speaker-accuracy", type=float, help="exit 1 if call speaker accuracy is below this")
    args = parser.parse_args()

    expected = json.load(open(args.expected))
    meeting = json.load(open(args.meeting))
    turns = expected["turns"]
    segments = sorted(meeting["segments"], key=lambda s: s["start"])
    visible = [s for s in segments if not s.get("suppressed")]
    channel_for_track = {"mic": "microphone", "system": "system"}

    # Word error rate: compare the concatenated text per track in time order.
    report = {"wer": {}}
    for track in ("mic", "system"):
        ref = " ".join(t["text"] for t in turns if t["track"] == track)
        hyp = " ".join(s["originalText"] for s in visible if s["channel"] == channel_for_track[track])
        report["wer"][track] = round(wer(ref, hyp), 3)
    report["wer"]["overall"] = round(wer(
        " ".join(t["text"] for t in turns),
        " ".join(s["originalText"] for s in visible),
    ), 3)

    # Speaker attribution on the call side: overlap seconds between each true
    # speaker and each predicted label, then map each label to its best match.
    matrix = defaultdict(float)
    total = 0.0
    for turn in turns:
        if turn["track"] != "system":
            continue
        for segment in visible:
            if segment["channel"] != "system":
                continue
            seconds = overlap(turn["start"], turn["end"], segment["start"], segment["end"])
            if seconds > 0:
                matrix[(turn["speaker"], segment["speakerID"])] += seconds
                total += seconds
    labels = {label for (_, label) in matrix}
    mapping = {}
    for label in labels:
        best = max(((truth, sec) for (truth, l), sec in matrix.items() if l == label), key=lambda pair: pair[1])
        mapping[label] = best[0]
    correct = sum(sec for (truth, label), sec in matrix.items() if mapping.get(label) == truth)
    true_speakers = sorted({t["speaker"] for t in turns if t["track"] == "system"})
    report["speakers"] = {
        "true": true_speakers,
        "predicted_labels": sorted(labels),
        "label_mapping": mapping,
        "accuracy": round(correct / total, 3) if total else None,
        "unlabelled_call_segments": sum(1 for s in visible if s["channel"] == "system" and s["speakerID"] == "them"),
    }

    # Echo: mic segments that overlap call turns but no local turn.
    local_turns = [t for t in turns if t["track"] == "mic"]
    leaks = []
    for segment in visible:
        if segment["channel"] != "microphone":
            continue
        local = sum(overlap(t["start"], t["end"], segment["start"], segment["end"]) for t in local_turns)
        if local < 0.3 * (segment["end"] - segment["start"]):
            leaks.append(segment["originalText"])
    report["echo"] = {
        "fixture_has_echo": expected.get("echo", False),
        "suppressed_segments": sum(1 for s in segments if s.get("suppressed")),
        "leaked_segments": len(leaks),
        "leaked_text": leaks[:5],
    }
    report["segments"] = {"visible": len(visible), "expected_turns": len(turns)}

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"WER overall {report['wer']['overall']:.1%}  (mic {report['wer']['mic']:.1%}, call {report['wer']['system']:.1%})")
        s = report["speakers"]
        accuracy = "n/a" if s["accuracy"] is None else f"{s['accuracy']:.1%}"
        print(f"Call speakers: {len(s['true'])} true, labels {s['predicted_labels']}, attribution accuracy {accuracy}")
        print(f"  mapping {s['label_mapping']}  ·  unlabelled call segments {s['unlabelled_call_segments']}")
        e = report["echo"]
        print(f"Echo: fixture leak={e['fixture_has_echo']}  suppressed {e['suppressed_segments']}  leaked {e['leaked_segments']}")
        for text in e["leaked_text"]:
            print(f"  leaked: {text}")
        print(f"Segments: {report['segments']['visible']} visible for {report['segments']['expected_turns']} spoken turns")

    failed = False
    if args.max_wer is not None and report["wer"]["overall"] > args.max_wer:
        failed = True
    if args.min_speaker_accuracy is not None and (report["speakers"]["accuracy"] or 0) < args.min_speaker_accuracy:
        failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
