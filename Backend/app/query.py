from dataclasses import dataclass
from collections import OrderedDict
import re
from queue import Empty, Queue
from threading import Lock, Thread
from typing import Callable


class QueryTranslationError(RuntimeError):
    """La consulta no puede continuar sin una traducción al inglés."""


# "mi" / "my" por sí solos son posesivos ("mi mascota"), no identidad.
_IDENTITY = re.compile(r"\b(mi persona|yo|mí|mía|mío|myself|me)\b", re.I)
_REQUEST_PREFIXES = (
    re.compile(r"^(?:por favor\s+)?(?:quiero|quisiera|busca(?:me)?|encuentra(?:me)?|mu[eé]strame|dame)\s+", re.I),
    re.compile(r"^(?:una?\s+)?(?:foto(?:graf[ií]a)?|imagen)\s+(?:de|donde|en la que|con)\s+", re.I),
    re.compile(r"^(?:donde\s+)?(?:salga|aparezca|se vea)\s+", re.I),
    re.compile(r"^(?:con|de)\s+", re.I),
)

COLORS = {
    "rojo": "red", "roja": "red", "rojos": "red", "rojas": "red",
    "azul": "blue", "azules": "blue", "verde": "green", "verdes": "green",
    "negro": "black", "negra": "black", "negros": "black", "negras": "black",
    "blanco": "white", "blanca": "white", "blancos": "white", "blancas": "white",
    "amarillo": "yellow", "amarilla": "yellow", "amarillos": "yellow", "amarillas": "yellow",
    "gris": "gray", "grises": "gray", "morado": "purple", "morada": "purple", "morados": "purple", "moradas": "purple",
    "rosado": "pink", "rosada": "pink", "rosados": "pink", "rosadas": "pink",
    "naranja": "orange", "naranjas": "orange", "café": "brown", "cafés": "brown", "marrón": "brown", "marrones": "brown",
}
CLOTHING = {
    "camiseta": "t-shirt", "camisetas": "t-shirts", "camisa": "shirt", "camisas": "shirts",
    "chaqueta": "jacket", "chaquetas": "jackets", "vestido": "dress", "vestidos": "dresses",
    "pantalón": "pants", "pantalones": "pants", "shorts": "shorts", "falda": "skirt", "faldas": "skirts",
    "zapatos": "shoes", "zapato": "shoe", "tenis": "sneakers", "tênis": "sneakers",
}
COMMON_OBJECTS = {
    "perro": "dog", "perros": "dogs", "gato": "cat", "gatos": "cats",
    "mascota": "pet", "mascotas": "pets", "carro": "car", "carros": "cars",
    "coche": "car", "coches": "cars", "bicicleta": "bicycle", "bicicletas": "bicycles",
    "caballo": "horse", "caballos": "horses", "pájaro": "bird", "pájaros": "birds",
    "moto": "motorcycle", "motos": "motorcycles", "motocicleta": "motorcycle", "motocicletas": "motorcycles",
    "computador": "computer", "computadora": "computer", "computadores": "computers", "computadoras": "computers",
    "celular": "phone", "celulares": "phones", "teléfono": "phone", "teléfonos": "phones",
    "mesa": "table", "mesas": "tables", "silla": "chair", "sillas": "chairs",
    "gafas": "glasses", "lentes": "glasses", "sombrero": "hat", "sombreros": "hats",
    "mochila": "backpack", "mochilas": "backpacks",
    "playa": "beach", "playas": "beaches", "parque": "park", "parques": "parks",
    "casa": "home", "casas": "homes", "restaurante": "restaurant", "restaurantes": "restaurants",
    "calle": "street", "calles": "streets", "ciudad": "city", "ciudades": "cities",
    "campo": "countryside", "montaña": "mountain", "montañas": "mountains", "piscina": "pool", "piscinas": "pools",
    "colegio": "school", "colegios": "schools", "universidad": "university", "universidades": "universities",
}
_OTHER_WORDS = {
    "hombre": "man", "mujer": "woman", "niño": "child", "niña": "child", "niños": "children", "niñas": "children",
    "bebé": "baby", "bebes": "babies", "familia": "family", "familias": "families",
    "amigo": "friend", "amiga": "friend", "amigos": "friends", "amigas": "friends", "pareja": "couple", "parejas": "couples",
    "persona": "person", "personas": "people", "con": "with", "en": "in", "de": "of",
    "sonriendo": "smiling", "corriendo": "running", "caminando": "walking", "comiendo": "eating", "jugando": "playing",
    "sentado": "sitting", "sentada": "sitting", "parado": "standing", "parada": "standing", "abrazando": "hugging",
    "noche": "night", "día": "daytime", "lluvia": "rain", "cumpleaños": "birthday", "fiesta": "party", "comida": "food",
    "la": "", "el": "", "los": "", "las": "", "un": "a", "una": "a", "unos": "", "unas": "", "y": "and",
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


def _naturalize_english(text: str) -> str:
    return re.sub(r"\b(person|people)\s+with\s+", r"\1 wearing ", text, flags=re.I)


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
        translation_enabled: bool = True,
        translator: Callable[[str], str] | None = None,
        translation_timeout_seconds: float = 2.0,
    ):
        self.translation_enabled = translation_enabled
        self._translator = translator
        self.translation_timeout_seconds = translation_timeout_seconds
        self._translation_cache: OrderedDict[str, str | None] = OrderedDict()
        self._translation_cache_lock = Lock()

    @staticmethod
    def _translation_key(text: str) -> str:
        return re.sub(r"\s+", " ", text).strip().casefold()

    def _translate_required(self, text: str) -> str:
        if not self.translation_enabled:
            raise QueryTranslationError("English translation is required for search")
        key = self._translation_key(text)
        with self._translation_cache_lock:
            if key in self._translation_cache:
                value = self._translation_cache.pop(key)
                self._translation_cache[key] = value
                return value
        result: Queue[tuple[str | None, Exception | None]] = Queue(maxsize=1)

        def translate() -> None:
            try:
                if self._translator is not None:
                    value = self._translator(text)
                else:
                    from deep_translator import GoogleTranslator
                    value = GoogleTranslator(source="auto", target="en").translate(text)
                result.put((value, None))
            except Exception as error:
                result.put((None, error))

        # Daemon evita que una caída de Google bloquee el proceso o la búsqueda.
        Thread(target=translate, daemon=True).start()
        try:
            value, error = result.get(timeout=self.translation_timeout_seconds)
        except Empty:
            raise QueryTranslationError("English translation timed out") from None
        if error is not None:
            raise QueryTranslationError("English translation failed") from error
        value = re.sub(r"\s+", " ", value.strip()) if isinstance(value, str) else ""
        if not value:
            raise QueryTranslationError("English translation was empty")
        with self._translation_cache_lock:
            self._translation_cache[key] = value
            self._translation_cache.move_to_end(key)
            while len(self._translation_cache) > 256:
                self._translation_cache.popitem(last=False)
        return value

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
        # La traducción remota es obligatoria y es la única consulta que llega
        # al encoder. Nunca se añade el texto español como fallback.
        semantic = _naturalize_english(self._translate_required(semantic))
        has_clothing = any(
            re.search(r"\b" + re.escape(word) + r"\b", semantic)
            for word in [*CLOTHING, *CLOTHING.values()]
        )
        english_variants = [semantic]
        variants: list[str] = []
        for english in english_variants:
            variants.append(english)
        for english in english_variants:
            if has_clothing and not re.search(r"\b(person|people)\b", english):
                variants.append(f"a photo of a person wearing {english}")
            else:
                variants.append(f"a photo of {english}")
        return ParsedQuery(
            query,
            semantic,
            requires_me,
            _deduplicate(variants),
            _compositional_constraints(semantic),
        )
