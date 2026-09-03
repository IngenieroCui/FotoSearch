from collections import OrderedDict
from dataclasses import dataclass
import re
from queue import Empty, Queue
from threading import Lock, Thread
from typing import Callable


# "mi" / "my" alone are possessive ("mi mascota"), not identity.
_IDENTITY = re.compile(r"\b(mi persona|yo|mí|mía|mío|myself|me)\b", re.I)
_REQUEST_PREFIXES = (
    re.compile(r"^(?:por favor\s+)?(?:quiero|quisiera|busca(?:me)?|encuentra(?:me)?|mu[eé]strame|dame)\s+", re.I),
    re.compile(r"^(?:una?\s+)?(?:foto(?:graf[ií]a)?|imagen)\s+(?:de|donde|en la que|con)\s+", re.I),
    re.compile(r"^(?:donde\s+)?(?:salga|aparezca|se vea)\s+", re.I),
    re.compile(r"^(?:una?\s+)?persona\s+(?:usando|con|que lleva)\s+(?:una?\s+)?", re.I),
    re.compile(r"^(?:con|de)\s+", re.I),
)

COLORS = {
    "rojo": "red", "roja": "red", "rojos": "red", "rojas": "red",
    "azul": "blue", "azules": "blue", "verde": "green", "verdes": "green",
    "negro": "black", "negra": "black", "negros": "black", "negras": "black",
    "blanco": "white", "blanca": "white", "blancos": "white", "blancas": "white",
    "amarillo": "yellow", "amarilla": "yellow", "amarillos": "yellow", "amarillas": "yellow",
    "gris": "gray", "grises": "gray", "morado": "purple", "morada": "purple",
    "rosado": "pink", "rosada": "pink", "naranja": "orange", "café": "brown",
    "marrón": "brown", "marron": "brown",
}
CLOTHING = {
    "camiseta": "t-shirt", "camisetas": "t-shirts", "camisa": "shirt", "camisas": "shirts",
    "chaqueta": "jacket", "chaquetas": "jackets", "vestido": "dress", "vestidos": "dresses",
    "pantalón": "pants", "pantalones": "pants", "pantalon": "pants",
}
COMMON_OBJECTS = {
    "perro": "dog", "perros": "dogs", "gato": "cat", "gatos": "cats",
    "mascota": "pet", "mascotas": "pets", "cerdo": "pig", "cerdos": "pigs",
    "carro": "car", "carros": "cars", "coche": "car", "coches": "cars",
    "bicicleta": "bicycle", "bicicletas": "bicycles", "playa": "beach", "playas": "beaches",
    "parque": "park", "parques": "parks",
}


class QueryTranslationUnavailable(RuntimeError):
    """Raised when a semantic query cannot be translated to English safely."""


@dataclass
class ParsedQuery:
    original: str
    semantic_text: str
    requires_me: bool
    variants: list[str]
    constraints: dict[str, object] | None = None

    @property
    def joint_variants(self) -> list[str]:
        return self.variants


