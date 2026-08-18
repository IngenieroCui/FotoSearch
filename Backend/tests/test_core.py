import json
import sqlite3

import numpy as np

from app.config import settings
from app.database import Database
from app.query import QueryNormalizer
from app.services import SearchRanker
from app.vector import cosine_similarity, normalize_embedding, numpy_to_blob


def _photo(asset_id: str, embedding: list[float], face: list[float] | None = None) -> dict:
    return {
        "asset_id": asset_id,
        "embedding": np.array(embedding, dtype=np.float32),
        "face_embedding": np.array(face, dtype=np.float32) if face else None,
        "metadata": {},
    }


def _feedback(asset_id: str, relevant: bool, image: list[float], *, strong: bool = False) -> dict:
    return {
        "query_embedding": np.array([1.0, 0.0]),
        "image_embedding": np.array(image, dtype=np.float32),
        "asset_id": asset_id,
        "feedback": "positive" if relevant else "negative",
        "is_strong": strong,
    }


def test_normalize_and_cosine():
    assert np.isclose(np.linalg.norm(normalize_embedding(np.array([3, 4]))), 1)
    assert np.isclose(cosine_similarity(np.array([1, 0]), np.array([2, 0])), 1)


def test_query_normalization_keeps_spanish_and_expands_common_visual_terms():
    parsed = QueryNormalizer().parse("quiero una foto con camiseta roja", [])
    assert parsed.semantic_text == "camiseta roja"
    assert parsed.variants[0] == "camiseta roja"
    assert "red t-shirt" in parsed.variants
    assert "a photo of a person wearing red t-shirt" in parsed.variants
    assert parsed.constraints is not None
    assert parsed.constraints["object"] == "camiseta"
    assert parsed.constraints["attribute"] == "roja"
    assert "camiseta" not in parsed.joint_variants
    assert "roja" not in parsed.joint_variants


def test_compositional_constraints_cover_requested_regressions():
    normalizer = QueryNormalizer()
    for query, object_, color in [
        ("camiseta roja", "camiseta", "roja"),
        ("perro negro", "perro", "negro"),
        ("carro rojo", "carro", "rojo"),
    ]:
        parsed = normalizer.parse(query, [])
        assert parsed.constraints is not None
        assert parsed.constraints["object"] == object_
        assert parsed.constraints["attribute"] == color


def test_compositional_reranking_promotes_complete_object_and_color_match():
    # El distractor gana CLIP conjunto inicialmente, pero no cubre el atributo.
    real = normalize_embedding(np.array([0.75, 0.55, 0.55]))
    distractor = normalize_embedding(np.array([0.90, 0.65, 0.0]))
    results = SearchRanker().rank(
        [_photo("red-shirt", real), _photo("shirt-no-color", distractor)],
        np.array([1.0, 0.0, 0.0]),
        None,
        [],
        [],
        False,
        ["red shirt"],
        {
            "object": np.array([0.0, 1.0, 0.0]),
            "attribute": np.array([0.0, 0.0, 1.0]),
            "target_color_joint": np.array([0.0, 0.0, 1.0]),
            "color_competitors": [np.array([0.0, 0.0, -1.0])],
        },
    )
    assert results[0]["asset_id"] == "red-shirt"
    assert results[0]["coverage_score"] > results[1]["coverage_score"]


def test_simple_queries_keep_semantic_order_without_compositional_constraints():
    results = SearchRanker().rank(
        [_photo("dog", [1, 0]), _photo("beach", [0, 1])],
        np.array([1, 0]),
        None,
        [],
        [],
        False,
        ["perro"],
    )
    assert [item["asset_id"] for item in results] == ["dog", "beach"]
    assert all(item["compositional_score"] == item["semantic_score"] for item in results)


def test_parse_identity_and_personal_concept_separately():
    parsed = QueryNormalizer().parse(
        "quiero una foto mía con mi mascota en el parque", ["mi mascota"]
    )
    assert parsed.requires_me
    assert parsed.personal_concepts == ["mi mascota"]
    assert "parque" in parsed.semantic_text
    assert not QueryNormalizer().parse("mi mascota", ["mi mascota"]).requires_me


def test_english_and_spanish_originals_are_never_removed():
    spanish = QueryNormalizer().parse("perros en la playa", [])
    english = QueryNormalizer().parse("dogs playing at the beach", [])
    assert spanish.variants[0] == "perros en la playa"
    assert "dogs at beach" in spanish.variants
    assert english.variants[0] == "dogs playing at the beach"


def test_optional_translation_failure_does_not_break_variants():
    def broken_translator(_: str) -> str:
        raise TimeoutError("offline")

    parsed = QueryNormalizer(True, broken_translator).parse("camiseta roja", [])
    assert parsed.variants[0] == "camiseta roja"
    assert "red t-shirt" in parsed.variants


def test_variant_scoring_uses_max_and_reports_winner():
    result = SearchRanker().rank(
        [_photo("match", [1, 0])],
        [np.array([1, 0]), np.array([-1, 0])],
        None,
        [],
        [],
        False,
        ["correct variant", "bad variant"],
    )[0]
    assert np.isclose(result["semantic_score"], 1.0)
    assert result["best_query_variant"] == "correct variant"


