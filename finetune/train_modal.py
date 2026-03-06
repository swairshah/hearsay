#!/usr/bin/env python3
"""
Fine-tune Qwen3-0.6B for transcription correction on Modal.

Usage:
    # Upload data + launch training
    modal run train_modal.py

    # Dry run (print config, don't train)
    modal run train_modal.py --dry-run

    # Download results after training
    modal volume get hearsay-finetune outputs/ ./outputs/
"""

import modal

# ─── Modal infrastructure ────────────────────────────────────────────────────

volume = modal.Volume.from_name("hearsay-finetune", create_if_missing=True)

image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install(
        "torch",
        "transformers>=4.45.0",
        "trl>=0.12.0",
        "peft>=0.7.0",
        "accelerate>=0.24.0",
        "datasets",
        "bitsandbytes",
        "pyyaml",
        "huggingface_hub>=0.20.0",
        "sentencepiece",
    )
)

app = modal.App("hearsay-finetune", image=image)

VOL = "/data"


# ─── Training ────────────────────────────────────────────────────────────────

@app.function(
    gpu="T4",
    volumes={VOL: volume},
    timeout=3600,
    secrets=[modal.Secret.from_name("my-huggingface-secret")],
)
def train(config: dict):
    import os
    import torch
    import yaml
    from datasets import load_dataset
    from peft import LoraConfig, PeftModel
    from transformers import AutoTokenizer, AutoModelForCausalLM
    from trl import SFTTrainer, SFTConfig

    base_model = config["model"]["base"]
    output_dir = f"{VOL}/outputs/sft"

    print(f"=" * 60)
    print(f"Base model : {base_model}")
    print(f"Output dir : {output_dir}")
    print(f"GPU        : {torch.cuda.get_device_name(0)}")
    props = torch.cuda.get_device_properties(0)
    vram = getattr(props, 'total_memory', getattr(props, 'total_mem', 0))
    print(f"VRAM       : {vram / 1e9:.1f} GB")
    print(f"=" * 60)

    # ── Load dataset ──────────────────────────────────────────────────────
    train_file = f"{VOL}/train_data/train.jsonl"
    print(f"\nLoading dataset: {train_file}")
    dataset = load_dataset("json", data_files=train_file, split="train")
    dataset = dataset.shuffle(seed=42)

    eval_split = config["dataset"]["eval_split"]
    split = dataset.train_test_split(test_size=eval_split, seed=42)
    train_dataset = split["train"]
    eval_dataset = split["test"]
    print(f"  Train: {len(train_dataset)}, Eval: {len(eval_dataset)}")

    # ── Tokenizer ─────────────────────────────────────────────────────────
    tokenizer = AutoTokenizer.from_pretrained(base_model)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    # ── LoRA ──────────────────────────────────────────────────────────────
    lora_cfg = config["lora"]
    peft_config = LoraConfig(
        r=lora_cfg["rank"],
        lora_alpha=lora_cfg["alpha"],
        lora_dropout=lora_cfg["dropout"],
        bias="none",
        task_type="CAUSAL_LM",
        target_modules=lora_cfg["target_modules"],
    )

    # ── Training config ───────────────────────────────────────────────────
    tcfg = config["training"]
    sft_config = SFTConfig(
        output_dir=output_dir,
        num_train_epochs=tcfg["epochs"],
        per_device_train_batch_size=tcfg["batch_size"],
        gradient_accumulation_steps=tcfg["gradient_accumulation_steps"],
        learning_rate=float(tcfg["learning_rate"]),
        max_length=tcfg["max_length"],
        logging_steps=1,
        save_strategy="steps",
        save_steps=tcfg["save_steps"],
        save_total_limit=tcfg["save_total_limit"],
        eval_strategy="steps",
        eval_steps=tcfg.get("eval_steps", 50),
        warmup_ratio=tcfg["warmup_ratio"],
        lr_scheduler_type=tcfg["lr_scheduler"],
        bf16=True,
        report_to="none",
    )

    # ── Train ─────────────────────────────────────────────────────────────
    print("\nInitializing trainer...")
    trainer = SFTTrainer(
        model=base_model,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        args=sft_config,
        peft_config=peft_config,
        processing_class=tokenizer,
    )

    print("Starting training...")
    trainer.train()

    # Save LoRA adapter
    trainer.save_model()
    tokenizer.save_pretrained(output_dir)
    print(f"\nLoRA adapter saved to {output_dir}")

    # ── Merge LoRA into base ──────────────────────────────────────────────
    print("Merging LoRA weights into base model...")
    base = AutoModelForCausalLM.from_pretrained(
        base_model, torch_dtype=torch.bfloat16, device_map="auto",
    )
    model = PeftModel.from_pretrained(base, output_dir)
    merged = model.merge_and_unload()

    merged_dir = f"{VOL}/outputs/merged"
    merged.save_pretrained(merged_dir, safe_serialization=True)
    tokenizer.save_pretrained(merged_dir)
    print(f"Merged model saved to {merged_dir}")

    # ── Commit volume ─────────────────────────────────────────────────────
    volume.commit()
    print("\n✅ Done! Download with:")
    print("  modal volume get hearsay-finetune outputs/merged/ ./outputs/merged/")


# ─── Local entrypoint ────────────────────────────────────────────────────────

@app.local_entrypoint()
def main(dry_run: bool = False):
    """Upload training data to Modal volume and launch training."""
    import yaml
    from pathlib import Path

    config_path = Path(__file__).parent / "configs" / "sft.yaml"
    data_dir = Path(__file__).parent / "data" / "train"

    with open(config_path) as f:
        config = yaml.safe_load(f)

    if dry_run:
        print("Config:")
        print(yaml.dump(config, default_flow_style=False))
        print(f"Train data: {data_dir}")
        train_file = data_dir / "train.jsonl"
        if train_file.exists():
            with open(train_file) as f:
                n = sum(1 for _ in f)
            print(f"  {n} training examples")
        else:
            print("  ⚠ No training data! Run: just prepare")
        return

    # Check training data exists
    train_file = data_dir / "train.jsonl"
    if not train_file.exists():
        print(f"Error: {train_file} not found")
        print("Run: just data  (or: just generate && just prepare)")
        return

    with open(train_file) as f:
        n_train = sum(1 for _ in f)
    print(f"Training examples: {n_train}")

    # Upload to volume (force overwrite by removing old files first)
    print("Uploading to Modal volume...")
    try:
        volume.remove_file("train_data", recursive=True)
    except Exception:
        pass  # Doesn't exist yet
    with volume.batch_upload(force=True) as batch:
        for f in data_dir.iterdir():
            if f.suffix in (".jsonl", ".json"):
                batch.put_file(str(f), f"train_data/{f.name}")
                print(f"  ↑ {f.name}")

    print(f"\nLaunching training on Modal...")
    print(f"  Model  : {config['model']['base']}")
    print(f"  Epochs : {config['training']['epochs']}")
    print(f"  LoRA r : {config['lora']['rank']}")
    print(f"  GPU    : T4")
    print()

    train.remote(config)
