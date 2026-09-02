#!/usr/bin/env python3
"""Report the pinned MobileCLIP-S0 text/vision compatibility without inference."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
VERSION = "mobileclip-s0-xenova-fp16-v1"


def main() -> None:
    report = {
        "repository": "Xenova/mobileclip_s0",
        "text_embedding_version": VERSION,
        "vision_embedding_version": VERSION,
        "text_model": str(ROOT / "Backend/models/mobileclip_s0/text_model_fp16.onnx"),
        "vision_model": str(
            ROOT / "frontend/assets/models/mobileclip_s0/vision_model_fp16.onnx"
        ),
        "compatible": True,
    }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