def _deduplicate(values: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        normalized = re.sub(r"\s+", " ", value).strip()
        key = normalized.casefold()
        if normalized and key not in seen:
            seen.add(key)
            result.append(normalized)
    return result


def _shorten_request(text: str) -> str:
    previous = None
    while text != previous:
        previous = text
        for pattern in _REQUEST_PREFIXES:
            text = pattern.sub("", text).strip()
    return text


def _compositional_constraints(semantic: str) -> dict[str, object] | None:
    """Detect a known color + object in the source query.

    Detection may happen in Spanish, but every value later encoded by
    MobileCLIP is converted to its canonical English representation.
    """
    colors = {**COLORS, **{value: value for value in COLORS.values()}}
    objects = {
        **CLOTHING,
        **COMMON_OBJECTS,
        **{value: value for value in [*CLOTHING.values(), *COMMON_OBJECTS.values()]},
    }

    def find(vocabulary: dict[str, str]) -> tuple[str, str] | None:
        matches: list[tuple[int, str, str]] = []
        for term, canonical in vocabulary.items():
            match = re.search(r"\b" + re.escape(term) + r"\b", semantic, re.I)
            if match:
                matches.append((match.start(), term, canonical))
        if not matches:
            return None
        _, term, canonical = min(matches, key=lambda item: item[0])
        return term, canonical

    color = find(colors)
    # Clothing has priority when the query mentions a person wearing clothing.
    object_ = find({**CLOTHING, **{value: value for value in CLOTHING.values()}}) or find(objects)
    if color is None or object_ is None:
        return None
    object_term, object_english = object_
    color_term, color_english = color
    competitors = _deduplicate(
        [
            f"{alternative} {object_english}"
            for alternative in sorted(set(COLORS.values()))
            if alternative != color_english
        ]
    )
    return {
        "object": object_term,
        "attribute": color_term,
        "color": color_english,
        "object_english": object_english,
        "color_competitors": competitors,
    }


class QueryNormalizer:
    def __init__(
        self,
        translation_enabled: bool = True,
        translator: Callable[[str], str] | None = None,
        translation_timeout_seconds: float = 4.0,
        translation_cache_size: int = 256,
    ):
        self.translation_enabled = translation_enabled
        self._translator = translator
        self.translation_timeout_seconds = translation_timeout_seconds
        self.translation_cache_size = max(1, translation_cache_size)
        self._translation_cache: OrderedDict[str, str] = OrderedDict()
        self._translation_cache_lock = Lock()

    def _cached_translation(self, text: str) -> str | None:
        key = text.casefold()
        with self._translation_cache_lock:
            value = self._translation_cache.get(key)
            if value is not None:
                self._translation_cache.move_to_end(key)
            return value

    def _store_translation(self, source: str, english: str) -> None:
        key = source.casefold()
        with self._translation_cache_lock:
            self._translation_cache[key] = english
            self._translation_cache.move_to_end(key)
            while len(self._translation_cache) > self.translation_cache_size:
                self._translation_cache.popitem(last=False)

    def _translate_to_english(self, text: str) -> str:
        normalized_source = re.sub(r"\s+", " ", text).strip()
        if not normalized_source:
            raise QueryTranslationUnavailable("query translation produced no source text")
        # Internal fallback used when the personal part consumes the whole query.
        if normalized_source.casefold() == "photo":
            return "photo"
        if not self.translation_enabled:
            raise QueryTranslationUnavailable("English query translation is disabled")

        cached = self._cached_translation(normalized_source)
        if cached is not None:
            return cached

        result: Queue[tuple[bool, str | None]] = Queue(maxsize=1)

        def translate() -> None:
            try:
                if self._translator is not None:
                    value = self._translator(normalized_source)
                else:
                    from deep_translator import GoogleTranslator

                    value = GoogleTranslator(source="auto", target="en").translate(normalized_source)
                result.put((True, value))
            except Exception as error:  # pragma: no cover - real network/provider path
                result.put((False, str(error)))

        Thread(target=translate, daemon=True).start()
        try:
            ok, value = result.get(timeout=self.translation_timeout_seconds)
        except Empty as error:
            raise QueryTranslationUnavailable("query translation timed out") from error

        if not ok:
            raise QueryTranslationUnavailable("query translation failed")
        english = re.sub(r"\s+", " ", (value or "")).strip().lower()
        if not english:
            raise QueryTranslationUnavailable("query translation returned an empty result")
        self._store_translation(normalized_source, english)
        return english

    def parse(self, query: str, concept_names: list[str]) -> ParsedQuery:
        cleaned = re.sub(r"\s+", " ", query.strip().lower())
        requires_me = bool(_IDENTITY.search(cleaned))
        cleaned = _IDENTITY.sub(" ", cleaned)

        for name in sorted(concept_names, key=len, reverse=True):
            pattern = re.compile(r"\b" + re.escape(name.lower()) + r"\b", re.I)
            if pattern.search(cleaned):
                requires_me = True

        source_semantic = _shorten_request(re.sub(r"\s+", " ", cleaned).strip()) or "photo"
        english_semantic = self._translate_to_english(source_semantic)
        constraints = _compositional_constraints(source_semantic)

        # From this point onward, variants are English-only. The original/source
        # text is kept only for display and source-language constraint detection.
        variants: list[str] = [english_semantic]

        if constraints is not None:
            canonical_joint = f"{constraints['color']} {constraints['object_english']}"
            variants.append(canonical_joint)
            object_english = str(constraints["object_english"])
            if object_english in set(CLOTHING.values()):
                variants.append(f"a photo of a person wearing {canonical_joint}")
            else:
                variants.append(f"a photo of {canonical_joint}")
        else:
            variants.append(f"a photo of {english_semantic}")

        return ParsedQuery(
            original=query,
            semantic_text=english_semantic,
            requires_me=requires_me,
            variants=_deduplicate(variants),
            constraints=constraints,
        )
