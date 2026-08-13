from dataclasses import dataclass
import re


_FILLERS = re.compile(r"\b(quiero|busca|buscame|mu[eé]strame|dame|una?|foto(?:graf[ií]a)?|donde|aparezca|que|con|de)\b", re.I)
_IDENTITY = re.compile(r"\b(yo|m[ií]a|m[ií]o|mi persona)\b", re.I)
_TRANSLATIONS = {
    "camiseta": "t-shirt", "camisa": "shirt", "chaqueta": "jacket", "vestido": "dress",
    "roja": "red", "rojo": "red", "azul": "blue", "verde": "green", "negro": "black", "blanco": "white",
    "perro": "dog", "gato": "cat", "mascota": "pet", "carro": "car", "bicicleta": "bicycle",
    "playa": "beach", "parque": "park", "casa": "house", "comida": "food", "noche": "night",
    "persona": "person", "sonriendo": "smiling", "dos personas": "two people",
}


@dataclass
class ParsedQuery:
    original: str
    semantic_text: str
    requires_me: bool
    variants: list[str]


class QueryNormalizer:
    def parse(self, query: str, concept_names: list[str]) -> ParsedQuery:
        cleaned = query.strip().lower()
        requires_me = bool(_IDENTITY.search(cleaned))
        cleaned = _IDENTITY.sub("", cleaned)
        for name in concept_names:
            cleaned = re.sub(r"\b" + re.escape(name.lower()) + r"\b", "", cleaned)
        semantic = _FILLERS.sub(" ", cleaned)
        semantic = re.sub(r"\s+", " ", semantic).strip() or "photo"
        translated = semantic
        for spanish, english in sorted(_TRANSLATIONS.items(), key=lambda item: -len(item[0])):
            translated = re.sub(r"\b" + re.escape(spanish) + r"\b", english, translated)
        variants = [semantic]
        if translated != semantic:
            variants.append(translated)
        variants.append(f"a photo of {translated}")
        return ParsedQuery(query, semantic, requires_me, variants[:3])
