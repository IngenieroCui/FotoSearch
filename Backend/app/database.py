import json
import sqlite3
from pathlib import Path
from typing import Any

import numpy as np

from .config import settings
from .vector import blob_to_numpy, numpy_to_blob


class Database:
    def __init__(
        self,
        path: str,
        embedding_version: str | None = None,
        query_pipeline_version: str | None = None,
        face_embedding_version: str | None = None,
        image_model: str | None = None,
        text_model: str | None = None,
    ):
        self.embedding_version = embedding_version or settings.embedding_version
        self.query_pipeline_version = query_pipeline_version or settings.query_pipeline_version
        self.face_embedding_version = face_embedding_version or settings.face_embedding_version
        self.image_model = image_model or settings.clip_model
        self.text_model = text_model or settings.text_model
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.invalidation_report: dict[str, int | bool] = {}
        self._create_tables()
        self._migrate_schema()
        self._reconcile_versions()

    def _create_tables(self) -> None:
        self.conn.executescript("""
        CREATE TABLE IF NOT EXISTS app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS photos (
          device_id TEXT NOT NULL, asset_id TEXT NOT NULL, modified_at TEXT, metadata TEXT NOT NULL DEFAULT '{}',
          embedding BLOB NOT NULL, embedding_version TEXT, indexed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY(device_id, asset_id));
        CREATE TABLE IF NOT EXISTS photo_faces (
          device_id TEXT NOT NULL, asset_id TEXT NOT NULL, embedding BLOB NOT NULL, embedding_version TEXT,
          PRIMARY KEY(device_id, asset_id));
        CREATE TABLE IF NOT EXISTS face_identities (
          id TEXT PRIMARY KEY, name TEXT UNIQUE NOT NULL, aliases TEXT NOT NULL, embedding BLOB NOT NULL,
          embedding_version TEXT, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS personal_concepts (
          id TEXT PRIMARY KEY, name TEXT UNIQUE NOT NULL, aliases TEXT NOT NULL, prototype_embedding BLOB NOT NULL,
          embedding_version TEXT, needs_rebuild INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS concept_examples (
          concept_id TEXT NOT NULL, device_id TEXT, asset_id TEXT, embedding BLOB NOT NULL, embedding_version TEXT);
        CREATE TABLE IF NOT EXISTS search_feedback (
          id INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT NOT NULL, query_text TEXT NOT NULL,
          query_embedding BLOB NOT NULL, asset_id TEXT NOT NULL, image_embedding BLOB NOT NULL,
          feedback TEXT NOT NULL, embedding_version TEXT, query_pipeline_version TEXT,
          is_strong INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
        """)
        self.conn.commit()

    def _ensure_column(self, table: str, definition: str) -> None:
        column = definition.split()[0]
        existing = {row["name"] for row in self.conn.execute(f"PRAGMA table_info({table})")}
        if column not in existing:
            self.conn.execute(f"ALTER TABLE {table} ADD COLUMN {definition}")

    def _migrate_schema(self) -> None:
        # ALTER TABLE preserva la DB del MVP y vuelve NULL todo embedding legado.
        additions = {
            "photos": ["embedding_version TEXT"],
            "photo_faces": ["embedding_version TEXT"],
            "face_identities": ["embedding_version TEXT"],
            "personal_concepts": ["embedding_version TEXT", "needs_rebuild INTEGER NOT NULL DEFAULT 1"],
            "concept_examples": ["embedding_version TEXT"],
            "search_feedback": [
                "embedding_version TEXT",
                "query_pipeline_version TEXT",
                "is_strong INTEGER NOT NULL DEFAULT 0",
            ],
        }
        with self.conn:
            for table, definitions in additions.items():
                for definition in definitions:
                    self._ensure_column(table, definition)

    def _metadata(self, key: str) -> str | None:
        row = self.conn.execute("SELECT value FROM app_metadata WHERE key=?", (key,)).fetchone()
        return row["value"] if row else None

    def _set_metadata(self, key: str, value: str) -> None:
        self.conn.execute("INSERT OR REPLACE INTO app_metadata(key,value) VALUES(?,?)", (key, value))

    def _count(self, table: str) -> int:
        return int(self.conn.execute(f"SELECT count(*) FROM {table}").fetchone()[0])

    def _reconcile_versions(self) -> None:
        old_image = self._metadata("image_embedding_version")
        old_query = self._metadata("query_pipeline_version")
        old_face = self._metadata("face_embedding_version")
        old_image_model = self._metadata("image_model")
        old_text_model = self._metadata("text_model")
        report: dict[str, int | bool] = {
            "semantic_index_invalidated": False,
            "photos_removed": 0,
            "feedback_removed": 0,
            "concepts_marked_for_rebuild": 0,
            "faces_removed": 0,
        }

        with self.conn:
            if (
                old_image != self.embedding_version
                or old_image_model != self.image_model
                or old_text_model != self.text_model
            ):
                report["semantic_index_invalidated"] = True
                report["photos_removed"] = self._count("photos")
                report["feedback_removed"] = self._count("search_feedback")
                report["concepts_marked_for_rebuild"] = self._count("personal_concepts")
                # Los originales viven en el teléfono. Borrar estas filas hace que
                # /index/pending solicite todas las miniaturas otra vez.
                self.conn.execute("DELETE FROM photos")
                self.conn.execute("DELETE FROM search_feedback")
                self.conn.execute("DELETE FROM concept_examples")
                self.conn.execute(
                    "UPDATE personal_concepts SET embedding_version=NULL, needs_rebuild=1"
                )
            elif old_query != self.query_pipeline_version:
                report["feedback_removed"] = self._count("search_feedback")
                self.conn.execute("DELETE FROM search_feedback")

            # La versión facial es independiente. En una DB sin metadata sabemos
            # que el MVP ya usaba exactamente FaceNet/VGGFace2, así que etiquetamos
            # esos vectores sin destruir identidades personales.
            if old_face is None:
                self.conn.execute(
                    "UPDATE photo_faces SET embedding_version=? WHERE embedding_version IS NULL",
                    (self.face_embedding_version,),
                )
                self.conn.execute(
                    "UPDATE face_identities SET embedding_version=? WHERE embedding_version IS NULL",
                    (self.face_embedding_version,),
                )
            elif old_face != self.face_embedding_version:
                report["faces_removed"] = self._count("photo_faces") + self._count("face_identities")
                self.conn.execute("DELETE FROM photo_faces")
                self.conn.execute("DELETE FROM face_identities")

            # Defensa adicional ante filas importadas o parcialmente migradas.
            self.conn.execute("DELETE FROM photos WHERE embedding_version IS NOT ?", (self.embedding_version,))
            self.conn.execute(
                "DELETE FROM search_feedback WHERE embedding_version IS NOT ? OR query_pipeline_version IS NOT ?",
                (self.embedding_version, self.query_pipeline_version),
            )
            self._set_metadata("image_embedding_version", self.embedding_version)
            self._set_metadata("query_pipeline_version", self.query_pipeline_version)
            self._set_metadata("face_embedding_version", self.face_embedding_version)
            self._set_metadata("image_model", self.image_model)
            self._set_metadata("text_model", self.text_model)
        self.invalidation_report = report

    def photo_is_current(self, device_id: str, asset_id: str, modified_at: str | None) -> bool:
        row = self.conn.execute(
            "SELECT modified_at,embedding_version FROM photos WHERE device_id=? AND asset_id=?",
            (device_id, asset_id),
        ).fetchone()
        return (
            row is not None
            and row["modified_at"] == modified_at
            and row["embedding_version"] == self.embedding_version
        )

    def upsert_photo(
        self,
        device_id: str,
        asset_id: str,
        modified_at: str | None,
        metadata: dict[str, Any],
        embedding: np.ndarray,
        face: np.ndarray | None,
    ) -> None:
        self.upsert_photos([(device_id, asset_id, modified_at, metadata, embedding, face)])

    def upsert_photos(
        self,
        records: list[tuple[str, str, str | None, dict[str, Any], np.ndarray, np.ndarray | None]],
    ) -> None:
        with self.conn:
            for device_id, asset_id, modified_at, metadata, embedding, face in records:
                self.conn.execute(
                    """INSERT OR REPLACE INTO photos
                    (device_id,asset_id,modified_at,metadata,embedding,embedding_version,indexed_at)
                    VALUES(?,?,?,?,?,?,CURRENT_TIMESTAMP)""",
                    (
                        device_id,
                        asset_id,
                        modified_at,
                        json.dumps(metadata),
                        numpy_to_blob(embedding),
                        self.embedding_version,
                    ),
                )
                if face is not None:
                    self.conn.execute(
                        """INSERT OR REPLACE INTO photo_faces
                        (device_id,asset_id,embedding,embedding_version) VALUES(?,?,?,?)""",
                        (device_id, asset_id, numpy_to_blob(face), self.face_embedding_version),
                    )

    def close(self) -> None:
        self.conn.close()

    def photos(self, device_id: str) -> list[dict[str, Any]]:
        rows = self.conn.execute(
            """SELECT p.*, f.embedding AS face_embedding
            FROM photos p LEFT JOIN photo_faces f
              ON p.device_id=f.device_id AND p.asset_id=f.asset_id
             AND f.embedding_version=?
            WHERE p.device_id=? AND p.embedding_version=?""",
            (self.face_embedding_version, device_id, self.embedding_version),
        ).fetchall()
        return [
            {
                "asset_id": row["asset_id"],
                "embedding": blob_to_numpy(row["embedding"]),
                "face_embedding": blob_to_numpy(row["face_embedding"]) if row["face_embedding"] else None,
                "metadata": json.loads(row["metadata"]),
            }
            for row in rows
        ]

    def photo(self, device_id: str, asset_id: str) -> dict[str, Any] | None:
        return next((item for item in self.photos(device_id) if item["asset_id"] == asset_id), None)

    def stats(self, device_id: str | None = None) -> dict[str, int]:
        clause, params = (" WHERE device_id=?", (device_id,)) if device_id else ("", ())
        photos = self.conn.execute("SELECT count(*) FROM photos" + clause, params).fetchone()[0]
        return {
            "indexed_photos": photos,
            "concepts": self._count("personal_concepts"),
            "feedback": self._count("search_feedback"),
        }

    def set_me(self, embedding: np.ndarray) -> None:
        with self.conn:
            self.conn.execute(
                """INSERT OR REPLACE INTO face_identities
                (id,name,aliases,embedding,embedding_version,updated_at)
                VALUES('me','yo','[\"yo\",\"mí\",\"mía\",\"mío\",\"mi persona\"]',?,?,CURRENT_TIMESTAMP)""",
                (numpy_to_blob(embedding), self.face_embedding_version),
            )

    def me(self) -> np.ndarray | None:
        row = self.conn.execute(
            "SELECT embedding FROM face_identities WHERE id='me' AND embedding_version=?",
            (self.face_embedding_version,),
        ).fetchone()
        return blob_to_numpy(row[0]) if row else None

    def create_concept(
        self,
        concept_id: str,
        name: str,
        aliases: list[str],
        prototype: np.ndarray,
        examples: list[np.ndarray],
    ) -> None:
        with self.conn:
            self.conn.execute(
                """INSERT OR REPLACE INTO personal_concepts
                (id,name,aliases,prototype_embedding,embedding_version,needs_rebuild)
                VALUES(?,?,?,?,?,0)""",
                (concept_id, name, json.dumps(aliases), numpy_to_blob(prototype), self.embedding_version),
            )
            self.conn.execute("DELETE FROM concept_examples WHERE concept_id=?", (concept_id,))
            self.conn.executemany(
                "INSERT INTO concept_examples(concept_id,embedding,embedding_version) VALUES(?,?,?)",
                [(concept_id, numpy_to_blob(item), self.embedding_version) for item in examples],
            )

    def concepts(self, include_unavailable: bool = False) -> list[dict[str, Any]]:
        rows = self.conn.execute("SELECT * FROM personal_concepts").fetchall()
        results = []
        for row in rows:
            active = row["embedding_version"] == self.embedding_version and not bool(row["needs_rebuild"])
            if not include_unavailable and not active:
                continue
            results.append({
                "id": row["id"],
                "name": row["name"],
                "aliases": json.loads(row["aliases"]),
                "embedding": blob_to_numpy(row["prototype_embedding"]) if active else None,
                "needs_rebuild": not active,
            })
        return results

    def delete_concept(self, concept_id: str) -> None:
        with self.conn:
            self.conn.execute("DELETE FROM concept_examples WHERE concept_id=?", (concept_id,))
            self.conn.execute("DELETE FROM personal_concepts WHERE id=?", (concept_id,))

    def add_feedback(
        self,
        device_id: str,
        query: str,
        query_embedding: np.ndarray,
        asset_id: str,
        image_embedding: np.ndarray,
        relevant: bool,
        strong: bool = False,
    ) -> None:
        normalized_query = re_normalize_query(query)
        # El voto posterior reemplaza el anterior: no existe acumulación exacta.
        with self.conn:
            self.conn.execute(
                "DELETE FROM search_feedback WHERE device_id=? AND query_text=? AND asset_id=?",
                (device_id, normalized_query, asset_id),
            )
            self.conn.execute(
                """INSERT INTO search_feedback
                (device_id,query_text,query_embedding,asset_id,image_embedding,feedback,
                 embedding_version,query_pipeline_version,is_strong)
                VALUES(?,?,?,?,?,?,?,?,?)""",
                (
                    device_id,
                    normalized_query,
                    numpy_to_blob(query_embedding),
                    asset_id,
                    numpy_to_blob(image_embedding),
                    "positive" if relevant else "negative",
                    self.embedding_version,
                    self.query_pipeline_version,
                    int(strong and relevant),
                ),
            )

    def feedback(self, device_id: str) -> list[dict[str, Any]]:
        rows = self.conn.execute(
            """SELECT query_embedding,image_embedding,asset_id,feedback,is_strong
            FROM search_feedback
            WHERE device_id=? AND embedding_version=? AND query_pipeline_version=?
            ORDER BY created_at DESC""",
            (device_id, self.embedding_version, self.query_pipeline_version),
        ).fetchall()
        return [
            {
                "query_embedding": blob_to_numpy(row["query_embedding"]),
                "image_embedding": blob_to_numpy(row["image_embedding"]),
                "asset_id": row["asset_id"],
                "feedback": row["feedback"],
                "is_strong": bool(row["is_strong"]),
            }
            for row in rows
        ]


def re_normalize_query(query: str) -> str:
    return " ".join(query.casefold().split())
