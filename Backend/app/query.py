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

# Deterministic visual vocabulary.  These are deliberately canonical rather
# than "translation hints": Spanish and English aliases resolve to the exact
# same English token before MobileCLIP sees anything.
SPANISH_CANONICAL = {
    # Colors
    "rojo": "red", "roja": "red", "rojos": "red", "rojas": "red",
    "azul": "blue", "azules": "blue", "verde": "green", "verdes": "green",
    "negro": "black", "negra": "black", "negros": "black", "negras": "black",
    "blanco": "white", "blanca": "white", "blancos": "white", "blancas": "white",
    "amarillo": "yellow", "amarilla": "yellow", "amarillos": "yellow", "amarillas": "yellow",
    "gris": "gray", "grises": "gray", "morado": "purple", "morada": "purple",
    "morados": "purple", "moradas": "purple", "rosado": "pink", "rosada": "pink",
    "rosados": "pink", "rosadas": "pink", "naranja": "orange", "café": "brown",
    "cafe": "brown", "marrón": "brown", "marron": "brown",

    # People
    "mujer": "woman", "mujeres": "women", "hombre": "man", "hombres": "men",
    "persona": "person", "personas": "people", "niño": "child", "niña": "child",
    "niños": "children", "niñas": "children", "bebé": "baby", "bebe": "baby",
    "familia": "family", "pareja": "couple", "amigo": "friend", "amiga": "friend",
    "amigos": "friends", "amigas": "friends",

    # Animals
    "perro": "dog", "perros": "dogs", "gato": "cat", "gatos": "cats",
    "mascota": "pet", "mascotas": "pets", "cerdo": "pig", "cerdos": "pigs",
    "caballo": "horse", "caballos": "horses", "pájaro": "bird", "pajaro": "bird",
    "pájaros": "birds", "pajaros": "birds",

    # Clothing
    "camiseta": "t-shirt", "camisetas": "t-shirts", "camisa": "shirt", "camisas": "shirts",
    "chaqueta": "jacket", "chaquetas": "jackets", "vestido": "dress", "vestidos": "dresses",
    "pantalón": "pants", "pantalon": "pants", "pantalones": "pants",
    "falda": "skirt", "faldas": "skirts", "zapatos": "shoes", "tenis": "sneakers",
    "sombrero": "hat", "sombreros": "hats",

    # Objects / transport
    "carro": "car", "carros": "cars", "coche": "car", "coches": "cars",
    "moto": "motorcycle", "motos": "motorcycles", "motocicleta": "motorcycle",
    "motocicletas": "motorcycles", "bicicleta": "bicycle", "bicicletas": "bicycles",
    "computador": "computer", "computadora": "computer", "celular": "phone",
    "teléfono": "phone", "telefono": "phone", "mesa": "table", "mesas": "tables",
    "silla": "chair", "sillas": "chairs", "gafas": "glasses", "lentes": "glasses",
    "mochila": "backpack", "mochilas": "backpacks",

    # Places / context
    "playa": "beach", "playas": "beaches", "parque": "park", "parques": "parks",
    "casa": "home", "restaurante": "restaurant", "restaurantes": "restaurants",
    "calle": "street", "ciudad": "city", "campo": "countryside", "montaña": "mountain",
    "montanas": "mountains", "piscina": "pool", "colegio": "school",
    "universidad": "university", "comida": "food", "fiesta": "party",
    "cumpleaños": "birthday", "cumpleanos": "birthday", "noche": "night",
    "día": "daytime", "dia": "daytime", "lluvia": "rain",

    # Actions
    "sonriendo": "smiling", "corriendo": "running", "caminando": "walking",
    "comiendo": "eating", "jugando": "playing", "sentado": "sitting",
    "sentada": "sitting", "parado": "standing", "parada": "standing",
    "abrazando": "hugging",
}

