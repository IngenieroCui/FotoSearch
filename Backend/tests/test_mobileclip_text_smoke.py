from __future__ import annotations

import os

import numpy as np
import pytest

from app.mobileclip_text import DEFAULT_MODEL_PATH, MobileClipTextEncoder


@pytest.mark.skipif(
    not DEFAULT_MODEL_PATH.is_file() or os.getenv("FOTOSEARCH_RUN_MOBILECLIP_SMOKE") != "1",
    reason="requires local Xenova MobileCLIP artifacts and FOTOSEARCH_RUN_MOBILECLIP_SMOKE=1",
)
def test_real_mobileclip_text_encoder_smoke():
    encoder = MobileClipTextEncoder()
    dog = encoder.encode(["dog"])
    assert dog.shape == (1, 512)
    assert dog.dtype == np.float32
    assert np.isfinite(dog).all()
    assert np.isclose(np.linalg.norm(dog[0]), 1.0, atol=1e-5)

    duplicate = encoder.encode(["dog", "dog"])
    assert np.dot(duplicate[0], duplicate[1]) >= 0.99999
    assert encoder.encode(["dog", "red shirt", "car"]).shape == (3, 512)
