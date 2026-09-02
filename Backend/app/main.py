from __future__ import annotations

from contextlib import asynccontextmanager
import logging
import re

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from .mobileclip_text import (
    MOBILECLIP_TEXT_EMBEDDING_VERSION,
    MobileClipTextEncoder,
    MobileClipTextModelUnavailable,
)
from .models import (
    MobileClipQueryConstraints,
    MobileClipQueryPlanRequest,
    MobileClipQueryPlanResponse,
    MobileClipTextConstraint,
)
from .query import QueryNormalizer

logger = logging.getLogger(__name__)
QUERY_PIPELINE_VERSION = "query-v4-compositional"


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup is eager: a deployment missing a bundled model is degraded;
    # no request downloads artifacts or falls back to a legacy service.
    app.state.normalizer = QueryNormalizer()
    try:
        app.state.mobileclip_text_encoder = MobileClipTextEncoder()
    except MobileClipTextModelUnavailable:
        logger.exception("MobileCLIP text model is unavailable")
        app.state.mobileclip_text_encoder = None
    yield


app = FastAPI(title="FotoSearch", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
)


@app.get("/api/health")
def health() -> dict[str, object]:
    available = getattr(app.state, "mobileclip_text_encoder", None) is not None
    return {
        "status": "ok" if available else "degraded",
        "mobileclip_text_available": available,
        "embedding_version": MOBILECLIP_TEXT_EMBEDDING_VERSION,
        "query_pipeline_version": QUERY_PIPELINE_VERSION,
    }


def _embedding_key(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip().casefold()


def _embeddings(texts: list[str]) -> dict[str, list[float]]:
    encoder = getattr(app.state, "mobileclip_text_encoder", None)
    if encoder is None:
        raise HTTPException(503, "MobileCLIP text model is not available")
    unique: list[str] = []
    seen: set[str] = set()
    for text in texts:
        key = _embedding_key(text)
        if key not in seen:
            seen.add(key)
            unique.append(text)
    vectors = encoder.encode(unique)
    if vectors.shape != (len(unique), 512):
        logger.error("MobileCLIP encoder returned invalid shape %s", vectors.shape)
        raise HTTPException(500, "MobileCLIP text encoder returned an invalid vector")
    return {
        _embedding_key(text): [float(value) for value in vector]
        for text, vector in zip(unique, vectors, strict=True)
    }


@app.post("/api/mobileclip/query-plan", response_model=MobileClipQueryPlanResponse)
def mobileclip_query_plan(request: MobileClipQueryPlanRequest) -> MobileClipQueryPlanResponse:
    """Normalize a query and return text vectors; photographs remain on-device."""
    parsed = app.state.normalizer.parse(request.query, request.concept_names)
    raw = parsed.constraints
    object_text = str(raw["object"]) if raw else None
    attribute_text = str(raw["attribute"]) if raw else None
    target_color_joint_text = f"{raw['color']} {raw['object_english']}" if raw else None
    competitor_texts = list(raw["color_competitors"]) if raw else []
    texts = [*parsed.joint_variants, *competitor_texts]
    texts.extend(text for text in (object_text, attribute_text, target_color_joint_text) if text)
    embeddings = _embeddings(texts)

    def constraint(text: str | None) -> MobileClipTextConstraint | None:
        return None if text is None else MobileClipTextConstraint(
            text=text, embedding=embeddings[_embedding_key(text)]
        )

    return MobileClipQueryPlanResponse(
        embedding_version=MOBILECLIP_TEXT_EMBEDDING_VERSION,
        query_pipeline_version=QUERY_PIPELINE_VERSION,
        original=request.query,
        semantic_text=parsed.semantic_text,
        requires_me=parsed.requires_me,
        variants=parsed.variants,
        joint_variants=parsed.joint_variants,
        query_embeddings=[embeddings[_embedding_key(text)] for text in parsed.joint_variants],
        constraints=MobileClipQueryConstraints(
            object=constraint(object_text),
            attribute=constraint(attribute_text),
            target_color_joint=constraint(target_color_joint_text),
            color_competitors=[constraint(text) for text in competitor_texts],
        ),
    )
