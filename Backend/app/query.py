from dataclasses import dataclass
import re
from queue import Empty, Queue
from threading import Thread
from typing import Callable


# "mi" / "my" por sí solos son posesivos ("mi mascota"), no identidad.
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
}
CLOTHING = {
    "camiseta": "t-shirt", "camisetas": "t-shirts", "camisa": "shirt", "camisas": "shirts",
    "chaqueta": "jacket", "chaquetas": "jackets", "vestido": "dress", "vestidos": "dresses",
    "pantalón": "pants", "pantalones": "pants",
}
COMMON_OBJECTS = {
    "perro": "dog", "perros": "dogs", "gato": "cat", "gatos": "cats",
    "mascota": "pet", "mascotas": "pets", "carro": "car", "carros": "cars",
    "coche": "car", "coches": "cars", "bicicleta": "bicycle", "bicicletas": "bicycles",
    "playa": "beach", "playas": "beaches", "parque": "park", "parques": "parks",
}
_OTHER_WORDS = {
    "persona": "person", "personas": "people", "con": "with", "en": "at",
    "de": "of", "la": "", "el": "", "los": "", "las": "", "y": "and",
}


@dataclass
class ParsedQuery:
    original: str
    semantic_text: str
    requires_me: bool
    variants: list[str]
    constraints: dict[str, object] | None = None

    @property
    def joint_variants(self) -> list[str]:
        """Nombre explícito para las variantes que representan la intención completa."""
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


def _local_english(text: str) -> str | None:
    """Traduce únicamente el vocabulario visual pequeño y conocido."""
    translated = text
    changed = False

    # En español el color suele seguir a la prenda; en inglés la precede.
    clothing_words = "|".join(sorted(map(re.escape, CLOTHING), key=len, reverse=True))
    color_words = "|".join(sorted(map(re.escape, COLORS), key=len, reverse=True))

    def clothing_color(match: re.Match[str]) -> str:
        nonlocal changed
        changed = True
        return f"{COLORS[match.group(2)]} {CLOTHING[match.group(1)]}"

    translated = re.sub(rf"\b({clothing_words})\s+({color_words})\b", clothing_color, translated)
    vocabulary = {**CLOTHING, **COLORS, **COMMON_OBJECTS, **_OTHER_WORDS}
    for spanish, english in sorted(vocabulary.items(), key=lambda item: -len(item[0])):
        replaced = re.sub(r"\b" + re.escape(spanish) + r"\b", english, translated)
        if replaced != translated:
            changed = True
            translated = replaced
    return re.sub(r"\s+", " ", translated).strip() if changed else None


def _compositional_constraints(semantic: str) -> dict[str, object] | None:
    """Detecta objecto + color sin convertir sus partes en queries equivalentes.

    Las variantes conjuntas siguen siendo la señal de recuperación. Estas
    restricciones se codifican aparte para el soft-AND del reranking.
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
    # La ropa tiene prioridad: en "persona con camiseta roja" el objeto es la
    # camiseta, no la persona implícita en la variante conjunta.
    object_ = find({**CLOTHING, **{value: value for value in CLOTHING.values()}}) or find(objects)
    if color is None or object_ is None:
        return None
    object_term, object_english = object_
    color_term, color_english = color
    competitors = _deduplicate(
        f"{alternative} {object_english}"
        for alternative in sorted(set(COLORS.values()))
        if alternative != color_english
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
        translation_enabled: bool = False,
        translator: Callable[[str], str] | None = None,
        translation_timeout_seconds: float = 2.0,
    ):
        self.translation_enabled = translation_enabled
        self._translator = translator
        self.translation_timeout_seconds = translation_timeout_seconds

    def _optional_translation(self, text: str) -> str | None:
        if not self.translation_enabled:
            return None
        result: Queue[str | None] = Queue(maxsize=1)

        def translate() -> None:
            try:
                if self._translator is not None:
                    value = self._translator(text)
                else:
                    from deep_translator import GoogleTranslator
                    value = GoogleTranslator(source="auto", target="en").translate(text)
                result.put(value)
            except Exception:
                result.put(None)

        # Daemon evita que una caída de Google bloquee el proceso o la búsqueda.
        Thread(target=translate, daemon=True).start()
        try:
            return result.get(timeout=self.translation_timeout_seconds)
        except Empty:
            return None

    def parse(self, query: str, concept_names: list[str]) -> ParsedQuery:
        cleaned = re.sub(r"\s+", " ", query.strip().lower())
        requires_me = bool(_IDENTITY.search(cleaned))
        cleaned = _IDENTITY.sub(" ", cleaned)

        for name in sorted(concept_names, key=len, reverse=True):
            pattern = re.compile(r"\b" + re.escape(name.lower()) + r"\b", re.I)
            if pattern.search(cleaned):
                # Los conceptos personalizados fueron retirados del MVP. La app
                # consume requires_me para informar el estado sin ejecutar una
                # búsqueda semántica incompleta o un fallback legacy.
                requires_me = True

        semantic = _shorten_request(re.sub(r"\s+", " ", cleaned).strip()) or "photo"
        local_english = _local_english(semantic)
        variants = [semantic]
        has_clothing = any(
            re.search(r"\b" + re.escape(word) + r"\b", semantic)
            for word in [*CLOTHING, *CLOTHING.values()]
        )
        if has_clothing and not re.search(r"\b(persona|person|people)\b", semantic):
            is_spanish_clothing = any(
                re.search(r"\b" + re.escape(word) + r"\b", semantic) for word in CLOTHING
            )
            variants.append(
                f"persona con {semantic}" if is_spanish_clothing else f"person wearing {semantic}"
            )
        english_variants = _deduplicate(
            [item for item in [local_english, self._optional_translation(semantic)] if item]
        )
        for english in english_variants:
            variants.append(english)
            if has_clothing:
                variants.append(f"a photo of a person wearing {english}")
            else:
                variants.append(f"a photo of {english}")
        if not english_variants:
            variants.append(
                f"a photo of a person wearing {semantic}" if has_clothing else f"a photo of {semantic}"
            )

        return ParsedQuery(
            query,
            semantic,
            requires_me,
            _deduplicate(variants),
            _compositional_constraints(semantic),
        )
