from contextlib import asynccontextmanager

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app import main
from app.query import QueryNormalizer, QueryTranslationError


def _translate(text):
    return {
        "perro negro": "black dog",
        "personas sonriendo en un restaurante": "people smiling in a restaurant",
        "cerdo": "pig",
        "pig": "pig",
    }.get(text, text)


class _Encoder:
    calls = 0

    def encode(self, texts):
        self.calls += 1
        vector = np.zeros(512, dtype=np.float32)
        vector[0] = 1
        return np.repeat(vector[None, :], len(texts), axis=0)


@asynccontextmanager
async def _lifespan(app):
    app.state.normalizer = main.QueryNormalizer(translator=_translate)
    app.state.mobileclip_text_encoder = _Encoder()
    yield


def test_query_plan_returns_mobileclip_vectors(monkeypatch):
    monkeypatch.setattr(main.app.router, "lifespan_context", _lifespan)
    with TestClient(main.app) as client:
        response = client.post("/api/mobileclip/query-plan", json={"query": "perro negro"})
    assert response.status_code == 200
    body = response.json()
    assert body["embedding_version"] == "mobileclip-s0-xenova-fp16-v1"
    assert len(body["query_embeddings"][0]) == 512
    assert "feedback_embedding" not in body
    assert "personal_concepts" not in body
    assert body["constraints"]["object"]["text"] == "dog"
    assert body["constraints"]["attribute"]["text"] == "black"
    assert body["constraints"]["target_color_joint"]["text"] == "black dog"


def test_health_reports_available_model_without_inference(monkeypatch):
    encoder = _Encoder()

    @asynccontextmanager
    async def lifespan(app):
        app.state.normalizer = main.QueryNormalizer()
        app.state.mobileclip_text_encoder = encoder
        yield

    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    with TestClient(main.app) as client:
        response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "mobileclip_text_available": True,
        "embedding_version": "mobileclip-s0-xenova-fp16-v1",
        "query_pipeline_version": "query-v5-backend-translation",
    }
    assert encoder.calls == 0


def test_cors_preflight_allows_query_plan(monkeypatch):
    monkeypatch.setattr(main.app.router, "lifespan_context", _lifespan)
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
    monkeypatch.setattr(main.app.router, "lifespan_context", _lifespan)
    with TestClient(main.app) as client:
        response = client.post(
            "/api/mobileclip/query-plan",
            json={"query": "mi perro", "concept_names": ["mi perro"]},
        )
    assert response.status_code == 200
    assert response.json()["requires_me"] is True


def test_spanish_queries_use_mocked_backend_translation_only():
    calls = []

    def translator(text):
        calls.append(text)
        return "people smiling in a restaurant"

    normalizer = QueryNormalizer(
        translation_enabled=True,
        translator=translator,
        translation_timeout_seconds=0.2,
    )
    parsed = normalizer.parse("personas sonriendo en un restaurante", [])

    assert parsed.variants[0] == "people smiling in a restaurant"
    assert parsed.semantic_text == "people smiling in a restaurant"
    assert all("personas" not in variant for variant in parsed.variants)
    assert calls == ["personas sonriendo en un restaurante"]
    # The second parse is served by the in-memory cache.
    assert normalizer.parse("personas sonriendo en un restaurante", []).variants[0] == parsed.variants[0]
    assert calls == ["personas sonriendo en un restaurante"]


def test_spanish_and_english_queries_produce_the_same_plan():
    normalizer = QueryNormalizer(translator=_translate)

    spanish = normalizer.parse("cerdo", [])
    english = normalizer.parse("pig", [])

    assert spanish.semantic_text == english.semantic_text == "pig"
    assert spanish.variants == english.variants
    assert spanish.joint_variants == english.joint_variants


def test_translation_failure_never_falls_back_to_spanish():
    def failing_translator(_):
        raise RuntimeError("translator unavailable")

    normalizer = QueryNormalizer(
        translation_enabled=True,
        translator=failing_translator,
        translation_timeout_seconds=0.2,
    )
    with pytest.raises(QueryTranslationError):
        normalizer.parse("una palabra que el traductor debe resolver", [])


def test_query_plan_returns_503_when_translation_is_unavailable(monkeypatch):
    @asynccontextmanager
    async def lifespan(app):
        app.state.normalizer = QueryNormalizer(
            translator=lambda _: (_ for _ in ()).throw(
                RuntimeError("translator unavailable")
            )
        )
        app.state.mobileclip_text_encoder = _Encoder()
        yield

    monkeypatch.setattr(main.app.router, "lifespan_context", lifespan)
    with TestClient(main.app) as client:
        response = client.post(
            "/api/mobileclip/query-plan", json={"query": "cerdo"}
        )

    assert response.status_code == 503
    assert "traductor" in response.json()["detail"]
