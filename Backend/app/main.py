from contextlib import asynccontextmanager
import json
from typing import Annotated
import numpy as np
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from .config import settings
from .database import Database
from .models import FeedbackRequest, IndexPendingRequest, SearchRequest
from .query import QueryNormalizer
from .services import EmbeddingModel, FaceService, SearchRanker, concept_id
from .vector import normalize_embedding


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Validar/cargar CLIP antes de invalidar una DB incompatible: un fallo de
    # modelos no debe borrar un índice que todavía podría recuperarse.
    app.state.embedder = EmbeddingModel()
    app.state.db = Database(settings.database_path)
    app.state.faces = FaceService()
    app.state.normalizer = QueryNormalizer(
        translation_enabled=settings.translation_enabled,
        translation_timeout_seconds=settings.translation_timeout_seconds,
    )
    app.state.ranker = SearchRanker()
    try:
        yield
    finally:
        app.state.db.close()


app = FastAPI(title="FotoSearch", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_methods=["*"], allow_headers=["*"])

@app.get("/health")
def health():
    return {
        "status": "ok",
        "image_model": settings.clip_model,
        "text_model": settings.text_model,
        "embedding_dimension": app.state.embedder.embedding_dimension,
        "embedding_version": settings.embedding_version,
        "query_pipeline_version": settings.query_pipeline_version,
        "face_embedding_version": settings.face_embedding_version,
        "translation_enabled": settings.translation_enabled,
        "device": app.state.embedder.device,
        "face_recognition_available": app.state.faces.available,
        "index_invalidation": app.state.db.invalidation_report,
    }

@app.post("/index/image")
async def index_image(device_id: Annotated[str, Form()], asset_id: Annotated[str, Form()], image: Annotated[UploadFile, File()], modified_at: Annotated[str | None, Form()] = None, metadata: Annotated[str | None, Form()] = None):
    if app.state.db.photo_is_current(device_id, asset_id, modified_at): return {"status": "skipped", "asset_id": asset_id}
    data = await image.read()
    try:
        embedding, face = app.state.embedder.encode_image(data), app.state.faces.encode_face(data)
    except Exception as error:
        raise HTTPException(400, f"No se pudo procesar la imagen: {error}") from error
    try:
        parsed_metadata = json.loads(metadata or "{}")
        if not isinstance(parsed_metadata, dict):
            raise ValueError("debe ser un objeto JSON")
    except (json.JSONDecodeError, ValueError) as error:
        raise HTTPException(422, f"Metadatos inválidos: {error}") from error
    app.state.db.upsert_photo(device_id, asset_id, modified_at, parsed_metadata, embedding, face)
    return {"status": "indexed", "asset_id": asset_id, "face_detected": face is not None}


@app.post("/index/images")
async def index_images(
    device_id: Annotated[str, Form()],
    items: Annotated[str, Form()],
    images: list[UploadFile] = File(...),
):
    """Indexa varias miniaturas para reducir viajes de red y usar CLIP en lote."""
    try:
        entries = json.loads(items)
        if not isinstance(entries, list) or len(entries) != len(images):
            raise ValueError("los metadatos no corresponden con las imágenes")
    except (json.JSONDecodeError, ValueError) as error:
        raise HTTPException(422, f"Lote inválido: {error}") from error

    pending: list[tuple[dict, bytes]] = []
    skipped = 0
    failed = 0
    for entry, upload in zip(entries, images):
        if not isinstance(entry, dict) or not isinstance(entry.get("asset_id"), str):
            failed += 1
            continue
        modified_at = entry.get("modified_at")
        if app.state.db.photo_is_current(device_id, entry["asset_id"], modified_at):
            skipped += 1
            continue
        try:
            metadata = entry.get("metadata", {})
            if not isinstance(metadata, dict):
                raise ValueError("metadatos inválidos")
            pending.append((entry, await upload.read()))
        except Exception:
            failed += 1

    decoded: list[tuple[dict, bytes, object]] = []
    for entry, data in pending:
        try:
            decoded.append((entry, data, app.state.embedder.decode_image(data)))
        except Exception:
            failed += 1

    if not decoded:
        return {"indexed": 0, "skipped": skipped, "failed": failed}

    try:
        embeddings = app.state.embedder.encode_images([image for _, _, image in decoded])
    except Exception as error:
        raise HTTPException(500, f"No se pudo procesar el lote: {error}") from error

    records = []
    for (entry, data, _), embedding in zip(decoded, embeddings):
        try:
            face = app.state.faces.encode_face(data)
            records.append((device_id, entry["asset_id"], entry.get("modified_at"), entry.get("metadata", {}), embedding, face))
        except Exception:
            failed += 1
    app.state.db.upsert_photos(records)
    return {"indexed": len(records), "skipped": skipped, "failed": failed}

@app.get("/index/stats")
def stats(device_id: str | None = None): return app.state.db.stats(device_id)


@app.post("/index/pending")
def index_pending(request: IndexPendingRequest):
    """Devuelve solo los assets que cambiaron o que aún no están indexados.

    El teléfono consulta este estado antes de generar miniaturas. Así, repetir
    un escaneo o reanudarlo no vuelve a transferir ni a decodificar la galería.
    """
    return {
        "pending_asset_ids": [
            item.asset_id
            for item in request.items
            if not app.state.db.photo_is_current(request.device_id, item.asset_id, item.modified_at)
        ]
    }

