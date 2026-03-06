#!/usr/bin/env python3
"""
Export a merged HuggingFace model to GGUF format for local inference.

Converts the merged model to MLX format for use with mlx-lm.

Usage:
    # After downloading merged model from Modal:
    modal volume get hearsay-finetune outputs/merged ./outputs/merged

    # Convert to MLX format
    python3 export_gguf.py outputs/merged -o outputs/mlx-4bit

    # Test the exported model
    uv run eval.py --local-model outputs/mlx-4bit --no-judge
"""

import argparse
import subprocess
import sys
from pathlib import Path


def export_mlx(model_path: str, output_path: str, bits: int = 4):
    """Convert HuggingFace model to MLX quantized format."""
    print(f"Converting {model_path} → {output_path} ({bits}-bit)")
    cmd = [
        sys.executable, "-m", "mlx_lm.convert",
        "--hf-path", model_path,
        "--mlx-path", output_path,
        "-q",
        "--q-bits", str(bits),
    ]
    print(f"  Running: {' '.join(cmd)}")
    result = subprocess.run(cmd)
    if result.returncode != 0:
        print("Conversion failed!")
        sys.exit(1)
    print(f"  Done! MLX model at: {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Export model to MLX format")
    parser.add_argument("model_path", help="Path to merged HF model")
    parser.add_argument("-o", "--output", default=None, help="Output path")
    parser.add_argument("--bits", type=int, default=4, choices=[4, 8], help="Quantization bits")
    args = parser.parse_args()

    if args.output is None:
        args.output = f"{args.model_path}-mlx-{args.bits}bit"

    export_mlx(args.model_path, args.output, args.bits)

    # Quick sanity check
    print(f"\nTo test: uv run eval.py --local-model {args.output} --no-judge")


if __name__ == "__main__":
    main()
