"""Configuración centralizada de FotoSearch.

Los valores se leen desde variables de entorno. Para desarrollo local se carga
automáticamente ``Backend/.env`` cuando existe; ese archivo no debe contener
secretos que se vayan a publicar.
"""

from dataclasses import dataclass
import os
from pathlib import Path

from dotenv import load_dotenv


BACKEND_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(BACKEND_ROOT / ".env")


def _text(name: str, default: str) -> str:
    return os.getenv(name, default).strip() or default


def _integer(name: str, default: int, *, minimum: int | None = None) -> int:
    try:
        value = int(_text(name, str(default)))
    except ValueError as error:
        raise ValueError(f"{name} debe ser un número entero") from error
    if minimum is not None and value < minimum:
        raise ValueError(f"{name} debe ser mayor o igual a {minimum}")
    return value


def _number(name: str, default: float) -> float:
    try:
        return float(_text(name, str(default)))
    except ValueError as error:
        raise ValueError(f"{name} debe ser un número") from error


def _flag(name: str, default: bool = False) -> bool:
    value = _text(name, str(default)).lower()
    if value in {"1", "true", "yes", "on", "si", "sí"}:
        return True
    if value in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"{name} debe ser true o false")


def _origins() -> list[str]:
    return [origin.strip() for origin in _text("FOTOSEARCH_CORS_ORIGINS", "*").split(",") if origin.strip()]


@dataclass(frozen=True)
class Settings:
    # Servidor y red
    host: str
    port: int
    log_level: str
    reload: bool
    cors_origins: list[str]

    # Datos y modelos
    database_path: str
    clip_model: str
    max_image_side: int
    embedding_batch_size: int
    enable_face_recognition: bool
    face_device: str

    # Ranking
    semantic_weight: float
    identity_weight: float
    concept_weight: float
    positive_feedback_weight: float
    negative_feedback_weight: float
    face_threshold: float
    query_feedback_similarity_threshold: float
    search_confidence_threshold: float
    default_search_limit: int
    max_search_limit: int

    @classmethod
    def from_environment(cls) -> "Settings":
        database_path = _text("FOTOSEARCH_DB", str(BACKEND_ROOT / "data" / "fotosearch.db"))
        return cls(
            host=_text("FOTOSEARCH_HOST", "0.0.0.0"),
            port=_integer("FOTOSEARCH_PORT", 8000, minimum=1),
            log_level=_text("FOTOSEARCH_LOG_LEVEL", "info").lower(),
            reload=_flag("FOTOSEARCH_RELOAD"),
            cors_origins=_origins(),
            database_path=database_path,
            clip_model=_text("FOTOSEARCH_CLIP_MODEL", "clip-ViT-B-32"),
            max_image_side=_integer("FOTOSEARCH_MAX_IMAGE_SIDE", 768, minimum=64),
            embedding_batch_size=_integer("FOTOSEARCH_EMBEDDING_BATCH_SIZE", 48, minimum=1),
            enable_face_recognition=_flag("FOTOSEARCH_ENABLE_FACE_RECOGNITION", True),
            face_device=_text("FOTOSEARCH_FACE_DEVICE", "auto").lower(),
            semantic_weight=_number("FOTOSEARCH_SEMANTIC_WEIGHT", 0.68),
            identity_weight=_number("FOTOSEARCH_IDENTITY_WEIGHT", 0.24),
            concept_weight=_number("FOTOSEARCH_CONCEPT_WEIGHT", 0.20),
            positive_feedback_weight=_number("FOTOSEARCH_POSITIVE_FEEDBACK_WEIGHT", 0.16),
            negative_feedback_weight=_number("FOTOSEARCH_NEGATIVE_FEEDBACK_WEIGHT", 0.18),
            face_threshold=_number("FOTOSEARCH_FACE_THRESHOLD", 0.68),
            query_feedback_similarity_threshold=_number("FOTOSEARCH_QUERY_FEEDBACK_THRESHOLD", 0.72),
            search_confidence_threshold=_number("FOTOSEARCH_SEARCH_CONFIDENCE_THRESHOLD", 0.22),
            default_search_limit=_integer("FOTOSEARCH_DEFAULT_SEARCH_LIMIT", 20, minimum=1),
            max_search_limit=_integer("FOTOSEARCH_MAX_SEARCH_LIMIT", 100, minimum=1),
        )


settings = Settings.from_environment()
