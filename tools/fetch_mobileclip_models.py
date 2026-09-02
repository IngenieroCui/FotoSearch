#!/usr/bin/env python3
"""Fetch pinned Xenova MobileCLIP-S0 artifacts and verify SHA-256 checksums."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
from tempfile import NamedTemporaryFile
from urllib.request import Request, urlopen


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
VISION_MODEL_URL = (
    "https://huggingface.co/Xenova/mobileclip_s0/resolve/main/onnx/"
    "vision_model_fp16.onnx?download=true"
)
VISION_EXPECTED_SHA256 = "22b1d36ecc6837e8205aee05003440a25e1c1ee0c7e2945dbb9dd597211c59dc"
DEFAULT_VISION_DESTINATION = REPOSITORY_ROOT / (
    "frontend/assets/models/mobileclip_s0/vision_model_fp16.onnx"
)
TEXT_ARTIFACTS = (
    (
        "text_model_fp16.onnx",
        "https://huggingface.co/Xenova/mobileclip_s0/resolve/main/onnx/text_model_fp16.onnx?download=true",
        "2f74b7b3abd9f3a70dcc60115f627bbadb9534606ac841400f9841f49bf980cc",
    ),
    (
        "tokenizer.json",
        "https://huggingface.co/Xenova/mobileclip_s0/resolve/main/tokenizer.json?download=true",
        "72ed5c96db5729294468543e4bc75fce14ca63f58e37300290189ba1c1e52b85",
    ),
    (
        "tokenizer_config.json",
        "https://huggingface.co/Xenova/mobileclip_s0/resolve/main/tokenizer_config.json?download=true",
        "a7d9d24f248071b792e4a3b56ab0539c2f40eec8da56d6fd91fb3a50058acebd",
    ),
)
DEFAULT_TEXT_DIRECTORY = REPOSITORY_ROOT / "Backend/models/mobileclip_s0"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(destination: Path, url: str, expected_sha256: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        actual_hash = _sha256(destination)
        if actual_hash == expected_sha256:
            print(f"Already present and verified {destination}")
            return
        raise RuntimeError(
            f"SHA-256 mismatch for {destination.name}: expected {expected_sha256}, "
            f"got {actual_hash}. Remove the corrupt file and run this command again."
        )
    with NamedTemporaryFile(dir=destination.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
        request = Request(url, headers={"User-Agent": "FotoSearch/MC-002"})
        with urlopen(request) as response:
            while chunk := response.read(1024 * 1024):
                temporary.write(chunk)
    try:
        actual_hash = _sha256(temporary_path)
        if actual_hash != expected_sha256:
            raise RuntimeError(
                f"SHA-256 mismatch for {destination.name}: "
                f"expected {expected_sha256}, got {actual_hash}"
            )
        os.replace(temporary_path, destination)
        print(f"Downloaded and verified {destination}")
    except Exception:
        if temporary_path.exists():
            temporary_path.unlink()
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_VISION_DESTINATION)
    parser.add_argument(
        "--text",
        action="store_true",
        help="download text_model_fp16.onnx plus the matching Xenova tokenizer files",
    )
    args = parser.parse_args()
    if args.text:
        for filename, url, sha256 in TEXT_ARTIFACTS:
            fetch(DEFAULT_TEXT_DIRECTORY / filename, url, sha256)
    else:
        fetch(args.output, VISION_MODEL_URL, VISION_EXPECTED_SHA256)


if __name__ == "__main__":
    main()
