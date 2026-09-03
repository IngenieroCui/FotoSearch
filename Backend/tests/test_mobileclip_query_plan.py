from contextlib import asynccontextmanager

import numpy as np
from fastapi.testclient import TestClient

from app import main
from app.query import QueryNormalizer


class _Encoder:
    calls = 0

    def encode(self, texts):
        self.calls += 1
        vector = np.zeros(512, dtype=np.float32)
        vector[0] = 1
        return np.repeat(vector[None, :], len(texts), axis=0)


@asynccontextmanager
async def _lifespan(app):
    app.state.normalizer = main.QueryNormalizer()
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
        "query_pipeline_version": "query-v4-compositional",
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


def test_spanish_queries_use_mocked_translation_before_local_fallback():
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
    assert calls == ["personas sonriendo en un restaurante"]
    # The second parse is served by the 256-entry in-memory cache.
    assert normalizer.parse("personas sonriendo en un restaurante", []).variants[0] == parsed.variants[0]
    assert calls == ["personas sonriendo en un restaurante"]


def test_spanish_local_translation_handles_natural_object_color_and_failures():
    def failing_translator(_):
        raise RuntimeError("translator unavailable")

    normalizer = QueryNormalizer(
        translation_enabled=True,
        translator=failing_translator,
        translation_timeout_seconds=0.2,
    )
    assert "red t-shirt" in normalizer.parse("camiseta roja", []).variants
    assert "black dog" in normalizer.parse("perro negro", []).variants
    assert "red car" in normalizer.parse("carro rojo", []).variants
    assert "person wearing red t-shirt" in normalizer.parse(
        "persona con camiseta roja", []
    ).variants
