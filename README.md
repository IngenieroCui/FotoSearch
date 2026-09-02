# FotoSearch

FotoSearch busca fotos de la galería con lenguaje natural sin enviar fotografías
ni embeddings visuales fuera del teléfono.

## Arquitectura final

```text
Galería → MobileCLIP Vision ONNX local → SQLite → búsqueda/ranking local
Consulta → FastAPI Vercel → MobileCLIP Text ONNX → embedding 512d → teléfono
```

El backend solo procesa texto. Las fotografías y sus embeddings visuales nunca
salen del dispositivo.

## Endpoints

- `GET /api/health`
- `POST /api/mobileclip/query-plan`

El query plan recibe, por ejemplo, `{ "query": "camiseta roja", "concept_names": [] }`
y devuelve embeddings de texto MobileCLIP de 512 dimensiones. No recibe fotos,
miniaturas ni embeddings de imágenes.

## Flutter

La URL configurada debe terminar en `/api`. Copia `frontend/.env.example` a
`frontend/.env` para desarrollo local, o proporciona la URL de Vercel durante
la compilación. También se puede cambiar desde Ajustes.

```powershell
cd frontend
flutter pub get
flutter run --dart-define=FOTOSEARCH_API_BASE_URL=https://YOUR-PROJECT.vercel.app/api
flutter build apk --release --dart-define=FOTOSEARCH_API_BASE_URL=https://YOUR-PROJECT.vercel.app/api
```

El fallback incorporado es exclusivamente local de desarrollo:
`http://10.0.2.2:8000/api`. No hay una URL productiva ficticia incluida en el
APK.

## Backend y Vercel

Antes de desplegar deben estar presentes estos artefactos en
`Backend/models/mobileclip_s0/`:

- `text_model_fp16.onnx`
- `tokenizer.json`
- `tokenizer_config.json`

Si faltan, descárgalos una sola vez con:

```powershell
python tools/fetch_mobileclip_models.py --text
```

El entrypoint de Vercel es `Backend/api/index.py`; `Backend/vercel.json` incluye
los modelos en esa función. No se descarga ningún modelo durante el inicio ni
durante una petición.

```powershell
cd Backend
python -m pip install -r requirements.txt
python -m pip install -r requirements-dev.txt
pytest
uvicorn app.main:app --reload
```

Comprueba `GET /api/health` y envía un `POST /api/mobileclip/query-plan` con
`{ "query": "camiseta roja", "concept_names": [] }`.

## Pendientes futuros

- "yo"
- conceptos personales
- feedback/aprendizaje

Las consultas que requieren esas capacidades muestran: "Las búsquedas
personalizadas todavía no están disponibles."
