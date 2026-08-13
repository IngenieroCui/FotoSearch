import json
import sqlite3
from pathlib import Path
from typing import Any
import numpy as np
from .vector import blob_to_numpy, numpy_to_blob


class Database:
    def __init__(self, path: str):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self._create_tables()

    def _create_tables(self) -> None:
        self.conn.executescript("""
        CREATE TABLE IF NOT EXISTS photos (
          device_id TEXT NOT NULL, asset_id TEXT NOT NULL, modified_at TEXT, metadata TEXT NOT NULL DEFAULT '{}',
          embedding BLOB NOT NULL, indexed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(device_id, asset_id));
        CREATE TABLE IF NOT EXISTS photo_faces (
          device_id TEXT NOT NULL, asset_id TEXT NOT NULL, embedding BLOB NOT NULL,
          PRIMARY KEY(device_id, asset_id));
        CREATE TABLE IF NOT EXISTS face_identities (
          id TEXT PRIMARY KEY, name TEXT UNIQUE NOT NULL, aliases TEXT NOT NULL, embedding BLOB NOT NULL, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS personal_concepts (
          id TEXT PRIMARY KEY, name TEXT UNIQUE NOT NULL, aliases TEXT NOT NULL, prototype_embedding BLOB NOT NULL, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS concept_examples (concept_id TEXT NOT NULL, device_id TEXT, asset_id TEXT, embedding BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS search_feedback (
          id INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT NOT NULL, query_text TEXT NOT NULL, query_embedding BLOB NOT NULL,
          asset_id TEXT NOT NULL, image_embedding BLOB NOT NULL, feedback TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
        """)
        self.conn.commit()

    def photo_is_current(self, device_id: str, asset_id: str, modified_at: str | None) -> bool:
        row = self.conn.execute("SELECT modified_at FROM photos WHERE device_id=? AND asset_id=?", (device_id, asset_id)).fetchone()
        return row is not None and row["modified_at"] == modified_at

    def upsert_photo(self, device_id: str, asset_id: str, modified_at: str | None, metadata: dict[str, Any], embedding: np.ndarray, face: np.ndarray | None) -> None:
        self.upsert_photos([(device_id, asset_id, modified_at, metadata, embedding, face)])

    def upsert_photos(self, records: list[tuple[str, str, str | None, dict[str, Any], np.ndarray, np.ndarray | None]]) -> None:
        """Persiste un lote dentro de una sola transacción SQLite."""
        with self.conn:
            for device_id, asset_id, modified_at, metadata, embedding, face in records:
                self.conn.execute("INSERT OR REPLACE INTO photos(device_id,asset_id,modified_at,metadata,embedding,indexed_at) VALUES(?,?,?,?,?,CURRENT_TIMESTAMP)", (device_id, asset_id, modified_at, json.dumps(metadata), numpy_to_blob(embedding)))
                if face is not None:
                    self.conn.execute("INSERT OR REPLACE INTO photo_faces(device_id,asset_id,embedding) VALUES(?,?,?)", (device_id, asset_id, numpy_to_blob(face)))
                else:
                    self.conn.execute("DELETE FROM photo_faces WHERE device_id=? AND asset_id=?", (device_id, asset_id))

    def close(self) -> None:
        self.conn.close()

    def photos(self, device_id: str) -> list[dict[str, Any]]:
        rows = self.conn.execute("SELECT p.*, f.embedding AS face_embedding FROM photos p LEFT JOIN photo_faces f ON p.device_id=f.device_id AND p.asset_id=f.asset_id WHERE p.device_id=?", (device_id,)).fetchall()
        return [{"asset_id": r["asset_id"], "embedding": blob_to_numpy(r["embedding"]), "face_embedding": blob_to_numpy(r["face_embedding"]) if r["face_embedding"] else None, "metadata": json.loads(r["metadata"])} for r in rows]

    def stats(self, device_id: str | None = None) -> dict[str, int]:
        clause, params = (" WHERE device_id=?", (device_id,)) if device_id else ("", ())
        photos = self.conn.execute("SELECT count(*) FROM photos" + clause, params).fetchone()[0]
        return {"indexed_photos": photos, "concepts": self.conn.execute("SELECT count(*) FROM personal_concepts").fetchone()[0], "feedback": self.conn.execute("SELECT count(*) FROM search_feedback").fetchone()[0]}

    def set_me(self, embedding: np.ndarray) -> None:
        self.conn.execute("INSERT OR REPLACE INTO face_identities(id,name,aliases,embedding,updated_at) VALUES('me','yo','[\"yo\",\"mí\",\"mía\",\"mío\",\"mi persona\"]',?,CURRENT_TIMESTAMP)", (numpy_to_blob(embedding),)); self.conn.commit()

    def me(self) -> np.ndarray | None:
        row = self.conn.execute("SELECT embedding FROM face_identities WHERE id='me'").fetchone()
        return blob_to_numpy(row[0]) if row else None

    def create_concept(self, concept_id: str, name: str, aliases: list[str], prototype: np.ndarray, examples: list[np.ndarray]) -> None:
        self.conn.execute("INSERT OR REPLACE INTO personal_concepts(id,name,aliases,prototype_embedding) VALUES(?,?,?,?)", (concept_id, name, json.dumps(aliases), numpy_to_blob(prototype)))
        self.conn.execute("DELETE FROM concept_examples WHERE concept_id=?", (concept_id,))
        self.conn.executemany("INSERT INTO concept_examples(concept_id,embedding) VALUES(?,?)", [(concept_id, numpy_to_blob(e)) for e in examples]); self.conn.commit()

    def concepts(self) -> list[dict[str, Any]]:
        return [{"id": r["id"], "name": r["name"], "aliases": json.loads(r["aliases"]), "embedding": blob_to_numpy(r["prototype_embedding"])} for r in self.conn.execute("SELECT * FROM personal_concepts").fetchall()]

    def delete_concept(self, concept_id: str) -> None:
        self.conn.execute("DELETE FROM concept_examples WHERE concept_id=?", (concept_id,)); self.conn.execute("DELETE FROM personal_concepts WHERE id=?", (concept_id,)); self.conn.commit()

    def add_feedback(self, device_id: str, query: str, query_embedding: np.ndarray, asset_id: str, image_embedding: np.ndarray, relevant: bool) -> None:
        self.conn.execute("INSERT INTO search_feedback(device_id,query_text,query_embedding,asset_id,image_embedding,feedback) VALUES(?,?,?,?,?,?)", (device_id, query, numpy_to_blob(query_embedding), asset_id, numpy_to_blob(image_embedding), "positive" if relevant else "negative")); self.conn.commit()

    def feedback(self, device_id: str) -> list[dict[str, Any]]:
        return [{"query_embedding": blob_to_numpy(r["query_embedding"]), "asset_id": r["asset_id"], "feedback": r["feedback"]} for r in self.conn.execute("SELECT query_embedding,asset_id,feedback FROM search_feedback WHERE device_id=?", (device_id,)).fetchall()]
