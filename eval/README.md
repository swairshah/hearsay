# Transcription Correction Eval

Compares transcription cleanup quality between Claude Sonnet (gold standard) and a local small model (Qwen3-0.6B via llama.cpp).

## Structure

```
eval/
├── prompt.txt              # Shared system prompt (edit to tune behavior)
├── eval.sh                 # Run the evaluation
├── transcripts/            # Raw ASR output (one per .txt file)
│   ├── coding_discussion.txt
│   ├── technical_terms.txt
│   └── ...
└── results/                # Generated side-by-side comparisons
    ├── coding_discussion.md
    └── ...
```

## Usage

```bash
cd eval

# Run all transcripts
./eval.sh

# Run a single transcript
./eval.sh transcripts/coding_discussion.txt

# Add your own
echo "your raw transcript here" > transcripts/my_test.txt
./eval.sh transcripts/my_test.txt
```

## Adding Real Transcripts

The best way to collect samples is to use Hearsay normally and copy the raw
output from the history before any correction is applied. Paste each one into
a separate `.txt` file in `transcripts/`.

## Changing the Prompt

Edit `prompt.txt` — it's used identically for both Claude and the local model,
so you get a fair comparison.

## Changing the Local Model

Edit the `LOCAL_MODEL` variable in `eval.sh`. Options:
- `bartowski/Qwen_Qwen3-0.6B-GGUF:Q4_K_M` (current, ~484MB)
- `bartowski/SmolLM2-360M-Instruct-GGUF:Q4_K_M` (~250MB)
- `bartowski/SmolLM2-135M-Instruct-GGUF:Q8_0` (~145MB)
