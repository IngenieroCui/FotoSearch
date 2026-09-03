#!/usr/bin/env python3
"""Verify pinned MobileCLIP vision models bundled in a Flutter APK."""

from __future__ import annotations

import argparse
import sys
import zipfile
from pathlib import Path


EXPECTED_ASSETS = {
    "assets/flutter_assets/assets/models/mobileclip_s0/vision_model.onnx": 45543630,
    "assets/flutter_assets/assets/models/mobileclip_s0/vision_model_fp16.onnx": 22876479,
}


def verify(apk: Path) -> None:
    if not apk.is_file():
        raise RuntimeError(f"APK does not exist: {apk}")
    with zipfile.ZipFile(apk) as archive:
        entries = set(archive.namelist())
        for asset, expected_size in EXPECTED_ASSETS.items():
            if asset not in entries:
                raise RuntimeError(f"Missing APK asset: {asset}")
            with archive.open(asset) as source:
                actual_size = sum(len(chunk) for chunk in iter(lambda: source.read(1024 * 1024), b""))
            if actual_size != expected_size:
                raise RuntimeError(
                    f"Wrong size for {asset}: expected {expected_size}, got {actual_size}"
                )
            print(f"Verified {asset} ({actual_size} bytes)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path, help="path to the APK to verify")
    args = parser.parse_args()
    try:
        verify(args.apk)
    except (OSError, RuntimeError, zipfile.BadZipFile) as error:
        print(f"APK MobileCLIP verification failed: {error}", file=sys.stderr)
        return 1
    print("APK MobileCLIP verification passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
