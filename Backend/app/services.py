from io import BytesIO
from uuid import uuid4

import numpy as np
from PIL import Image
from sentence_transformers import SentenceTransformer

from .config import settings
from .vector import cosine_similarity, normalize_embedding


class EmbeddingModel:
    def __init__(self) -> None:
        # Estos dos modelos comparten el espacio CLIP ViT-B/32 de 512 dimensiones.
        self.image_model = SentenceTransformer(settings.clip_model)
        self.text_model = SentenceTransformer(settings.text_model)
        image_dimension = self.image_model.get_sentence_embedding_dimension()
        text_dimension = self.text_model.get_sentence_embedding_dimension()
        if image_dimension is not None and text_dimension is not None and image_dimension != text_dimension:
            raise RuntimeError(
                f"Modelos CLIP incompatibles: imagen={image_dimension}, texto={text_dimension}"
            )
        # SentenceTransformers no expone la dimensión del wrapper CLIP visual,
        # pero el encoder textual alineado sí (512 para ViT-B/32).
        self.embedding_dimension = int(image_dimension or text_dimension or 0)
        self.device = str(getattr(self.image_model, "device", "cpu")).split(":", 1)[0]

    def decode_image(self, image_bytes: bytes) -> Image.Image:
        """Decodifica por completo para detectar archivos corruptos pronto."""
        with Image.open(BytesIO(image_bytes)) as source:
            source.load()
            return source.convert("RGB")

    def encode_images(self, images: list[Image.Image]) -> list[np.ndarray]:
        if not images:
            return []
        for image in images:
            image.thumbnail((settings.max_image_side, settings.max_image_side))
        with __import__("torch").inference_mode():
            vectors = self.image_model.encode(
                images,
                batch_size=min(settings.embedding_batch_size, len(images)),
                convert_to_numpy=True,
            )
        return [normalize_embedding(vector) for vector in vectors]

    def encode_image(self, image_bytes: bytes) -> np.ndarray:
        return self.encode_images([self.decode_image(image_bytes)])[0]

    def encode_texts(self, texts: list[str]) -> list[np.ndarray]:
        """Codifica variantes por separado; nunca promedia intenciones."""
        if not texts:
            return []
        with __import__("torch").inference_mode():
            vectors = self.text_model.encode(texts, convert_to_numpy=True)
        return [normalize_embedding(vector) for vector in vectors]

    def encode_text(self, text: str | list[str]) -> np.ndarray:
        """Compatibilidad para los lugares que codifican exactamente un texto."""
        texts = [text] if isinstance(text, str) else text
        if len(texts) != 1:
            raise ValueError("encode_text acepta un solo texto; usa encode_texts para variantes")
        return self.encode_texts(texts)[0]


