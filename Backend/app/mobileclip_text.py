"""MobileCLIP-S0 text encoder backed directly by the pinned Xenova ONNX export."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Sequence

import numpy as np


MOBILECLIP_TEXT_EMBEDDING_VERSION = "mobileclip-s0-xenova-fp16-v1"
MODEL_DIRECTORY = Path(__file__).resolve().parent.parent / "models" / "mobileclip_s0"
DEFAULT_MODEL_PATH = MODEL_DIRECTORY / "text_model_fp16.onnx"
DEFAULT_TOKENIZER_PATH = MODEL_DIRECTORY / "tokenizer.json"
DEFAULT_TOKENIZER_CONFIG_PATH = MODEL_DIRECTORY / "tokenizer_config.json"


class MobileClipTextModelUnavailable(RuntimeError):
    """The pinned local MobileCLIP text artifacts cannot be loaded."""


class MobileClipTextEncoder:
    """Convert text into normalized 512-dimensional MobileCLIP embeddings.

    The class deliberately owns only the tokenizer and one ONNX Runtime session.
    It has no HTTP, database, query-normalization, or search responsibilities.
    """

    def __init__(
        self,
        model_path: Path | str = DEFAULT_MODEL_PATH,
        tokenizer_path: Path | str = DEFAULT_TOKENIZER_PATH,
        tokenizer_config_path: Path | str = DEFAULT_TOKENIZER_CONFIG_PATH,
    ) -> None:
        self.model_path = Path(model_path)
        self.tokenizer_path = Path(tokenizer_path)
        self.tokenizer_config_path = Path(tokenizer_config_path)
        self._require_artifacts()

        try:
            from tokenizers import Tokenizer
            import onnxruntime as ort

            with self.tokenizer_config_path.open(encoding="utf-8") as source:
                tokenizer_config = json.load(source)
            self.max_length = int(tokenizer_config["model_max_length"])
            if self.max_length <= 0:
                raise ValueError("model_max_length must be positive")

            self._tokenizer = Tokenizer.from_file(str(self.tokenizer_path))
            pad_token = str(tokenizer_config["pad_token"])
            pad_id = self._tokenizer.token_to_id(pad_token)
            if pad_id is None:
                raise ValueError(f"pad token {pad_token!r} is absent from tokenizer.json")
            # tokenizer.json supplies the real CLIP start/end post-processor;
            # configuration supplies its real maximum length and padding token.
            self._tokenizer.enable_truncation(max_length=self.max_length)
            self._tokenizer.enable_padding(
                length=self.max_length,
                pad_id=pad_id,
                pad_token=pad_token,
            )
            self._session = ort.InferenceSession(
                str(self.model_path), providers=["CPUExecutionProvider"]
            )
        except Exception as error:
            raise MobileClipTextModelUnavailable(
                "MobileCLIP text model not available"
            ) from error

        inputs = self._session.get_inputs()
        outputs = self._session.get_outputs()
        if len(inputs) != 1 or len(outputs) != 1:
            raise MobileClipTextModelUnavailable(
                "MobileCLIP text model not available: unexpected ONNX I/O count"
            )
        input_metadata, output_metadata = inputs[0], outputs[0]
        if input_metadata.type != "tensor(int64)" or len(input_metadata.shape) != 2:
            raise MobileClipTextModelUnavailable(
                "MobileCLIP text model not available: unexpected input metadata"
            )
        if (
            output_metadata.type not in {"tensor(float)", "tensor(float16)"}
            or len(output_metadata.shape) != 2
            or output_metadata.shape[-1] != 512
        ):
            raise MobileClipTextModelUnavailable(
                "MobileCLIP text model not available: unexpected output metadata"
            )
        sequence_length = input_metadata.shape[-1]
        if isinstance(sequence_length, int) and sequence_length != self.max_length:
            raise MobileClipTextModelUnavailable(
                "MobileCLIP text model not available: tokenizer/model length mismatch"
            )
        self.input_name = input_metadata.name
        self.output_name = output_metadata.name

    @classmethod
    def artifacts_available(cls) -> bool:
        """Cheap availability check for health reporting; it never loads ONNX."""
        return all(
            path.is_file()
            for path in (
                DEFAULT_MODEL_PATH,
                DEFAULT_TOKENIZER_PATH,
                DEFAULT_TOKENIZER_CONFIG_PATH,
            )
        )

    def _require_artifacts(self) -> None:
        missing = [
            str(path)
            for path in (self.model_path, self.tokenizer_path, self.tokenizer_config_path)
            if not path.is_file()
        ]
        if missing:
            raise MobileClipTextModelUnavailable(
                "MobileCLIP text model not available: missing " + ", ".join(missing)
            )

    def encode(self, texts: Sequence[str]) -> np.ndarray:
        """Encode a batch once and return finite, L2-normalized float32 vectors."""
        values = list(texts)
        if not all(isinstance(text, str) for text in values):
            raise TypeError("MobileCLIP texts must be strings")
        if not values:
            return np.empty((0, 512), dtype=np.float32)

        encoded = self._tokenizer.encode_batch(values, add_special_tokens=True)
        input_ids = np.asarray([item.ids for item in encoded], dtype=np.int64)
        if input_ids.shape != (len(values), self.max_length):
            raise RuntimeError("MobileCLIP tokenizer returned an unexpected input shape")

        result = np.asarray(
            self._session.run([self.output_name], {self.input_name: input_ids})[0],
            dtype=np.float32,
        )
        if result.shape != (len(values), 512):
            raise RuntimeError(
                f"MobileCLIP text output has shape {result.shape}; expected ({len(values)}, 512)"
            )
        if not np.isfinite(result).all():
            raise RuntimeError("MobileCLIP text output contains NaN or Infinity")
        norms = np.linalg.norm(result, axis=1, keepdims=True)
        if np.any(norms <= 0) or not np.isfinite(norms).all():
            raise RuntimeError("MobileCLIP text output has an invalid L2 norm")
        return (result / norms).astype(np.float32, copy=False)
