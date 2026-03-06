#!/bin/bash
#
# eval.sh — Compare transcription correction: Cloud model vs local Qwen3-0.6B
#
# Usage:
#   ./eval.sh                     # Run all transcripts in transcripts/
#   ./eval.sh transcripts/foo.txt # Run a single transcript
#
# Prerequisites:
#   - OPENROUTER_API_KEY env var set
#   - llama-cli installed (brew install llama.cpp)
#   - Qwen3-0.6B GGUF cached (auto-downloads on first run)
#
# Output goes to results/ directory with side-by-side comparisons.

set -euo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
TRANSCRIPTS_DIR="$EVAL_DIR/transcripts"
RESULTS_DIR="$EVAL_DIR/results"
PROMPT_FILE="$EVAL_DIR/prompt.txt"

# Model config
LOCAL_MODEL="bartowski/Qwen_Qwen3-0.6B-GGUF:Q4_K_M"
CLOUD_MODEL="google/gemini-2.5-flash-lite:free"

mkdir -p "$RESULTS_DIR"

SYSTEM_PROMPT="$(cat "$PROMPT_FILE")"

# ─── Cloud Model (OpenRouter) ────────────────────────────────────────────────

run_cloud() {
    local input="$1"
    local payload
    payload=$(jq -n \
        --arg model "$CLOUD_MODEL" \
        --arg system "$SYSTEM_PROMPT" \
        --arg input "$input" \
        '{
            model: $model,
            max_tokens: 4096,
            temperature: 0.1,
            messages: [
                { role: "system", content: $system },
                { role: "user", content: $input }
            ]
        }')

    curl -s https://openrouter.ai/api/v1/chat/completions \
        -H "content-type: application/json" \
        -H "Authorization: Bearer $OPENROUTER_API_KEY" \
        -d "$payload" \
    | jq -r '.choices[0].message.content'
}

# ─── Local Model (llama-cli) ─────────────────────────────────────────────────

run_local() {
    local input="$1"
    llama-cli \
        -hf "$LOCAL_MODEL" \
        -sys "$SYSTEM_PROMPT" \
        -p "$input" \
        -st -ngl 99 --temp 0.1 \
        --no-display-prompt \
        2>/dev/null
}

# ─── Process a single transcript ─────────────────────────────────────────────

process_transcript() {
    local file="$1"
    local name
    name="$(basename "$file" .txt)"
    local result_file="$RESULTS_DIR/${name}.md"

    local raw
    raw="$(cat "$file")"

    echo "━━━ Processing: $name ━━━"

    echo "  → Running cloud model ($CLOUD_MODEL)..."
    local cloud_out
    cloud_out="$(run_cloud "$raw")"

    echo "  → Running local model ($LOCAL_MODEL)..."
    local local_out
    local_out="$(run_local "$raw")"

    # Write result file
    cat > "$result_file" <<EOF
# Eval: $name

## Raw Transcript
$raw

## Cloud Model ($CLOUD_MODEL)
$cloud_out

## Local Model ($LOCAL_MODEL)
$local_out
EOF

    echo "  ✓ Saved to results/${name}.md"
    echo ""

    # Also print side-by-side to terminal
    echo "  ┌─ RAW:"
    echo "  │ $raw"
    echo "  ├─ CLOUD:"
    echo "  │ $cloud_out"
    echo "  ├─ LOCAL:"
    echo "  │ $local_out"
    echo "  └─────────────────────────"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

if [ $# -gt 0 ]; then
    for f in "$@"; do
        process_transcript "$f"
    done
else
    files=("$TRANSCRIPTS_DIR"/*.txt)
    if [ ${#files[@]} -eq 0 ] || [ ! -e "${files[0]}" ]; then
        echo "No transcripts found in $TRANSCRIPTS_DIR/"
        echo ""
        echo "Add .txt files with raw transcriptions, e.g.:"
        echo "  echo 'so um i was like thinking we should refactor this' > transcripts/sample1.txt"
        exit 1
    fi

    echo "Found ${#files[@]} transcript(s)"
    echo ""

    for f in "${files[@]}"; do
        process_transcript "$f"
    done
fi

echo "━━━ Done! Results in eval/results/ ━━━"
