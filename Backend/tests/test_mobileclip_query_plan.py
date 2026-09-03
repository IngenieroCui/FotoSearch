from contextlib import asynccontextmanager

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app import main
from app.query import QueryNormalizer, QueryTranslationUnavailable


class _Encoder:
    def __init__(self):
        self.calls = 0
        self.seen_texts: list[str] = []

    def encode(self, texts):
        self.calls += 1
        self.seen_texts.extend(texts)
        rows = []
        for text in texts:
            vector = np.zeros(512, dtype=np.float32)
            vector[sum(ord(char) for char in text) % 512] = 1.0
            rows.append(vector)
        return np.stack(rows)


def _forbidden_translator(_text: str) -> str:
    raise AssertionError("known visual vocabulary must not call external translation")


def _translator(text: str) -> str:
    translations = {
        "helicóptero": "helicopter",
        "un animal extraño sobre una roca": "a strange animal on a rock",
    }
    if text not in translations:
        raise RuntimeError(f"unexpected translation request: {text}")
    return translations[text]


def _test_lifespan(encoder: _Encoder | None = None, translator=_forbidden_translator):
    encoder = encoder or _Encoder()

    @asynccontextmanager
    async def lifespan(app):
        app.state.normalizer = QueryNormalizer(
            translation_enabled=True,
            translator=translator,
            translation_timeout_seconds=1.0,
        )
        app.state.mobileclip_text_encoder = encoder
        yield

    return lifespan, encoder


@pytest.mark.parametrize(
    ("spanish", "english", "canonical"),
    [
        ("cerdo", "pig", "pig"),
        ("azul", "blue", "blue"),
        ("negro", "black", "black"),
        ("mujer", "woman", "woman"),
        ("mujeres", "women", "women"),
        ("hombre", "man", "man"),
        ("hombres", "men", "men"),
        ("perro", "dog", "dog"),
        ("gato", "cat", "cat"),
        ("rojo", "red", "red"),
        ("blanco", "white", "white"),
        ("verde", "green", "green"),
    ],
)
def test_known_spanish_and_english_terms_canonicalize_identically(spanish, english, canonical):
    normalizer = QueryNormalizer(
        translation_enabled=True,
        translator=_forbidden_translator,
        translation_timeout_seconds=0.1,
    )
    spanish_plan = normalizer.parse(spanish, [])
    english_plan = normalizer.parse(english, [])
    assert spanish_plan.semantic_text == english_plan.semantic_text == canonical
    assert spanish_plan.joint_variants == english_plan.joint_variants
    assert spanish_plan.constraints == english_plan.constraints


@pytest.mark.parametrize(
    ("spanish", "english", "canonical"),
    [
        ("perro negro", "black dog", "black dog"),
        ("camiseta roja", "red t-shirt", "red t-shirt"),
        ("carro azul", "blue car", "blue car"),
    ],
)
def test_known_compositional_queries_canonicalize_identically(spanish, english, canonical):
    normalizer = QueryNormalizer(
        translation_enabled=True,
        translator=_forbidden_translator,
        translation_timeout_seconds=0.1,
    )
    spanish_plan = normalizer.parse(spanish, [])
    english_plan = normalizer.parse(english, [])
    assert spanish_plan.semantic_text == english_plan.semantic_text == canonical
    assert spanish_plan.joint_variants == english_plan.joint_variants
    assert spanish_plan.constraints == english_plan.constraints
    assert spanish_plan.constraints is not None
    assert all(value not in {"perro", "negro", "camiseta", "roja", "carro", "azul"}
               for value in [
                   spanish_plan.constraints["object"],
                   spanish_plan.constraints["attribute"],
               ])


def test_endpoint_equivalence_for_all_critical_pairs(monkeypatch):
    lifespan, _ = _test_lifespan()
    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    pairs = [
        ("cerdo", "pig"),
        ("azul", "blue"),
        ("negro", "black"),
        ("mujer", "woman"),
        ("hombre", "man"),
        ("hombres", "men"),
        ("perro", "dog"),
        ("camiseta roja", "red t-shirt"),
        ("perro negro", "black dog"),
    ]
    with TestClient(main.app) as client:
        for spanish, english in pairs:
            left = client.post("/api/mobileclip/query-plan", json={"query": spanish})
            right = client.post("/api/mobileclip/query-plan", json={"query": english})
            assert left.status_code == right.status_code == 200
            a, b = left.json(), right.json()
            assert a["semantic_text"] == b["semantic_text"], (spanish, english)
            assert a["joint_variants"] == b["joint_variants"], (spanish, english)
            assert a["query_embeddings"] == b["query_embeddings"], (spanish, english)
            assert a["constraints"] == b["constraints"], (spanish, english)


def test_encoder_receives_canonical_english_only(monkeypatch):
    encoder = _Encoder()
    lifespan, encoder = _test_lifespan(encoder=encoder)
    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    with TestClient(main.app) as client:
        response = client.post("/api/mobileclip/query-plan", json={"query": "camiseta roja"})
    assert response.status_code == 200
    seen = {text.casefold() for text in encoder.seen_texts}
    assert "red t-shirt" in seen
    assert "t-shirt" in seen
    assert "red" in seen
    assert "camiseta roja" not in seen
    assert "camiseta" not in seen
    assert "roja" not in seen


def test_unknown_spanish_word_uses_translator_before_encoding(monkeypatch):
    encoder = _Encoder()
    lifespan, encoder = _test_lifespan(encoder=encoder, translator=_translator)
    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    with TestClient(main.app) as client:
        response = client.post("/api/mobileclip/query-plan", json={"query": "helicóptero"})
    assert response.status_code == 200
    assert response.json()["semantic_text"] == "helicopter"
    assert all("helicóptero" not in text.casefold() for text in encoder.seen_texts)


def test_unknown_spanish_phrase_is_translated_as_one_unit(monkeypatch):
    lifespan, _ = _test_lifespan(translator=_translator)
    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    with TestClient(main.app) as client:
        response = client.post(
            "/api/mobileclip/query-plan",
            json={"query": "un animal extraño sobre una roca"},
        )
    assert response.status_code == 200
    assert response.json()["semantic_text"] == "a strange animal on a rock"


def test_translation_failure_returns_503_and_never_encodes(monkeypatch):
    encoder = _Encoder()

    def failing_translator(_text: str) -> str:
        raise RuntimeError("translator unavailable")

    lifespan, encoder = _test_lifespan(encoder=encoder, translator=failing_translator)
    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    with TestClient(main.app) as client:
        response = client.post(
            "/api/mobileclip/query-plan",
            json={"query": "palabra completamente desconocida"},
        )
    assert response.status_code == 503
    assert encoder.calls == 0


def test_health_reports_available_model_without_inference(monkeypatch):
    encoder = _Encoder()
    lifespan, encoder = _test_lifespan(encoder=encoder)
    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    with TestClient(main.app) as client:
        response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "mobileclip_text_available": True,
        "embedding_version": "mobileclip-s0-xenova-fp16-v1",
        "query_pipeline_version": "query-v5-english-only",
    }
    assert encoder.calls == 0


def test_cors_preflight_allows_query_plan(monkeypatch):
    lifespan, _ = _test_lifespan()
    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    with TestClient(main.app) as client:
        response = client.options(
            "/api/mobileclip/query-plan",
            headers={
                "Origin": "https://example.com",
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "content-type",
            },
        )
    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == "*"