@app.post("/search")
def search(request: SearchRequest):
    concept_definitions = app.state.db.concepts(include_unavailable=True)
    aliases = [alias for concept in concept_definitions for alias in [concept["name"], *concept["aliases"]]]
    parsed = app.state.normalizer.parse(request.query, aliases)
    active_concepts = {concept["id"]: concept for concept in app.state.db.concepts()}
    applicable = [
        concept
        for concept in concept_definitions
        if concept["id"] in active_concepts
        and any(
            alias.casefold() in {name.casefold() for name in parsed.personal_concepts}
            for alias in [concept["name"], *concept["aliases"]]
        )
    ]
    query_embeddings = app.state.embedder.encode_texts(parsed.joint_variants)
    constraint_embeddings = None
    if parsed.constraints is not None:
        # Se reutilizan exclusivamente los embeddings de las fotos indexadas;
        # aquí solo se crean textos de consulta para el reranking del Top K.
        constraint_embeddings = {
            "object": app.state.embedder.encode_text(str(parsed.constraints["object"])),
            "attribute": app.state.embedder.encode_text(str(parsed.constraints["attribute"])),
            "target_color_joint": app.state.embedder.encode_text(
                f"{parsed.constraints['color']} {parsed.constraints['object_english']}"
            ),
            "color_competitors": app.state.embedder.encode_texts(
                list(parsed.constraints["color_competitors"])
            ),
        }
    me_embedding = app.state.db.me()
    ranked = app.state.ranker.rank(
        app.state.db.photos(request.device_id),
        query_embeddings,
        me_embedding,
        applicable,
        app.state.db.feedback(request.device_id),
        parsed.requires_me,
        parsed.joint_variants,
        constraint_embeddings,
    )
    results = ranked[:request.limit]
    best_semantic = max((item["semantic_score"] for item in results), default=float("-inf"))
    low_confidence = not results or best_semantic < settings.search_confidence_threshold
    return {
        "query": request.query,
        "semantic_query": parsed.semantic_text,
        "normalized_query": parsed.semantic_text,
        "variants": parsed.variants,
        "joint_variants": parsed.joint_variants,
        "constraints": parsed.constraints,
        "results": results,
        "low_confidence": low_confidence,
        "not_confident": low_confidence,
        "requires_identity_setup": parsed.requires_me and me_embedding is None,
    }

@app.post("/feedback")
def feedback(request: FeedbackRequest):
    photo = app.state.db.photo(request.device_id, request.asset_id)
    if photo is None: raise HTTPException(404, "La foto no está indexada")
    if request.learn:
        definitions = app.state.db.concepts(include_unavailable=True)
        aliases = [alias for concept in definitions for alias in [concept["name"], *concept["aliases"]]]
        parsed = app.state.normalizer.parse(request.query, aliases)
        app.state.db.add_feedback(request.device_id, request.query, app.state.embedder.encode_text(parsed.semantic_text), request.asset_id, photo["embedding"], request.relevant)
    return {"status": "saved"}

@app.post("/feedback/correction")
async def correction(device_id: Annotated[str, Form()], query: Annotated[str, Form()], asset_id: Annotated[str, Form()], image: Annotated[UploadFile, File()], modified_at: Annotated[str | None, Form()] = None):
    data = await image.read(); embedding = app.state.embedder.encode_image(data)
    app.state.db.upsert_photo(device_id, asset_id, modified_at, {}, embedding, app.state.faces.encode_face(data))
    definitions = app.state.db.concepts(include_unavailable=True)
    aliases = [alias for concept in definitions for alias in [concept["name"], *concept["aliases"]]]
    parsed = app.state.normalizer.parse(query, aliases)
    app.state.db.add_feedback(device_id, query, app.state.embedder.encode_text(parsed.semantic_text), asset_id, embedding, True, strong=True)
    return {"status": "learned", "asset_id": asset_id}

@app.post("/identities/face/enroll")
async def enroll_me(images: list[UploadFile] = File(...)):
    if not app.state.faces.available: raise HTTPException(503, "Reconocimiento facial no disponible; instala facenet-pytorch y reinicia.")
    vectors = [app.state.faces.encode_face(await item.read()) for item in images]
    vectors = [v for v in vectors if v is not None]
    if not vectors: raise HTTPException(400, "No se detectó un rostro claro en las imágenes seleccionadas")
    app.state.db.set_me(normalize_embedding(np.mean(vectors, axis=0)))
    return {"status": "enrolled", "faces_used": len(vectors)}

@app.get("/identities/face")
def get_me(): return {"configured": app.state.db.me() is not None, "name": "yo"}

@app.post("/concepts")
async def create_concept(name: Annotated[str, Form()], aliases: Annotated[str | None, Form()] = None, images: list[UploadFile] = File(...)):
    data = [await image.read() for image in images]; vectors = [app.state.embedder.encode_image(item) for item in data]
    if not vectors: raise HTTPException(400, "Selecciona al menos una imagen")
    parsed_aliases = [a.strip() for a in (aliases or "").split(",") if a.strip()]
    identifier = concept_id(); app.state.db.create_concept(identifier, name.strip(), parsed_aliases, normalize_embedding(np.mean(vectors, axis=0)), vectors)
    return {"id": identifier, "name": name, "aliases": parsed_aliases}

@app.get("/concepts")
def concepts():
    return [
        {"id": concept["id"], "name": concept["name"], "aliases": concept["aliases"], "needs_rebuild": concept["needs_rebuild"]}
        for concept in app.state.db.concepts(include_unavailable=True)
    ]

@app.delete("/concepts/{concept_id}")
def delete_concept(concept_id: str): app.state.db.delete_concept(concept_id); return {"status": "deleted"}


def run() -> None:
    """Inicia Uvicorn usando la configuración de entorno de FotoSearch."""
    import uvicorn
    uvicorn.run("app.main:app", host=settings.host, port=settings.port, log_level=settings.log_level, reload=settings.reload)


if __name__ == "__main__":
    run()
