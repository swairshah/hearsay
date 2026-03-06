#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["pydantic>=2.0"]
# ///
"""Validate all JSONL files in data/ against the strict schema."""

import glob
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
from dataset.schema import load_examples


def main():
    files = sorted(glob.glob("data/*.jsonl"))
    if not files:
        print("No JSONL files found in data/")
        sys.exit(1)

    total = 0
    errors = 0
    for f in files:
        try:
            examples = load_examples(f)
            total += len(examples)
            with_prompt = sum(1 for ex in examples if ex.prompt)
            print(f"  ✓ {Path(f).name}: {len(examples)} examples ({with_prompt} with prompt)")
        except ValueError as e:
            print(f"  ✗ {Path(f).name}: {e}")
            errors += 1

    print(f"\nTotal: {total} examples across {len(files)} files")
    if errors:
        print(f"FAILED: {errors} file(s) had errors")
        sys.exit(1)
    else:
        print("All files valid ✓")


if __name__ == "__main__":
    main()
