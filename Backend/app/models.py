from typing import Annotated

from pydantic import BaseModel, Field, field_validator

MobileClipEmbedding = Annotated[list[float], Field(min_length=512, max_length=512)]


class MobileClipQueryPlanRequest(BaseModel):
    query: str = Field(min_length=1, max_length=300)
    concept_names: list[str] = Field(default_factory=list)

    @field_validator("query")
    @classmethod
    def clean_query(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("query must not be empty")
        return value

    @field_validator("concept_names", mode="before")
    @classmethod
    def clean_concept_names(cls, value: object) -> object:
        if not isinstance(value, list):
            return value
        names = [item.strip() for item in value if isinstance(item, str) and item.strip()]
        if any(len(item) > 100 for item in names):
            raise ValueError("concept names must be at most 100 characters")
        if len(names) > 50:
            raise ValueError("at most 50 concept names are allowed")
        return list(dict.fromkeys(names))


class MobileClipTextConstraint(BaseModel):
    text: str
    embedding: MobileClipEmbedding


class MobileClipQueryConstraints(BaseModel):
    object: MobileClipTextConstraint | None = None
    attribute: MobileClipTextConstraint | None = None
    target_color_joint: MobileClipTextConstraint | None = None
    color_competitors: list[MobileClipTextConstraint] = Field(default_factory=list)


class MobileClipQueryPlanResponse(BaseModel):
    embedding_version: str
    query_pipeline_version: str
    original: str
    semantic_text: str
    requires_me: bool
    variants: list[str]
    joint_variants: list[str]
    query_embeddings: list[MobileClipEmbedding]
    constraints: MobileClipQueryConstraints
