#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "dspy>=3.0",
#     "pydantic>=2.0",
# ]
# ///
"""Generate synthetic training data using DSPy.

Takes seed transcripts (from evals/ or Hearsay history) and generates
corrected versions + ASR-error variations. The correction ONLY subtracts —
removes filler words, fixes punctuation/capitalization/spelling, deduplicates.
It NEVER adds words, rephrases, or changes the speaker's vocabulary.

Usage:
    uv run dataset/generate_data.py                           # from evals/*.txt
    uv run dataset/generate_data.py --input data/seeds.jsonl  # from JSONL
    uv run dataset/generate_data.py --model deepseek/deepseek-chat
"""

import argparse
import glob
import json
import os
import sys
from pathlib import Path

import dspy
from pydantic import ValidationError

sys.path.insert(0, str(Path(__file__).parent.parent))
from dataset.schema import TrainingExample

DEFAULT_MODEL = "deepseek/deepseek-chat"


# ─── DSPy Signatures ─────────────────────────────────────────────────────────

class CorrectTranscript(dspy.Signature):
    """Fix a raw speech transcript. ONLY subtract — remove filler words
    (um, uh, ah, like, you know, so, basically, right), false starts,
    and repeated words. Fix punctuation, capitalization, and spelling.
    NEVER add words, rephrase, or change the speaker's vocabulary.
    The corrected text must use only words the speaker actually said."""

    raw_transcript: str = dspy.InputField(desc="raw ASR transcript")
    corrected: str = dspy.OutputField(desc="corrected transcript using only the speaker's original words")


class FormatAsStructuredList(dspy.Signature):
    """Reformat a transcript into a structured numbered list.
    ONLY apply when the speaker is clearly listing items, steps, or tasks.
    Use the speaker's exact words for each list item — do NOT rephrase.
    Also remove filler words, fix punctuation, and deduplicate."""

    raw_transcript: str = dspy.InputField(desc="raw ASR transcript containing a list or sequence of items")
    structured: str = dspy.OutputField(desc="numbered list using the speaker's own words, one item per line")


class ExtractTechnicalTerms(dspy.Signature):
    """Extract technical terms, API names, tool names, library names,
    or domain-specific jargon from a transcript. Return only terms
    that would need special attention for correct spelling/capitalization."""

    raw_transcript: str = dspy.InputField(desc="raw ASR transcript")
    terms: str = dspy.OutputField(desc="comma-separated list of technical terms found, or 'none' if no technical terms")


class GenerateASRVariation(dspy.Signature):
    """Generate a realistic ASR (speech-to-text) error variation of a
    clean transcript. Introduce typical ASR mistakes:
    - Remove some punctuation and capitalization
    - Insert filler words (um, uh, ah, like, you know) at natural positions
    - Add word repetitions or false starts ("the the", "I I")
    - Occasionally create run-on sentences (remove periods)
    Make it sound like a real person speaking with natural disfluencies."""

    clean_transcript: str = dspy.InputField(desc="the clean/corrected transcript")
    variation: str = dspy.OutputField(desc="a realistic ASR transcript with natural speech errors")


class HasListContent(dspy.Signature):
    """Determine if a transcript contains sequential items, steps,
    instructions, or an enumerated list that could be formatted
    as a structured numbered list."""

    raw_transcript: str = dspy.InputField(desc="raw ASR transcript")
    has_list: bool = dspy.OutputField(desc="true if the transcript contains list-like content")


class HasTechnicalContent(dspy.Signature):
    """Determine if a transcript contains technical terms, API names,
    programming concepts, tool names, or domain-specific jargon."""

    raw_transcript: str = dspy.InputField(desc="raw ASR transcript")
    has_technical: bool = dspy.OutputField(desc="true if the transcript contains technical content")


# ─── Generation Pipeline ─────────────────────────────────────────────────────

