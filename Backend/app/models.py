from typing import Any
from pydantic import BaseModel, Field
from .config import settings


class SearchRequest(BaseModel):
    device_id: str
    query: str = Field(min_length=1, max_length=300)
    limit: int = Field(default_factory=lambda: settings.default_search_limit, ge=1, le=settings.max_search_limit)


class FeedbackRequest(BaseModel):
    device_id: str
    query: str
    asset_id: str
    relevant: bool
    learn: bool = True


class IndexAssetState(BaseModel):
    asset_id: str
    modified_at: str | None = None


class IndexPendingRequest(BaseModel):
    device_id: str
    items: list[IndexAssetState]


class SearchResult(BaseModel):
    asset_id: str
    score: float
    semantic_score: float
    identity_score: float = 0.0
    concept_score: float = 0.0
    feedback_adjustment: float = 0.0
    metadata: dict[str, Any] = Field(default_factory=dict)
