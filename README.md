# FotoSearch MVP

FotoSearch busca fotos de la galería del teléfono con lenguaje natural, manteniendo los originales en el dispositivo. Flutter envía únicamente miniaturas JPEG temporales al backend local; Python calcula embeddings y descarta esos bytes. SQLite guarda IDs de galería, metadatos mínimos y vectores.

## Arquitectura

`frontend/` es la app Flutter Android preparada para iOS mediante `photo_manager`. `Backend/` es un FastAPI local con SQLite y búsqueda NumPy. `clip-ViT-B-32` genera los embeddings de imagen y `clip-ViT-B-32-multilingual-v1` genera consultas de más de 50 idiomas en el mismo espacio vectorial. El español original siempre se codifica y un diccionario local pequeño agrega variantes visuales en inglés para colores, ropa y objetos frecuentes. No hay APIs de IA pagas, LLMs ni fine-tuning.

El ranking tiene dos etapas. Primero selecciona hasta 100 candidatos únicamente por el máximo score CLIP entre variantes independientes; no promedia queries. Después aplica identidad facial, conceptos personales y feedback acotado. El feedback general usa como máximo tres ejemplos y queda entre `-0.05` y `+0.05`; un voto exacto usa `-0.10` o `+0.08`. La configuración se concentra en variables de entorno y se puede copiar desde `Backend/.env.example`.

## Ejecutar el backend (Windows PowerShell)

```powershell
cd Backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
Copy-Item .env.example .env
python -m app.main
```

`python -m app.main` inicia Uvicorn con `FOTOSEARCH_HOST` y `FOTOSEARCH_PORT`, por lo que evita los problemas habituales de ejecutar un `uvicorn` global con otro intérprete o desde un directorio distinto. La base SQLite predeterminada queda anclada a `Backend/data/fotosearch.db`, sin importar desde qué directorio se ejecute el proceso.

La primera ejecución descarga los modelos preentrenados; después la inferencia es local. Si el PC tiene CUDA, PyTorch la usa automáticamente. Confirma `http://localhost:8000/health`.

El reconocimiento facial es opcional y el backend continúa funcionando si no está disponible. Para instalarlo, usa Python 3.12 o anterior y ejecuta `python -m pip install -r requirements-face.txt`; con Python 3.13, FaceNet no es instalable aún porque su dependencia fija NumPy 1.x. También puedes fijar `FOTOSEARCH_ENABLE_FACE_RECOGNITION=false` para desactivarlo explícitamente.

Las variables más habituales son estas:

| Variable | Valor predeterminado | Uso |
| --- | --- | --- |
| `FOTOSEARCH_HOST` / `FOTOSEARCH_PORT` | `0.0.0.0` / `8000` | IP de escucha y puerto del backend |
| `FOTOSEARCH_DB` | `Backend/data/fotosearch.db` | Ubicación de SQLite |
| `FOTOSEARCH_CORS_ORIGINS` | `*` | Orígenes web permitidos, separados por coma |
| `FOTOSEARCH_CLIP_MODEL` | `clip-ViT-B-32` | Modelo de embeddings visuales |
| `FOTOSEARCH_TEXT_MODEL` | `sentence-transformers/clip-ViT-B-32-multilingual-v1` | Encoder de texto multilingüe alineado con el visual |
| `FOTOSEARCH_EMBEDDING_VERSION` | `clip-b32-multilingual-v2` | Invalida automáticamente vectores CLIP incompatibles |
| `FOTOSEARCH_QUERY_PIPELINE_VERSION` | `query-v3` | Invalida feedback generado por otro pipeline de consulta |
| `FOTOSEARCH_TRANSLATION_ENABLED` | `false` | Variante adicional opcional con Google Translate gratuito |
| `FOTOSEARCH_SEMANTIC_CANDIDATES` | `100` | Top K puramente semántico que pasa al reranking |
| `FOTOSEARCH_MAX_IMAGE_SIDE` | `768` | Tamaño máximo procesado por el backend |
| `FOTOSEARCH_EMBEDDING_BATCH_SIZE` | `48` | Imágenes que CLIP procesa a la vez durante la indexación |
| `FOTOSEARCH_ENABLE_FACE_RECOGNITION` | `true` | Activa o desactiva FaceNet |
| `FOTOSEARCH_FACE_DEVICE` | `auto` | `auto`, `cpu` o `cuda:0` |
| `FOTOSEARCH_*_WEIGHT` y `FOTOSEARCH_*_THRESHOLD` | Ver `.env.example` | Ajustes de ranking y confianza |

