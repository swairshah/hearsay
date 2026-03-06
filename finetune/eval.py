#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "dspy>=3.0",
#     "mlx-lm>=0.20.0",
# ]
# ///
"""
Evaluate transcription correction quality.

Cloud + judge via DSPy (OpenRouter). Local model via mlx-lm Python API.

Usage:
    uv run eval.py                                       # all evals/*.txt
    uv run eval.py evals/hist_018.txt evals/hist_003.txt  # specific files
    uv run eval.py --no-judge                            # skip scoring
    uv run eval.py --local-model mlx-community/Qwen3-0.6B-8bit
    uv run eval.py --cloud-model deepseek/deepseek-chat
"""

import argparse
import glob
import json
import os
import re
import sys
from pathlib import Path

import dspy

# ─── Config ───────────────────────────────────────────────────────────────────

DEFAULT_CLOUD_MODEL = "deepseek/deepseek-chat"
DEFAULT_JUDGE_MODEL = "deepseek/deepseek-chat"
DEFAULT_LOCAL_MODEL = "mlx-community/Qwen3-0.6B-4bit"


# ─── DSPy Signatures ─────────────────────────────────────────────────────────

class CorrectTranscript(dspy.Signature):
    """Fix punctuation, capitalization, and spelling errors in a speech transcript.
    Remove filler words (um, uh, ah, like, you know) and false starts.
    Remove duplicate/repeated words or phrases.
    Do NOT rephrase or add words the speaker didn't say.
    Preserve the speaker's original vocabulary and tone."""

    raw_transcript: str = dspy.InputField(desc="the raw ASR transcript")
    corrected: str = dspy.OutputField(desc="the corrected transcript text only")


class JudgeCorrection(dspy.Signature):
    """Evaluate a transcription correction against a reference.
    Score on four dimensions (0-10 each):
    - accuracy: Are corrections factually right? (punctuation, spelling, capitalization)
    - completeness: Did it catch all filler words, false starts, repetitions?
    - faithfulness: Did it preserve the speaker's words without rephrasing or adding?
    - fluency: Does the output read naturally?"""

    raw_transcript: str = dspy.InputField(desc="the original raw ASR transcript")
    reference: str = dspy.InputField(desc="the reference correction from a strong model")
    model_output: str = dspy.InputField(desc="the correction to evaluate")
    accuracy: int = dspy.OutputField(desc="accuracy score 0-10")
    completeness: int = dspy.OutputField(desc="completeness score 0-10")
    faithfulness: int = dspy.OutputField(desc="faithfulness score 0-10")
    fluency: int = dspy.OutputField(desc="fluency score 0-10")
    notes: str = dspy.OutputField(desc="brief explanation of scores")


# ─── Cloud LM (DSPy + OpenRouter) ────────────────────────────────────────────

def make_cloud_lm(model: str) -> dspy.LM:
    api_key = os.environ.get("OPENROUTER_API_KEY")
    if not api_key:
        print("Error: OPENROUTER_API_KEY not set")
        sys.exit(1)
    return dspy.LM(
        f"openrouter/{model}",
        api_key=api_key,
        cache=False,
        temperature=0.1,
        max_tokens=4096,
    )


# ─── Local model (mlx-lm direct API) ─────────────────────────────────────────

# System prompt shared between cloud (via DSPy signature docstring) and local
LOCAL_SYSTEM_PROMPT = (
    "Fix punctuation, capitalization, and spelling errors in a speech transcript. "
    "Remove filler words (um, uh, ah, like, you know) and false starts. "
    "Remove duplicate/repeated words or phrases. "
    "Do NOT rephrase or add words the speaker didn't say. "
    "Preserve the speaker's original vocabulary and tone. "
    "Output ONLY the corrected transcript."
)

_mlx_model = None
_mlx_tokenizer = None
_mlx_model_name = None


def load_local_model(model_name: str):
    global _mlx_model, _mlx_tokenizer, _mlx_model_name
    if _mlx_model is None or _mlx_model_name != model_name:
        from mlx_lm import load
        _mlx_model, _mlx_tokenizer = load(model_name)
        _mlx_model_name = model_name
    return _mlx_model, _mlx_tokenizer


