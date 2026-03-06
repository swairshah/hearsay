#!/usr/bin/env python3
"""
Strict schema for Hearsay transcription correction training data.

Every JSONL file in data/ MUST conform to this format:

    {"raw": "so um i was like...", "corrected": "So I was...", "prompt": "optional context"}

- raw: the ASR transcription output (non-empty)
- corrected: the expected corrected text (non-empty)
- prompt: optional user-provided context/instructions (e.g. "technical terms: XcodeGen, SwiftUI")

There is exactly ONE format. No alternatives, no legacy fallbacks.
"""

from __future__ import annotations

import json
from pathlib import Path

from pydantic import BaseModel, ConfigDict, field_validator


class TrainingExample(BaseModel):
    """One training example in the canonical JSONL format."""

    raw: str
    corrected: str
    prompt: str | None = None

    # Optional metadata — present in some files, ignored during training.
    category: str | None = None
    source: str | None = None

    model_config = ConfigDict(extra="ignore")

    @field_validator("raw")
    @classmethod
    def raw_not_empty(cls, v: str) -> str:
        if not v or not v.strip():
            raise ValueError("raw must not be empty")
        return v

    @field_validator("corrected")
    @classmethod
    def corrected_not_empty(cls, v: str) -> str:
        if not v or not v.strip():
            raise ValueError("corrected must not be empty")
        return v


def load_examples(path: str | Path) -> list[TrainingExample]:
    """Load and validate a JSONL file. Fails loudly on any bad line."""
    path = Path(path)
    examples: list[TrainingExample] = []
    with path.open("r", encoding="utf-8") as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as e:
                raise ValueError(f"{path}:{line_num}: invalid JSON: {e}") from e
            try:
                examples.append(TrainingExample.model_validate(obj))
            except Exception as e:
                raise ValueError(f"{path}:{line_num}: {e}") from e
    return examples