class GenerateTrainingData(dspy.Module):
    """Generate training examples from a raw transcript."""

    def __init__(self):
        self.correct = dspy.Predict(CorrectTranscript)
        self.format_list = dspy.Predict(FormatAsStructuredList)
        self.extract_terms = dspy.Predict(ExtractTechnicalTerms)
        self.generate_variation = dspy.Predict(GenerateASRVariation)
        self.check_list = dspy.Predict(HasListContent)
        self.check_technical = dspy.Predict(HasTechnicalContent)

    def forward(self, raw_transcript: str) -> list[dict]:
        examples = []

        # 1. Casual correction (always)
        casual = self.correct(raw_transcript=raw_transcript)
        examples.append({
            "raw": raw_transcript,
            "corrected": casual.corrected,
            "prompt": "Keep it casual",
        })

        # 2. Generate 2 ASR-error variations → same corrected output
        for _ in range(2):
            var = self.generate_variation(clean_transcript=casual.corrected)
            examples.append({
                "raw": var.variation,
                "corrected": casual.corrected,
                "prompt": "Keep it casual",
            })

        # 3. Structured list (if applicable)
        has_list = self.check_list(raw_transcript=raw_transcript)
        if has_list.has_list:
            structured = self.format_list(raw_transcript=raw_transcript)
            examples.append({
                "raw": raw_transcript,
                "corrected": structured.structured,
                "prompt": "Format as a structured list",
            })

        # 4. Technical terms (if applicable)
        has_tech = self.check_technical(raw_transcript=raw_transcript)
        if has_tech.has_technical:
            terms = self.extract_terms(raw_transcript=raw_transcript)
            if terms.terms and terms.terms.lower() != "none":
                examples.append({
                    "raw": raw_transcript,
                    "corrected": casual.corrected,
                    "prompt": f"Preserve technical terms: {terms.terms}",
                })

        return examples


# ─── Main ─────────────────────────────────────────────────────────────────────

def make_lm(model: str) -> dspy.LM:
    api_key = os.environ.get("OPENROUTER_API_KEY")
    if not api_key:
        print("Error: OPENROUTER_API_KEY not set")
        sys.exit(1)
    return dspy.LM(
        f"openrouter/{model}",
        api_key=api_key,
        cache=False,
        temperature=0.7,
        max_tokens=4096,
    )


def main():
    parser = argparse.ArgumentParser(description="Generate training data")
    parser.add_argument(
        "--input", type=str, default=None,
        help="Input JSONL (needs 'raw' field) or glob for .txt files. Default: evals/*.txt",
    )
    parser.add_argument(
        "--output", type=str, default="data/generated.jsonl",
        help="Output JSONL file",
    )
    parser.add_argument(
        "--model", type=str, default=DEFAULT_MODEL,
        help=f"Model for generation (default: {DEFAULT_MODEL})",
    )
    args = parser.parse_args()

    # Load seed transcripts
    seeds: list[str] = []
    if args.input:
        if args.input.endswith(".jsonl"):
            with open(args.input) as f:
                for line in f:
                    line = line.strip()
                    if line:
                        obj = json.loads(line)
                        seeds.append(obj.get("raw", obj.get("text", "")))
        else:
            for fp in sorted(glob.glob(args.input)):
                seeds.append(Path(fp).read_text().strip())
    else:
        eval_files = sorted(glob.glob("evals/*.txt"))
        if eval_files:
            print(f"Using {len(eval_files)} transcripts from evals/")
            for fp in eval_files:
                seeds.append(Path(fp).read_text().strip())
        else:
            print("No eval transcripts found. Run: python3 import_history.py")
            sys.exit(1)

    if not seeds:
        print("No seed transcripts found")
        sys.exit(1)

    # Set up DSPy
    lm = make_lm(args.model)
    dspy.configure(lm=lm)
    pipeline = GenerateTrainingData()

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    all_examples = []
    for i, seed in enumerate(seeds):
        print(f"[{i+1}/{len(seeds)}] Generating from: {seed[:60]}...")
        try:
            examples = pipeline(raw_transcript=seed)
            # Validate each example
            valid = []
            for ex in examples:
                try:
                    validated = TrainingExample.model_validate(ex)
                    valid.append(validated.model_dump(exclude_none=True))
                except ValidationError as e:
                    print(f"  ⚠ Skipping invalid: {e}")
            all_examples.extend(valid)
            print(f"  ✓ Generated {len(valid)} examples")
        except Exception as e:
            print(f"  ✗ Error: {e}")

    with open(output_path, "w") as f:
        for ex in all_examples:
            f.write(json.dumps(ex) + "\n")

    print(f"\n=== Done ===")
    print(f"Generated {len(all_examples)} examples → {output_path}")


if __name__ == "__main__":
    main()