# English aliases are canonicalized too.  This is what guarantees that the
# English control query and its Spanish translation reach MobileCLIP identically.
ENGLISH_CANONICAL = {
    "red": "red", "blue": "blue", "green": "green", "black": "black",
    "white": "white", "yellow": "yellow", "gray": "gray", "grey": "gray",
    "purple": "purple", "pink": "pink", "orange": "orange", "brown": "brown",
    "woman": "woman", "women": "women", "female": "woman",
    "man": "man", "men": "men", "male": "man", "person": "person", "people": "people",
    "child": "child", "children": "children", "baby": "baby", "family": "family",
    "couple": "couple", "friend": "friend", "friends": "friends",
    "dog": "dog", "dogs": "dogs", "cat": "cat", "cats": "cats", "pet": "pet",
    "pets": "pets", "pig": "pig", "pigs": "pigs", "horse": "horse", "horses": "horses",
    "bird": "bird", "birds": "birds", "t-shirt": "t-shirt", "t-shirts": "t-shirts",
    "tshirt": "t-shirt", "tshirts": "t-shirts", "shirt": "shirt", "shirts": "shirts",
    "jacket": "jacket", "jackets": "jackets", "dress": "dress", "dresses": "dresses",
    "pants": "pants", "skirt": "skirt", "skirts": "skirts", "shoes": "shoes",
    "sneakers": "sneakers", "hat": "hat", "hats": "hats", "car": "car", "cars": "cars",
    "automobile": "car", "motorcycle": "motorcycle", "motorcycles": "motorcycles",
    "bicycle": "bicycle", "bicycles": "bicycles", "computer": "computer", "phone": "phone",
    "table": "table", "tables": "tables", "chair": "chair", "chairs": "chairs",
    "glasses": "glasses", "backpack": "backpack", "backpacks": "backpacks",
    "beach": "beach", "beaches": "beaches", "park": "park", "parks": "parks",
    "home": "home", "restaurant": "restaurant", "restaurants": "restaurants",
    "street": "street", "city": "city", "countryside": "countryside", "mountain": "mountain",
    "mountains": "mountains", "pool": "pool", "school": "school", "university": "university",
    "food": "food", "party": "party", "birthday": "birthday", "night": "night",
    "daytime": "daytime", "rain": "rain", "smiling": "smiling", "running": "running",
    "walking": "walking", "eating": "eating", "playing": "playing", "sitting": "sitting",
    "standing": "standing", "hugging": "hugging",
}

# Only used to decide whether a short phrase can be translated deterministically
# without contacting Google. They are also canonicalized into natural English.
SPANISH_CONNECTORS = {
    "un": "a", "una": "a", "unos": "some", "unas": "some", "con": "with",
    "en": "in", "de": "of", "del": "of the", "y": "and", "al": "at the",
    "el": "the", "la": "the", "los": "the", "las": "the",
}
ENGLISH_CONNECTORS = {
    "a", "an", "the", "with", "in", "at", "of", "and", "on", "wearing", "some",
}

