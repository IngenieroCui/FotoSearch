from contextlib import asynccontextmanager

import numpy as np
from fastapi.testclient import TestClient

from app import main


_TRANSLATIONS = {
    "cerdo": "pig",
    "pig": "pig",
    "perro negro": "black dog",
    "camiseta roja": "red t-shirt",
    "persona con camiseta roja": "person wearing a red t-shirt",
    "helicóptero": "helicopter",
    "un cerdo en el campo": "a pig in the countryside",
    "mi perro": "my dog",
}


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
            # Deterministic per text so equal vectors require equal encoder input.
            vector[sum(ord(char) for char in text) % 512] = 1.0
            rows.append(vector)
        return np.stack(rows)


def _translator(text: str) -> str:
    return _TRANSLATIONS.get(text, text)


def _test_lifespan(encoder: _Encoder | None = None, translator=_translator):
    encoder = encoder or _Encoder()

    @asynccontextmanager
    async def lifespan(app):
        app.state.normalizer = main.QueryNormalizer(
            translation_enabled=True,
            translator=translator,
            translation_timeout_seconds=1.0,
        )
        app.state.mobileclip_text_encoder = encoder
        yield

    return lifespan, encoder


def test_query_plan_returns_mobileclip_vectors(monkeypatch):
    lifespan, _ = _test_lifespan()
    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    with TestClient(main.app) as client:
        response = client.post("/api/mobileclip/query-plan", json={"query": "perro negro"})
    assert response.status_code == 200
    body = response.json()
    assert body["embedding_version"] == "mobileclip-s0-xenova-fp16-v1"
    assert body["query_pipeline_version"] == "query-v5-english-only"
    assert body["semantic_text"] == "black dog"
    assert len(body["query_embeddings"][0]) == 512


def test_spanish_and_english_equivalent_query_use_same_pipeline(monkeypatch):
    lifespan, _ = _test_lifespan()
    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    with TestClient(main.app) as client:
        spanish = client.post("/api/mobileclip/query-plan", json={"query": "cerdo"})
        english = client.post("/api/mobileclip/query-plan", json={"query": "pig"})
    assert spanish.status_code == english.status_code == 200
    spanish_body = spanish.json()
    english_body = english.json()
    assert spanish_body["original"] == "cerdo"
    assert english_body["original"] == "pig"
    assert spanish_body["semantic_text"] == english_body["semantic_text"] == "pig"
    assert spanish_body["joint_variants"] == english_body["joint_variants"]
    assert spanish_body["query_embeddings"] == english_body["query_embeddings"]


def test_encoder_receives_english_only_for_spanish_compositional_query(monkeypatch):
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


def test_arbitrary_spanish_word_is_translated_before_encoding(monkeypatch):
    encoder = _Encoder()
    lifespan, encoder = _test_lifespan(encoder=encoder)
    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    with TestClient(main.app) as client:
        response = client.post("/api/mobileclip/query-plan", json={"query": "helicóptero"})
    assert response.status_code == 200
    assert response.json()["semantic_text"] == "helicopter"
    assert all("helicóptero" not in text.casefold() for text in encoder.seen_texts)


def test_translation_failure_returns_503_without_encoding(monkeypatch):
    encoder = _Encoder()

    def failing_translator(_text: str) -> str:
        raise RuntimeError("translator unavailable")

    lifespan, encoder = _test_lifespan(encoder=encoder, translator=failing_translator)
    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    with TestClient(main.app) as client:
        response = client.post("/api/mobileclip/query-plan", json={"query": "cerdo"})
    assert response.status_code == 503
    assert encoder.calls == 0


def test_complete_phrase_is_translated_as_one_unit(monkeypatch):
    lifespan, _ = _test_lifespan()
    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    with TestClient(main.app) as client:
        response = client.post(
            "/api/mobileclip/query-plan", json={"query": "un cerdo en el campo"}
        )
    assert response.status_code == 200
    assert response.json()["semantic_text"] == "a pig in the countryside"
    assert all("cerdo" not in item for item in response.json()["joint_variants"])


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


def test_query_plan_marks_personal_queries_without_a_fallback(monkeypatch):
    lifespan, _ = _test_lifespan()
    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    with TestClient(main.app) as client:
        response = client.post(
            "/api/mobileclip/query-plan",
            json={"query": "mi perro", "concept_names": ["mi perro"]},
        )
    assert response.status_code == 200
    assert response.json()["requires_me"] is True
