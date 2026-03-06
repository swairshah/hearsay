#!/usr/bin/env python3
"""
Run standard benchmarks on base vs fine-tuned model to check for regression.

Uses lm-evaluation-harness to run the same benchmarks Qwen3-0.6B was
evaluated on. Compares base model scores against fine-tuned model.

Qwen3-0.6B reported benchmarks:
  - MMLU (5-shot): ~52.8
  - GSM8K: ~59.6
  - EvalPlus/HumanEval: ~36.2
  - ARC-Challenge, HellaSwag, PIQA, WinoGrande (common sense)

We run a lightweight subset to verify fine-tuning didn't break general
capabilities. Full suite takes ~30 min on A100; quick suite ~5 min.

Usage:
    # Quick regression check (runs on Modal GPU)
    modal run eval_regression.py

    # Full benchmark suite
    modal run eval_regression.py --full

    # Local run (if you have a GPU)
    python3 eval_regression.py --local --model Qwen/Qwen3-0.6B
    python3 eval_regression.py --local --model outputs/merged

Requirements:
    pip install lm-eval  (lm-evaluation-harness)
"""

import modal

# ─── Modal setup ──────────────────────────────────────────────────────────────

volume = modal.Volume.from_name("hearsay-finetune", create_if_missing=True)

image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install(
        "lm-eval>=0.4.0",
        "torch",
        "transformers>=4.45.0",
        "accelerate",
        "datasets",
        "sentencepiece",
    )
)

app = modal.App("hearsay-eval-regression", image=image)

VOLUME_PATH = "/data"

# Quick suite: common-sense + basic reasoning (~5 min on A100)
QUICK_TASKS = [
    "arc_challenge",
    "hellaswag",
    "piqa",
    "winogrande",
]

# Full suite: adds MMLU + math (~30 min on A100)
FULL_TASKS = QUICK_TASKS + [
    "mmlu",
    "gsm8k",
]


@app.function(
    gpu="A100",
    volumes={VOLUME_PATH: volume},
    timeout=3600,
    image=image,
)
def run_benchmark(model_path: str, tasks: list[str], num_fewshot: int = 0) -> dict:
    """Run lm-eval benchmarks on a model."""
    import json
    import lm_eval

    print(f"Model: {model_path}")
    print(f"Tasks: {', '.join(tasks)}")

    results = lm_eval.simple_evaluate(
        model="hf",
        model_args=f"pretrained={model_path},trust_remote_code=True",
        tasks=tasks,
        num_fewshot=num_fewshot,
        batch_size="auto",
        device="cuda",
    )

    # Extract scores
    scores = {}
    for task, data in results["results"].items():
        # Get the primary metric for each task
        for key, val in data.items():
            if key.endswith(",none") and isinstance(val, (int, float)):
                metric_name = key.replace(",none", "")
                scores[f"{task}/{metric_name}"] = round(val * 100, 2)

    print("\n" + "=" * 60)
    print(f"Results for {model_path}:")
    print("=" * 60)
    for k, v in sorted(scores.items()):
        print(f"  {k:40s}: {v:6.2f}%")

    return scores


@app.local_entrypoint()
def main(full: bool = False, local: bool = False, model: str = None):
    """Run regression benchmarks comparing base vs fine-tuned model."""
    import json
    from pathlib import Path

    tasks = FULL_TASKS if full else QUICK_TASKS
    base_model = "Qwen/Qwen3-0.6B"

    if local:
        # Local execution
        import lm_eval

        target = model or base_model
        print(f"Running locally on: {target}")
        print(f"Tasks: {', '.join(tasks)}")

        results = lm_eval.simple_evaluate(
            model="hf",
            model_args=f"pretrained={target},trust_remote_code=True",
            tasks=tasks,
            num_fewshot=0,
            batch_size="auto",
        )

        for task, data in results["results"].items():
            print(f"\n{task}:")
            for key, val in data.items():
                if key.endswith(",none") and isinstance(val, (int, float)):
                    print(f"  {key}: {val*100:.2f}%")
        return

    # Modal execution: run base and fine-tuned
    print(f"Running {'full' if full else 'quick'} regression benchmark on Modal...")
    print(f"Tasks: {', '.join(tasks)}\n")

    # Base model
    print("1/2: Benchmarking base model...")
    base_scores = run_benchmark.remote(base_model, tasks)

    # Fine-tuned model (if exists on volume)
    finetuned_path = f"{VOLUME_PATH}/outputs/merged"
    print("\n2/2: Benchmarking fine-tuned model...")
    try:
        ft_scores = run_benchmark.remote(finetuned_path, tasks)
    except Exception as e:
        print(f"Fine-tuned model not found or error: {e}")
        print("Run training first: modal run train_modal.py")
        ft_scores = None

    # Comparison
    print("\n" + "=" * 60)
    print("REGRESSION CHECK")
    print("=" * 60)
    print(f"{'Task':<40s}  {'Base':>8s}  {'Finetuned':>8s}  {'Δ':>8s}")
    print("-" * 70)

    regressions = []
    for key in sorted(base_scores.keys()):
        base_val = base_scores[key]
        ft_val = ft_scores.get(key, None) if ft_scores else None
        if ft_val is not None:
            delta = ft_val - base_val
            flag = " ⚠️" if delta < -2.0 else ""  # Flag >2% regressions
            print(f"  {key:<38s}  {base_val:7.2f}%  {ft_val:7.2f}%  {delta:+7.2f}%{flag}")
            if delta < -2.0:
                regressions.append((key, delta))
        else:
            print(f"  {key:<38s}  {base_val:7.2f}%  {'N/A':>8s}")

    if regressions:
        print(f"\n⚠️  {len(regressions)} tasks regressed by >2%:")
        for task, delta in regressions:
            print(f"    {task}: {delta:+.2f}%")
    elif ft_scores:
        print("\n✅ No significant regressions detected!")

    # Save results
    results_path = Path("regression_results.json")
    results_path.write_text(json.dumps({
        "base_model": base_model,
        "base_scores": base_scores,
        "finetuned_scores": ft_scores,
    }, indent=2))
    print(f"\nResults saved to: {results_path}")