def test_feedback_is_capped_with_fifty_examples():
    positives = [_feedback(f"p{index}", True, [1, 0]) for index in range(50)]
    negatives = [_feedback(f"n{index}", False, [1, 0]) for index in range(50)]
    positive = SearchRanker().rank(
        [_photo("target", [1, 0])], np.array([1, 0]), None, [], positives, False
    )[0]
    negative = SearchRanker().rank(
        [_photo("target", [1, 0])], np.array([1, 0]), None, [], negatives, False
    )[0]
    assert positive["feedback_adjustment"] <= settings.general_feedback_max_boost
    assert negative["feedback_adjustment"] >= settings.general_feedback_max_penalty


def test_semantic_signal_dominates_generalized_feedback():
    results = SearchRanker().rank(
        [_photo("semantic", [0.4, np.sqrt(0.84)]), _photo("feedback", [0.1, np.sqrt(0.99)])],
        np.array([1, 0]),
        None,
        [],
        [_feedback("example", True, [0.1, np.sqrt(0.99)])],
        False,
    )
    assert results[0]["asset_id"] == "semantic"


def test_exact_and_correction_feedback_have_bounded_effect():
    normal = SearchRanker().rank(
        [_photo("target", [1, 0])], np.array([1, 0]), None, [], [_feedback("target", True, [1, 0])], False
    )[0]
    strong = SearchRanker().rank(
        [_photo("target", [1, 0])], np.array([1, 0]), None, [], [_feedback("target", True, [1, 0], strong=True)], False
    )[0]
    negative = SearchRanker().rank(
        [_photo("target", [1, 0])], np.array([1, 0]), None, [], [_feedback("target", False, [1, 0])], False
    )[0]
    assert normal["feedback_adjustment"] == settings.exact_positive_boost
    assert strong["feedback_adjustment"] == settings.correction_positive_boost
    assert negative["feedback_adjustment"] == settings.exact_negative_penalty


def test_two_stage_retrieval_does_not_rescue_non_candidate():
    feedback = [_feedback("irrelevant", True, [0, 1], strong=True)]
    results = SearchRanker(semantic_candidates=1).rank(
        [_photo("semantic", [1, 0]), _photo("irrelevant", [0, 1])],
        np.array([1, 0]),
        None,
        [],
        feedback,
        False,
    )
    assert [item["asset_id"] for item in results] == ["semantic"]


def test_me_query_excludes_unrecognized_faces():
    results = SearchRanker().rank(
        [_photo("me", [1, 0], [1, 0]), _photo("other", [1, 0], [0, 1])],
        np.array([1, 0]),
        np.array([1, 0]),
        [],
        [],
        True,
    )
    assert [item["asset_id"] for item in results] == ["me"]


def test_photo_version_participates_in_current_check(tmp_path):
    database = Database(str(tmp_path / "current.db"))
    database.upsert_photo("phone", "asset", "123", {}, np.array([1, 0]), None)
    assert database.photo_is_current("phone", "asset", "123")
    database.conn.execute("UPDATE photos SET embedding_version='old'")
    database.conn.commit()
    assert not database.photo_is_current("phone", "asset", "123")
    database.close()


def test_model_name_change_invalidates_even_if_declared_version_is_unchanged(tmp_path):
    path = tmp_path / "model-change.db"
    database = Database(str(path))
    database.upsert_photo("phone", "asset", "123", {}, np.array([1, 0]), None)
    database.close()

    changed = Database(str(path), image_model="a-different-image-model")
    assert changed.stats()["indexed_photos"] == 0
    assert changed.invalidation_report["semantic_index_invalidated"] is True
    changed.close()


def test_incompatible_feedback_is_ignored(tmp_path):
    database = Database(str(tmp_path / "feedback.db"))
    database.add_feedback("phone", "dog", np.array([1, 0]), "asset", np.array([1, 0]), True)
    database.conn.execute("UPDATE search_feedback SET embedding_version='old'")
    database.conn.commit()
    assert database.feedback("phone") == []
    database.close()


def test_incompatible_concept_is_marked_for_rebuild(tmp_path):
    database = Database(str(tmp_path / "concept.db"))
    database.create_concept("pet", "mi mascota", [], np.array([1, 0]), [np.array([1, 0])])
    database.conn.execute("UPDATE personal_concepts SET embedding_version='old'")
    database.conn.commit()
    assert database.concepts() == []
    assert database.concepts(include_unavailable=True)[0]["needs_rebuild"]
    database.close()


def test_legacy_db_invalidates_semantics_but_preserves_faces(tmp_path):
    path = tmp_path / "legacy.db"
    connection = sqlite3.connect(path)
    connection.execute(
        """CREATE TABLE photos (device_id TEXT, asset_id TEXT, modified_at TEXT, metadata TEXT,
        embedding BLOB, indexed_at TEXT, PRIMARY KEY(device_id,asset_id))"""
    )
    connection.execute(
        """CREATE TABLE photo_faces (device_id TEXT, asset_id TEXT, embedding BLOB,
        PRIMARY KEY(device_id,asset_id))"""
    )
    connection.execute(
        "INSERT INTO photos VALUES(?,?,?,?,?,CURRENT_TIMESTAMP)",
        ("phone", "asset", "1", json.dumps({}), numpy_to_blob(np.array([1, 0]))),
    )
    connection.execute(
        "INSERT INTO photo_faces VALUES(?,?,?)",
        ("phone", "asset", numpy_to_blob(np.array([1, 0]))),
    )
    connection.commit()
    connection.close()

    database = Database(str(path))
    assert database.stats()["indexed_photos"] == 0
    face = database.conn.execute("SELECT embedding_version FROM photo_faces").fetchone()
    assert face["embedding_version"] == settings.face_embedding_version
    assert database.invalidation_report["semantic_index_invalidated"] is True
    database.close()