class FaceService:
    def __init__(self) -> None:
        self.available = False
        self.device = "disabled"
        if not settings.enable_face_recognition:
            return
        try:
            from facenet_pytorch import InceptionResnetV1, MTCNN
            import torch

            if settings.face_device == "auto":
                self.device = "cuda:0" if torch.cuda.is_available() else "cpu"
            else:
                self.device = settings.face_device
            self.detector = MTCNN(keep_all=False, device=self.device)
            self.encoder = InceptionResnetV1(pretrained="vggface2").eval().to(self.device)
            self.available = True
        except Exception:
            # La búsqueda semántica debe seguir disponible sin FaceNet.
            self.device = "unavailable"

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
    def __init__(self, semantic_candidates: int | None = None) -> None:
        self.semantic_candidates = semantic_candidates or settings.semantic_candidates

    @staticmethod
    def _query_vectors(query_embeddings: np.ndarray | list[np.ndarray]) -> list[np.ndarray]:
        if isinstance(query_embeddings, np.ndarray) and query_embeddings.ndim == 1:
            return [query_embeddings]
        return [np.asarray(vector) for vector in query_embeddings]

    def _feedback_adjustment(
        self,
        photo: dict,
        related_feedback: list[tuple[float, dict]],
    ) -> float:
        exact = [(similarity, item) for similarity, item in related_feedback if item["asset_id"] == photo["asset_id"]]
        if exact:
            _, strongest = max(exact, key=lambda pair: pair[0])
            if strongest["feedback"] == "negative":
                return settings.exact_negative_penalty
            if strongest.get("is_strong"):
                return settings.correction_positive_boost
            return settings.exact_positive_boost

        generalized: list[tuple[float, float]] = []
        for query_similarity, item in related_feedback:
            image_similarity = cosine_similarity(photo["embedding"], item["image_embedding"])
            if image_similarity < settings.image_feedback_similarity_threshold:
                continue
            magnitude = (
                settings.general_feedback_max_boost
                if item["feedback"] == "positive"
                else abs(settings.general_feedback_max_penalty)
            )
            signed = magnitude * image_similarity * (1.0 if item["feedback"] == "positive" else -1.0)
            generalized.append((query_similarity * image_similarity, signed))

        strongest = sorted(generalized, key=lambda pair: pair[0], reverse=True)[: settings.feedback_max_examples]
        if not strongest:
            return 0.0
        adjustment = float(np.mean([value for _, value in strongest]))
        return float(np.clip(
            adjustment,
            settings.general_feedback_max_penalty,
            settings.general_feedback_max_boost,
        ))

    def rank(
        self,
        photos: list[dict],
        query_embeddings: np.ndarray | list[np.ndarray],
        me_embedding: np.ndarray | None,
        concepts: list[dict],
        feedback: list[dict],
        requires_me: bool,
        query_variants: list[str] | None = None,
    ) -> list[dict]:
        vectors = self._query_vectors(query_embeddings)
        if not vectors:
            return []
        variants = query_variants or ["query"] * len(vectors)
        if len(variants) != len(vectors):
            raise ValueError("Cada query embedding debe conservar su variante")

        # Etapa A: exclusivamente CLIP; ninguna personalización rescata fotos fuera
        # del conjunto semántico candidato.
        semantic_candidates: list[tuple[float, str, dict]] = []
        for photo in photos:
            similarities = [cosine_similarity(photo["embedding"], vector) for vector in vectors]
            best_index = int(np.argmax(similarities))
            semantic_candidates.append((similarities[best_index], variants[best_index], photo))
        semantic_candidates.sort(key=lambda item: item[0], reverse=True)
        semantic_candidates = semantic_candidates[: self.semantic_candidates]

        related_feedback: list[tuple[float, dict]] = []
        for item in feedback:
            query_similarity = max(cosine_similarity(vector, item["query_embedding"]) for vector in vectors)
            if query_similarity >= settings.query_feedback_similarity_threshold:
                related_feedback.append((query_similarity, item))
        related_feedback.sort(key=lambda pair: pair[0], reverse=True)

        # Etapa B: identidad, conceptos y feedback limitado, solo sobre Top K.
        scored: list[dict] = []
        for semantic, best_variant, photo in semantic_candidates:
            identity = (
                cosine_similarity(me_embedding, photo["face_embedding"])
                if me_embedding is not None and photo["face_embedding"] is not None
                else 0.0
            )
            if requires_me and me_embedding is not None and identity < settings.face_threshold:
                continue

            concept = max(
                (cosine_similarity(item["embedding"], photo["embedding"]) for item in concepts),
                default=0.0,
            )
            adjustment = self._feedback_adjustment(photo, related_feedback)
            final = (
                settings.semantic_weight * semantic
                + (settings.identity_weight * max(identity, 0.0) if requires_me else 0.0)
                + (settings.concept_weight * max(concept, 0.0) if concepts else 0.0)
                + adjustment
            )
            scored.append({
                "asset_id": photo["asset_id"],
                "score": final,
                "final_score": final,
                "semantic_score": semantic,
                "relevance_score": semantic,
                "best_query_variant": best_variant,
                "identity_score": identity if requires_me else 0.0,
                "concept_score": concept if concepts else 0.0,
                "feedback_adjustment": adjustment,
                "metadata": photo["metadata"],
            })
        return sorted(scored, key=lambda item: item["final_score"], reverse=True)


def concept_id() -> str:
    return str(uuid4())
