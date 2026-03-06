#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "transformers>=4.45.0",
#     "pydantic>=2.0",
#     "jinja2",
# ]
# ///
"""Prepare Hearsay transcription correction data for training.

Loads all data/*.jsonl via the strict Pydantic schema, applies the Qwen3
chat template, deduplicates by raw text, and writes train/val splits.

The prepared train files are ephemeral build artifacts — the canonical
data lives in data/*.jsonl and is always loaded through the schema.
"""

import argparse
import glob as globmod
import json
import os
import random
from pathlib import Path

from dataset.schema import TrainingExample, load_examples
from transformers import AutoTokenizer

_tokenizer = None
_tokenizer_model = None

# The system prompt used for both training and inference
SYSTEM_PROMPT = (
    "You are a transcription editor. Fix punctuation, capitalization, and spelling errors. "
    "Remove filler words (um, uh, ah, like, you know) and false starts. "
    "Do NOT rephrase or add words the speaker didn't say. "
    "Preserve the speaker's original vocabulary and tone. "
    "Output ONLY the corrected transcript."
)


def get_tokenizer():
    global _tokenizer, _tokenizer_model
    model_name = os.environ.get("HEARSAY_BASE_MODEL", "Qwen/Qwen3-0.6B")
    if _tokenizer is None or _tokenizer_model != model_name:
        _tokenizer = AutoTokenizer.from_pretrained(model_name)
        _tokenizer_model = model_name
    return _tokenizer


def format_for_training(ex: TrainingExample) -> dict:
    """Format a validated TrainingExample for SFT training."""
    tokenizer = get_tokenizer()

    # Build user message: optional prompt context + raw transcript
    user_content = ""
    if ex.prompt:
        user_content += f"[Context: {ex.prompt.strip()}]\n"
    user_content += ex.raw.strip()

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": user_content},
        {"role": "assistant", "content": ex.corrected.strip()},
    ]

    text = tokenizer.apply_chat_template(
        messages,
        tokenize=False,
        add_generation_prompt=False,
        enable_thinking=False,
    )

    # Strip empty <think> tags from the template
    text = text.replace("<think>\n\n</think>\n\n", "")

    return {
        "text": text,
        "messages": messages,
    }


def main():
    parser = argparse.ArgumentParser(description="Prepare data for training")
    parser.add_argument(
        "--input", type=str, default="data/*.jsonl",
        help="Input JSONL file(s) - supports glob patterns",
    )
    parser.add_argument(
        "--output", type=str, default="data/train",
        help="Output directory",
    )
    parser.add_argument(
        "--split", type=float, default=0.1,
        help="Validation split ratio",
    )
    parser.add_argument(
        "--seed", type=int, default=42,
        help="Shuffle seed",
    )
    args = parser.parse_args()

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Resolve input files
    if "*" in args.input:
        input_files = sorted(globmod.glob(args.input))
        if not input_files:
            print(f"Error: No files found matching: {args.input}")
            exit(1)
        print(f"Found {len(input_files)} input files")
    else:
        input_path = Path(args.input)
        if not input_path.exists():
            print(f"Error: Input file not found: {input_path}")
            exit(1)
        input_files = [str(input_path)]

    # Load all examples through strict Pydantic schema
    all_examples: list[TrainingExample] = []
    for input_file in input_files:
        examples = load_examples(input_file)
        print(f"  {Path(input_file).name}: {len(examples)} examples")
        all_examples.extend(examples)

    print(f"Loaded {len(all_examples)} examples total")

    # Deduplicate by raw text (case-insensitive)
    seen: set[str] = set()
    deduped: list[TrainingExample] = []
    for ex in all_examples:
        key = ex.raw.lower().strip()
        if key not in seen:
            seen.add(key)
            deduped.append(ex)
    if len(deduped) < len(all_examples):
        print(f"Deduplicated: {len(all_examples)} -> {len(deduped)}")
    all_examples = deduped

    # Shuffle
    random.seed(args.seed)
    random.shuffle(all_examples)

    # Format each example
    formatted = [format_for_training(ex) for ex in all_examples]

    # Split
    split_idx = int(len(formatted) * (1 - args.split))
    train_data = formatted[:split_idx]
    val_data = formatted[split_idx:]

    # Write
    for name, data in [("train.jsonl", train_data), ("val.jsonl", val_data)]:
        with open(output_dir / name, "w") as f:
            for item in data:
                f.write(json.dumps(item) + "\n")

    with open(output_dir / "train_chat.jsonl", "w") as f:
        for item in train_data:
            f.write(json.dumps({"messages": item["messages"]}) + "\n")

    # Stats
    with_prompt = sum(1 for ex in all_examples if ex.prompt)
    print(f"\n=== Summary ===")
    print(f"Total examples: {len(all_examples)}")
    print(f"With prompt/context: {with_prompt} ({100 * with_prompt / max(len(all_examples), 1):.1f}%)")
    print(f"Train: {len(train_data)}, Val: {len(val_data)}")
    print(f"Output: {output_dir}")

    dataset_info = {
        "dataset_name": "hearsay-transcription-correction",
        "train_samples": len(train_data),
        "val_samples": len(val_data),
        "with_prompt_pct": round(100 * with_prompt / max(len(all_examples), 1), 1),
        "columns": ["text", "messages"],
    }
    with open(output_dir / "dataset_info.json", "w") as f:
        json.dump(dataset_info, f, indent=2)


if __name__ == "__main__":
    main()
