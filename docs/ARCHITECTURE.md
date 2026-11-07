# Arquitectura de FotoSearch

[Presentación](../README.md). Alcance: rama `production`, commit base `4d3aa40`; `frontend/lib/local_search`, personalización y `Backend/app`.

## Componentes y datos

Flutter obtiene activos de galería con `photo_manager`, prepara la imagen y ejecuta MobileCLIP Vision con ONNX Runtime. SQLite conserva referencias/metadatos y vectores para búsqueda local; las imágenes originales permanecen en la galería. Los modelos visuales se declaran como assets en `frontend/pubspec.yaml`.

La consulta sale del dispositivo hacia `POST /api/mobileclip/query-plan`. FastAPI normaliza el texto con `QueryNormalizer`, extrae restricciones y genera vectores MobileCLIP Text de 512 dimensiones. Devuelve variantes y restricciones con vectores al cliente, que compara contra el índice local. La API de esta rama no implementa indexación de imágenes remota.

`Backend/app/main.py` activa traducción en el normalizador. `query.py` combina vocabulario determinístico con traducción mediante `deep-translator` cuando se necesita. Esa ruta puede transmitir texto a un tercero y devolver 503 si la traducción no está disponible. No debe describirse como un sistema íntegramente offline.

## API y autenticación

- `GET /api/health`: indica disponibilidad del encoder, versión de embeddings y pipeline; puede informar estado degradado.
- `POST /api/mobileclip/query-plan`: recibe `query` y `concept_names`; devuelve texto normalizado, variantes, embeddings y restricciones.

No se observa una capa de cuentas/autenticación en estos endpoints. CORS se configura con `FOTOSEARCH_CORS_ORIGINS`, cuyo valor predeterminado permite cualquier origen; CORS no aporta autorización. Un servicio expuesto requiere evaluar acceso, límites y privacidad del texto.

## Preparación del backend

Requiere Python y los paquetes declarados en `Backend/requirements.txt`. Los artefactos de texto deben estar presentes en `Backend/models/mobileclip_s0/`: `text_model_fp16.onnx`, `tokenizer.json` y `tokenizer_config.json`.

```bash
python tools/fetch_mobileclip_models.py --text
cd Backend
python -m pip install -r requirements.txt
python -m uvicorn app.main:app --reload
```

La descarga prepara artefactos antes del arranque. La API no descarga modelos durante una petición; si no puede cargar el encoder queda degradada. El entrypoint de Vercel es `Backend/api/index.py` y su configuración incluye los modelos en la función. Esta documentación no verifica el servicio desplegado.

Flutter recibe `FOTOSEARCH_API_BASE_URL` mediante `--dart-define`; la URL se incorpora al compilar y no tiene un fallback productivo ficticio. Para generar un APK se usa el mismo parámetro con `flutter build apk --release`. La instalación de dependencias y esos comandos no se ejecutaron en este sprint.

## Decisiones, historial y límites

- La inferencia visual local evita enviar fotografías al backend de esta rama.
- El encoder textual permanece en servidor: reduce exigencias del cliente, pero impone conectividad.
- SQLite y ranking local mantienen el índice bajo control del dispositivo; los permisos y cambios en la galería afectan su disponibilidad.
- `9012a2f` registra la arquitectura MobileCLIP; `be47765`, `dca35fb`, `99dcf7c` y `4d3aa40` ajustan traducción/búsqueda. El historial los atribuye a Andrecodev, sin adjudicar su identidad a otra persona.

No deben mezclarse los vectores de esta rama con los de CLIP de `master`/FotoSearch Cloud sin reindexar y verificar compatibilidad. Posibles mejoras: encoder de texto local, evaluación con consultas etiquetadas, medición en dispositivos y protección de la API. No se aportan métricas inventadas de calidad o velocidad. La redistribución de modelos necesita revisión de licencias y procedencia de los pesos.
