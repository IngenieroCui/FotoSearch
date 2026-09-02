from contextlib import asynccontextmanager

import numpy as np
from fastapi.testclient import TestClient

from app import main


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


def test_query_plan_marks_personal_queries_without_a_fallback(monkeypatch):
    monkeypatch.setattr(main.app.router, "lifespan_context", _lifespan)
    with TestClient(main.app) as client:
        response = client.post(
            "/api/mobileclip/query-plan",
            json={"query": "mi perro", "concept_names": ["mi perro"]},
        )
    assert response.status_code == 200
    assert response.json()["requires_me"] is True
