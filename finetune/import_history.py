#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Import real transcripts from Hearsay history into eval test files.

Selects transcripts that would most benefit from correction (filler words,
repetitions, missing punctuation) and writes them to evals/.

Usage:
    uv run import_history.py              # Import top 20 candidates
    uv run import_history.py --count 50   # Import more
    uv run import_history.py --all        # Import everything >30 chars
"""

import argparse
import json
import os
import re
from pathlib import Path


HISTORY_PATH = os.path.expanduser(
    "~/Library/Application Support/Hearsay/History/chunk_0000.json"
)


def score_transcript(text: str) -> int:
    """Score how much a transcript would benefit from correction. Higher = more issues."""
    if len(text) < 30:
        return -1  # too short to be useful

    score = 0

    # Filler words
    fillers = len(re.findall(r'\b(um|uh|ah|er)\b', text, re.I))
    score += fillers * 2

    # Repeated words ("the the", "is is")
    repeats = len(re.findall(r'\b(\w+) \1\b', text))
    score += repeats * 2

    # Hedge word "like" used as filler
    likes = len(re.findall(r'\blike\b', text, re.I))
    score += likes

    # "you know" filler
    score += len(re.findall(r'\byou know\b', text, re.I)) * 2

    # Missing sentence-ending punctuation
    if not any(c in text for c in '.!?'):
        score += 1

    # Longer transcripts have more opportunity for issues
    if len(text) > 200:
        score += 1

    return score


def main():
    parser = argparse.ArgumentParser(description="Import Hearsay history for eval")
    parser.add_argument("--count", type=int, default=20, help="Number of transcripts to import")
    parser.add_argument("--all", action="store_true", help="Import all transcripts >30 chars")
    parser.add_argument("--min-score", type=int, default=0, help="Minimum correction-need score")
    parser.add_argument("--output", type=str, default="evals", help="Output directory")
    args = parser.parse_args()

    if not os.path.exists(HISTORY_PATH):
        print(f"History file not found: {HISTORY_PATH}")
        return

    with open(HISTORY_PATH) as f:
        data = json.load(f)

    # Score and filter
    scored = []
    for entry in data:
        text = entry.get("text", "").strip()
        s = score_transcript(text)
        if s >= args.min_score:
            scored.append((s, text, entry.get("id", "unknown")))

    scored.sort(key=lambda x: -x[0])

    if not args.all:
        scored = scored[:args.count]

    # Write eval files
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Clear old auto-imported files
    for f in output_dir.glob("hist_*.txt"):
        f.unlink()

    written = 0
    for i, (score, text, entry_id) in enumerate(scored):
        if len(text) < 30:
            continue
        filename = output_dir / f"hist_{i:03d}.txt"
        filename.write_text(text)
        written += 1
        preview = text[:80] + "..." if len(text) > 80 else text
        print(f"  [{score:2d}] {filename.name}: {preview}")

    print(f"\nImported {written} transcripts → {output_dir}/")


if __name__ == "__main__":
    main()
