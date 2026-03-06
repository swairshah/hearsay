# Hearsay Transcription Correction Fine-Tuning

Fine-tune Qwen3-0.6B to correct ASR transcription output for Hearsay.

## Task

Given raw speech-to-text output (possibly with filler words, bad punctuation, spelling errors), produce clean corrected text. Optionally accepts a user prompt for domain-specific context (e.g., "Technical terms: XcodeGen, SwiftUI").

## Data Format

Every `.jsonl` file in `data/` must match the schema in `dataset/schema.py`:

```json
{"raw": "so um i was like thinking...", "corrected": "So I was thinking...", "prompt": "optional context"}
```

- `raw`: ASR transcription output (required)
- `corrected`: expected clean text (required)
- `prompt`: optional user context for domain-specific corrections

## Quick Start

```bash
cd finetune

# 1. Generate training data using Claude
just generate
# or: uv run dataset/generate_data.py --multiplier 5

# 2. Validate data
just validate

# 3. Prepare for training (apply chat template, split)
just prepare

# 4. Evaluate base model before training
just eval
# or: uv run eval.py --no-judge  (skip LLM scoring, just side-by-side)
```

## Pipeline

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐     ┌─────────┐
│ generate_data│ ──→ │ validate     │ ──→ │ prepare_data │ ──→ │ train   │
│ (Claude)     │     │ (Pydantic)   │     │ (chat tmpl)  │     │ (SFT)   │
└─────────────┘     └──────────────┘     └──────────────┘     └─────────┘
                                                                    │
                                                               ┌────▼────┐
                                                               │  eval   │
                                                               └─────────┘
```

## File Structure

```
finetune/
├── dataset/
│   ├── schema.py           # Pydantic schema (single source of truth)
│   ├── generate_data.py    # Generate training data via Claude
│   ├── prepare_data.py     # Apply chat template, dedup, split
│   └── validate_schema.py  # Validate all JSONL files
├── configs/
│   └── sft.yaml            # SFT hyperparameters
├── data/                   # Training JSONL files
├── evals/                  # Raw transcripts for evaluation
├── eval.py                 # Evaluate: Claude vs local model
├── pyproject.toml          # Dependencies
├── Justfile                # Common commands
└── README.md               # This file
```

## Training (requires GPU)

Two options:

### Option A: TRL + LoRA (same as QMD pipeline)
Training uses the same stack as the QMD fine-tuning pipeline (TRL + LoRA + PEFT).
Will reuse the `train.py` pattern from QMD once we have enough data.

### Option B: Unsloth (recommended for small models)
[Unsloth](https://unsloth.ai/docs/models/qwen3.5/fine-tune) supports Qwen3.5
fine-tuning with 1.5x faster training and 50% less VRAM:

- **Qwen3.5-0.8B**: only **3GB VRAM** with bf16 LoRA (free Colab!)
- Built-in GGUF export (`model.save_pretrained_gguf("dir", tokenizer, "q4_k_m")`)
- Supports SFT and GRPO
- Free Colab notebooks available for 0.8B, 2B, 4B

```python
from unsloth import FastModel
model, tokenizer = FastModel.from_pretrained(
    model_name="unsloth/Qwen3.5-0.8B",
    max_seq_length=2048,
    load_in_4bit=False,
    load_in_16bit=True,
    full_finetuning=False,
)
# ... attach LoRA, train with SFTTrainer, then:
model.save_pretrained_gguf("output", tokenizer, quantization_method="q4_k_m")
```

**Note:** Qwen3.5-0.8B has reasoning disabled by default (good for our use case —
we want direct correction, not chain-of-thought). It also supports 256K context
and 201 languages.

## Model Candidates

| Model | Params | GGUF Size (Q4) | Notes |
|-------|--------|-----------------|-------|
| Qwen3-0.6B | 0.6B | ~484 MB | Current baseline, works well |
| **Qwen3.5-0.8B** | 0.8B | ~500 MB | **Newer, better, Unsloth support** |
| SmolLM2-360M | 360M | ~250 MB | Smaller but less capable |