Para desarrollo, usa `FOTOSEARCH_RELOAD=true`. Si necesitas invocar Uvicorn directamente, hazlo siempre con el Python del entorno: `python -m uvicorn app.main:app --host 0.0.0.0 --port 8000`.

La traducción remota no es necesaria. Para probarla, instala `Backend/requirements-translation.txt` y activa `FOTOSEARCH_TRANSLATION_ENABLED=true`. Tiene timeout y cualquier error conserva las variantes locales ES/EN.

### Compatibilidad de la base existente

Al arrancar se comparan versión, modelo visual, modelo textual y versión del pipeline con `app_metadata`. Una DB sin metadata se considera antigua: se vacían `photos` (para que `/index/pending` solicite reindexación completa) y `search_feedback`; los `concept_examples` incompatibles se eliminan y cada `personal_concept` queda con `needs_rebuild=true`. No se borran identidades ni embeddings faciales porque FaceNet usa una versión independiente. Si esa versión facial cambia explícitamente, entonces sí se invalidan solamente sus tablas.

## Ejecutar Android

```powershell
cd frontend
flutter pub get
Copy-Item .env.example .env
flutter run
```

El frontend tiene su propio archivo `frontend/.env`; créalo a partir de `.env.example`. `FOTOSEARCH_API_BASE_URL` define la URL inicial: para un teléfono físico usa la IP LAN del PC; en un emulador Android, `http://10.0.2.2:8000` es correcto. También puedes cambiarla desde **Ajustes**; esa elección queda guardada en el teléfono. Las variables `FOTOSEARCH_REQUEST_TIMEOUT_SECONDS`, `FOTOSEARCH_THUMBNAIL_SIDE`, `FOTOSEARCH_THUMBNAIL_QUALITY`, `FOTOSEARCH_INDEX_BATCH_SIZE` y `FOTOSEARCH_SEARCH_LIMIT` permiten ajustar tiempo de espera, consumo de red, velocidad de indexación y cantidad de resultados. La app usa miniaturas de 256 px y lotes de 48 por defecto. Guarda su avance, se reanuda desde el último lote completado y, en escaneos posteriores, consulta primero qué fotos cambiaron para no regenerar miniaturas de las ya indexadas. Continúa aunque encuentre archivos corruptos o no compatibles. En CI se pueden sobrescribir con `--dart-define=FOTOSEARCH_*`; no guardes secretos en el `.env` del frontend porque quedan incluidos en la aplicación.

Android queda habilitado para conectarse por HTTP a la red local. Para publicar fuera de una red de confianza, usa HTTPS y elimina esa excepción. Al abrir FotoSearch se solicita el permiso de galería automáticamente; el acceso limitado de Android/iOS también es válido y permite procesar las fotos seleccionadas. Después entra a **Índice** y pulsa **Escanear / continuar**.

## Uso

- Busca `camisa roja`, `yo con camisa roja`, `foto en la playa` o `mi mascota`.
- En **Personalizar**, configura **Yo** con 3–5 fotos claras. FaceNet detecta y promedia el rostro; no conserva recortes.
- Crea **mi mascota** (u otro concepto) con 3–5 fotos: se promedian sus embeddings CLIP, sin entrenar una red.
- Usa 👍/👎 para guardar ejemplos y rerankear consultas semánticamente cercanas.
- Si falta una imagen, toca **No está la foto que buscaba**, selecciónala y FotoSearch la indexa y guarda como corrección positiva.

## Validación

```powershell
cd Backend
python -m pytest

cd ..\frontend
flutter analyze
flutter test
```

## Límites conocidos

CLIP generalista no garantiza atributos finos en todas las galerías. La identidad depende de que FaceNet detecte correctamente rostros; si `facenet-pytorch` no carga, el resto del MVP sigue funcionando y `/health` lo indica. La indexación actual es secuencial para mostrar progreso fiable; para bibliotecas muy grandes puede convertirse en lote/concurrencia más adelante. Una evolución natural es reemplazar el repositorio NumPy por FAISS y evaluar SigLIP o fine-tuning/LoRA únicamente cuando haya suficientes correcciones etiquetadas.
