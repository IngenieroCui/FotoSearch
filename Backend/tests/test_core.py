import numpy as np
from app.query import QueryNormalizer
from app.services import SearchRanker
from app.vector import cosine_similarity, normalize_embedding


def test_normalize_and_cosine():
    assert np.isclose(np.linalg.norm(normalize_embedding(np.array([3, 4]))), 1)
    assert np.isclose(cosine_similarity(np.array([1, 0]), np.array([2, 0])), 1)


def test_parse_me_and_concept():
    result = QueryNormalizer().parse("quiero una foto mía con mi mascota en el parque", ["mi mascota"])
    assert result.requires_me and "parque" in result.semantic_text


def test_ranking_feedback(monkeypatch):
    results = SearchRanker().rank([{"asset_id": "good", "embedding": np.array([1, 0]), "face_embedding": None, "metadata": {}}, {"asset_id": "bad", "embedding": np.array([.9, .1]), "face_embedding": None, "metadata": {}}], np.array([1, 0]), None, [], [{"query_embedding": np.array([1, 0]), "asset_id": "good", "feedback": "positive"}, {"query_embedding": np.array([1, 0]), "asset_id": "bad", "feedback": "negative"}], False)
    assert results[0]["asset_id"] == "good"
