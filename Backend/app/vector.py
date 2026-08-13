import numpy as np


def normalize_embedding(vector: np.ndarray) -> np.ndarray:
    vector = np.asarray(vector, dtype=np.float32).reshape(-1)
    norm = float(np.linalg.norm(vector))
    return vector if norm == 0 else vector / norm


def numpy_to_blob(vector: np.ndarray) -> bytes:
    return normalize_embedding(vector).astype(np.float32).tobytes()


def blob_to_numpy(blob: bytes) -> np.ndarray:
    return np.frombuffer(blob, dtype=np.float32).copy()


def cosine_similarity(left: np.ndarray, right: np.ndarray) -> float:
    return float(np.dot(normalize_embedding(left), normalize_embedding(right)))
