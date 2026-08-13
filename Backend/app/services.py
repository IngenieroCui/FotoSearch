from io import BytesIO
from uuid import uuid4
import numpy as np
from PIL import Image
from sentence_transformers import SentenceTransformer
from .config import settings
from .vector import normalize_embedding, cosine_similarity


class EmbeddingModel:
    def __init__(self) -> None:
        self.model = SentenceTransformer(settings.clip_model)

    def decode_image(self, image_bytes: bytes) -> Image.Image:
        """Decodifica completamente la imagen para detectar archivos corruptos pronto."""
        with Image.open(BytesIO(image_bytes)) as source:
            source.load()
            return source.convert("RGB")

    def encode_images(self, images: list[Image.Image]) -> list[np.ndarray]:
        for image in images:
            image.thumbnail((settings.max_image_side, settings.max_image_side))
        with __import__("torch").inference_mode():
            vectors = self.model.encode(
                images,
                batch_size=min(settings.embedding_batch_size, len(images)),
                convert_to_numpy=True,
            )
        return [normalize_embedding(vector) for vector in vectors]

    def encode_image(self, image_bytes: bytes) -> np.ndarray:
        return self.encode_images([self.decode_image(image_bytes)])[0]

    def encode_text(self, texts: list[str]) -> np.ndarray:
        with __import__("torch").inference_mode():
            vectors = self.model.encode(texts, convert_to_numpy=True)
        return normalize_embedding(np.mean(vectors, axis=0))


class FaceService:
    def __init__(self) -> None:
        self.available = False
        if not settings.enable_face_recognition:
            return
        try:
            from facenet_pytorch import MTCNN, InceptionResnetV1
            import torch
            if settings.face_device == "auto":
                self.device = "cuda:0" if torch.cuda.is_available() else "cpu"
            else:
                self.device = settings.face_device
            self.detector, self.encoder = MTCNN(keep_all=False, device=self.device), InceptionResnetV1(pretrained="vggface2").eval().to(self.device)
            self.available = True
        except Exception:
            pass

    def encode_face(self, image_bytes: bytes) -> np.ndarray | None:
        if not self.available:
            return None
        import torch
        image = Image.open(BytesIO(image_bytes)).convert("RGB")
        face = self.detector(image)
        if face is None:
            return None
        with torch.inference_mode():
            return normalize_embedding(self.encoder(face.unsqueeze(0).to(self.device)).cpu().numpy()[0])


class SearchRanker:
    def rank(self, photos, query_embedding, me_embedding, concepts, feedback, requires_me: bool):
        related_feedback = [f for f in feedback if cosine_similarity(query_embedding, f["query_embedding"]) >= settings.query_feedback_similarity_threshold]
        scored = []
        for photo in photos:
            semantic = cosine_similarity(query_embedding, photo["embedding"])
            identity = cosine_similarity(me_embedding, photo["face_embedding"]) if me_embedding is not None and photo["face_embedding"] is not None else 0.0
            if requires_me and identity < settings.face_threshold:
                identity -= 0.35
            concept_scores = [cosine_similarity(c["embedding"], photo["embedding"]) for c in concepts]
            concept = max(concept_scores, default=0.0)
            adjustment = sum((settings.positive_feedback_weight if f["feedback"] == "positive" else -settings.negative_feedback_weight) for f in related_feedback if f["asset_id"] == photo["asset_id"])
            total = settings.semantic_weight * semantic + (settings.identity_weight * identity if requires_me else 0) + (settings.concept_weight * concept if concepts else 0) + adjustment
            scored.append({"asset_id": photo["asset_id"], "score": total, "semantic_score": semantic, "identity_score": identity if requires_me else 0.0, "concept_score": concept if concepts else 0.0, "feedback_adjustment": adjustment, "metadata": photo["metadata"]})
        return sorted(scored, key=lambda item: item["score"], reverse=True)


def concept_id() -> str:
    return str(uuid4())