def run_local(raw: str, model_name: str) -> str:
    from mlx_lm import generate

    model, tokenizer = load_local_model(model_name)

    messages = [
        {"role": "system", "content": LOCAL_SYSTEM_PROMPT},
        {"role": "user", "content": raw},
    ]

    prompt = tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True,
        enable_thinking=False,
    )
    response = generate(model, tokenizer, prompt=prompt, max_tokens=1024)

    # Strip any <think> tags just in case
    response = re.sub(r"<think>.*?</think>\s*", "", response, flags=re.DOTALL)
    return response.strip()


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Evaluate transcription correction")
    parser.add_argument("files", nargs="*", help="Transcript files to evaluate")
    parser.add_argument("--local-model", default=DEFAULT_LOCAL_MODEL)
    parser.add_argument("--cloud-model", default=DEFAULT_CLOUD_MODEL)
    parser.add_argument("--judge-model", default=DEFAULT_JUDGE_MODEL)
    parser.add_argument("--output", "-o", type=str, default=None)
    parser.add_argument("--no-judge", action="store_true")
    args = parser.parse_args()

    # Resolve input files
    files = args.files or sorted(glob.glob("evals/*.txt"))
    if not files:
        print("No transcript files found in evals/")
        print("Run: python3 import_history.py")
        sys.exit(1)

    # Set up LMs
    cloud_lm = make_cloud_lm(args.cloud_model)
    judge_lm = make_cloud_lm(args.judge_model) if not args.no_judge else None

    # Warm up local model
    print(f"Loading local model ({args.local_model})...", flush=True)
    load_local_model(args.local_model)
    print(f"  Ready\n")

    # DSPy predictors
    correct = dspy.Predict(CorrectTranscript)
    judge = dspy.Predict(JudgeCorrection) if not args.no_judge else None

    print(f"Cloud model : {args.cloud_model}")
    print(f"Local model : {args.local_model}")
    if not args.no_judge:
        print(f"Judge model : {args.judge_model}")
    print(f"Transcripts : {len(files)}")
    print(f"{'=' * 70}\n")

    results = []
    scored_results = []

    for i, filepath in enumerate(files):
        name = Path(filepath).stem
        raw = Path(filepath).read_text().strip()

        print(f"[{i+1}/{len(files)}] ━━━ {name} ━━━")
        print(f"  RAW: {raw[:100]}{'...' if len(raw) > 100 else ''}")

        # Cloud correction (DSPy)
        print(f"  → Cloud...", end=" ", flush=True)
        try:
            with dspy.context(lm=cloud_lm):
                cloud_result = correct(raw_transcript=raw)
            cloud_out = cloud_result.corrected
            print("done")
        except Exception as e:
            print(f"error: {e}")
            cloud_out = f"[ERROR: {e}]"

        # Local correction (mlx-lm)
        print(f"  → Local...", end=" ", flush=True)
        try:
            local_out = run_local(raw, args.local_model)
            print("done")
        except Exception as e:
            print(f"error: {e}")
            local_out = f"[ERROR: {e}]"

        print(f"  CLOUD: {cloud_out[:150]}{'...' if len(cloud_out) > 150 else ''}")
        print(f"  LOCAL: {local_out[:150]}{'...' if len(local_out) > 150 else ''}")

        result = {
            "name": name,
            "raw": raw,
            "cloud": cloud_out,
            "local": local_out,
        }

        # Judge (DSPy)
        if judge and not cloud_out.startswith("[ERROR"):
            print(f"  → Judge...", end=" ", flush=True)
            try:
                with dspy.context(lm=judge_lm):
                    scores = judge(
                        raw_transcript=raw,
                        reference=cloud_out,
                        model_output=local_out,
                    )
                result["scores"] = {
                    "accuracy": int(scores.accuracy),
                    "completeness": int(scores.completeness),
                    "faithfulness": int(scores.faithfulness),
                    "fluency": int(scores.fluency),
                    "notes": scores.notes,
                }
                total = sum(result["scores"][d] for d in
                            ["accuracy", "completeness", "faithfulness", "fluency"])
                result["scores"]["total"] = total
                scored_results.append(result)
                print(f"done — {total}/40")
                print(f"  NOTES: {scores.notes[:120]}")
            except Exception as e:
                print(f"error: {e}")

        results.append(result)
        print()

    # ── Summary ───────────────────────────────────────────────────────────────
    print(f"{'=' * 70}")
    if scored_results:
        totals = [r["scores"]["total"] for r in scored_results]
        avg = sum(totals) / len(totals)
        print(f"Average: {avg:.1f}/40 ({avg / 40 * 100:.1f}%)")
        print()
        for dim in ["accuracy", "completeness", "faithfulness", "fluency"]:
            vals = [r["scores"][dim] for r in scored_results]
            print(f"  {dim:15s}: {sum(vals) / len(vals):.1f}/10")

    if args.output:
        out = {
            "cloud_model": args.cloud_model,
            "local_model": args.local_model,
            "judge_model": args.judge_model if not args.no_judge else None,
            "results": results,
        }
        Path(args.output).write_text(json.dumps(out, indent=2))
        print(f"\nResults saved to: {args.output}")


if __name__ == "__main__":
    main()