COLORS_EN = {
    "red", "blue", "green", "black", "white", "yellow", "gray", "purple", "pink", "orange", "brown"
}
OBJECTS_EN = {
    "t-shirt", "t-shirts", "shirt", "shirts", "jacket", "jackets", "dress", "dresses",
    "pants", "skirt", "skirts", "shoes", "sneakers", "hat", "hats", "dog", "dogs",
    "cat", "cats", "pet", "pets", "pig", "pigs", "horse", "horses", "bird", "birds",
    "car", "cars", "motorcycle", "motorcycles", "bicycle", "bicycles", "phone", "computer",
}
CLOTHING_EN = {
    "t-shirt", "t-shirts", "shirt", "shirts", "jacket", "jackets", "dress", "dresses",
    "pants", "skirt", "skirts", "shoes", "sneakers", "hat", "hats",
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


def _normalize_space(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip().lower()


def _deduplicate(values: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        normalized = _normalize_space(value)
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


def _canonicalize_english(text: str) -> str:
    """Canonicalize English aliases without changing the semantic language."""
    text = _normalize_space(text)
    # Normalize multiword spellings before token processing.
    text = re.sub(r"\btee[ -]?shirt\b", "t-shirt", text)
    text = re.sub(r"\bt[ -]?shirt\b", "t-shirt", text)
    tokens = text.split()
    canonical = [ENGLISH_CANONICAL.get(token, token) for token in tokens]
    return _normalize_space(" ".join(canonical))


def _known_english_phrase(text: str) -> str | None:
    """Return canonical English when every content token is already known English."""
    normalized = _canonicalize_english(text)
    tokens = normalized.split()
    if not tokens:
        return None
    for token in tokens:
        if token in ENGLISH_CONNECTORS:
            continue
        if token not in ENGLISH_CANONICAL.values():
            return None
    return normalized


def _known_spanish_translation(text: str) -> str | None:
    """Translate a fully-known Spanish visual phrase deterministically.

    This path makes common one-word queries independent of external language
    detection: azul/blue, negro/black, mujer/woman, hombre/man, cerdo/pig, etc.
    """
    normalized = _normalize_space(text)
    tokens = normalized.split()
    if not tokens:
        return None
    translated: list[str] = []
    for token in tokens:
        if token in SPANISH_CANONICAL:
            translated.append(SPANISH_CANONICAL[token])
        elif token in SPANISH_CONNECTORS:
            translated.extend(SPANISH_CONNECTORS[token].split())
        else:
            return None
    english = _canonicalize_english(" ".join(translated))

    # Canonical Spanish COLOR + OBJECT becomes natural English OBJECT order.
    # Example: "perro negro" -> "black dog" and "camiseta roja" -> "red t-shirt".
    source_tokens = normalized.split()
    if len(source_tokens) == 2:
        first = SPANISH_CANONICAL.get(source_tokens[0])
        second = SPANISH_CANONICAL.get(source_tokens[1])
        if first in OBJECTS_EN and second in COLORS_EN:
            return f"{second} {first}"
    return english


def _compositional_constraints(english_semantic: str) -> dict[str, object] | None:
    """Detect color + object exclusively from canonical English semantic text."""
    normalized = _canonicalize_english(english_semantic)

    def find_term(terms: set[str]) -> str | None:
        matches: list[tuple[int, str]] = []
        for term in sorted(terms, key=len, reverse=True):
            match = re.search(r"\b" + re.escape(term) + r"\b", normalized, re.I)
            if match:
                matches.append((match.start(), term))
        if not matches:
            return None
        return min(matches, key=lambda item: item[0])[1]

    color = find_term(COLORS_EN)
    object_ = find_term(CLOTHING_EN) or find_term(OBJECTS_EN)
    if color is None or object_ is None:
        return None
    competitors = _deduplicate(
        [f"{alternative} {object_}" for alternative in sorted(COLORS_EN) if alternative != color]
    )
    return {
        "object": object_,
        "attribute": color,
        "color": color,
        "object_english": object_,
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
        normalized_source = _normalize_space(text)
        if not normalized_source:
            raise QueryTranslationUnavailable("query translation produced no source text")
        if normalized_source == "photo":
            return "photo"

        cached = self._cached_translation(normalized_source)
        if cached is not None:
            return cached

        # 1) Known English goes directly to the canonical English representation.
        known_english = _known_english_phrase(normalized_source)
        if known_english is not None:
            self._store_translation(normalized_source, known_english)
            return known_english

        # 2) Known Spanish visual vocabulary is deterministic and requires no
        # provider/language auto-detection. This is the critical equivalence path.
        known_spanish = _known_spanish_translation(normalized_source)
        if known_spanish is not None:
            self._store_translation(normalized_source, known_spanish)
            return known_spanish

        # 3) Everything else in the Spanish-first app goes through the translator.
        if not self.translation_enabled:
            raise QueryTranslationUnavailable("English query translation is disabled")

        result: Queue[tuple[bool, str | None]] = Queue(maxsize=1)

        def translate() -> None:
            try:
                if self._translator is not None:
                    value = self._translator(normalized_source)
                else:
                    from deep_translator import GoogleTranslator

                    # FotoSearch is Spanish-first. Explicit Spanish source avoids
                    # Google's unreliable auto-detection for short words.
                    value = GoogleTranslator(source="es", target="en").translate(normalized_source)
                result.put((True, value))
            except Exception as error:  # pragma: no cover - provider/network path
                result.put((False, str(error)))

        Thread(target=translate, daemon=True).start()
        try:
            ok, value = result.get(timeout=self.translation_timeout_seconds)
        except Empty as error:
            raise QueryTranslationUnavailable("query translation timed out") from error

        if not ok:
            raise QueryTranslationUnavailable("query translation failed")
        english = _canonicalize_english(value or "")
        if not english:
            raise QueryTranslationUnavailable("query translation returned an empty result")
        self._store_translation(normalized_source, english)
        return english

    def parse(self, query: str, concept_names: list[str]) -> ParsedQuery:
        cleaned = _normalize_space(query)
        requires_me = bool(_IDENTITY.search(cleaned))
        cleaned = _IDENTITY.sub(" ", cleaned)

        for name in sorted(concept_names, key=len, reverse=True):
            pattern = re.compile(r"\b" + re.escape(name.lower()) + r"\b", re.I)
            if pattern.search(cleaned):
                requires_me = True

        source_semantic = _shorten_request(_normalize_space(cleaned)) or "photo"
        english_semantic = self._translate_to_english(source_semantic)
        # Constraints are derived from canonical English, never from source
        # Spanish. Equivalent Spanish/English queries therefore use identical
        # reranking constraints as well as identical semantic variants.
        constraints = _compositional_constraints(english_semantic)

        variants: list[str] = [english_semantic]
        if constraints is not None:
            canonical_joint = f"{constraints['color']} {constraints['object_english']}"
            variants.append(canonical_joint)
            object_english = str(constraints["object_english"])
            if object_english in CLOTHING_EN:
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
