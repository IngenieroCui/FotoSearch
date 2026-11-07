# FotoSearch

**Búsqueda de fotos personales con lenguaje natural e inferencia visual en el teléfono.**

## Problema y solución

Encontrar una imagen en una galería grande no debería depender de recordar su fecha o nombre. FotoSearch indexa las fotos con MobileCLIP en Flutter y compara sus vectores con una consulta textual para ordenar resultados.

## Funcionalidades

- Acceso a la galería y generación local de embeddings visuales con ONNX.
- Índice SQLite y ranking en el dispositivo.
- Consulta por lenguaje natural, con normalización ES/EN en el backend.
- Conceptos personales y personalización de «yo» almacenados localmente.

## Tecnologías y arquitectura

`Galería → Flutter + MobileCLIP Vision/ONNX → SQLite → ranking local`.

`Texto de consulta → FastAPI + MobileCLIP Text/ONNX → vectores 512d → teléfono`.

La aplicación usa Dart, `photo_manager`, `flutter_onnxruntime` y `sqflite`. El backend usa Python, FastAPI, NumPy y ONNX Runtime. En la rama **`production`**, los endpoints de consulta no reciben fotos, miniaturas ni embeddings visuales.

## Instalación

Con Flutter instalado:

```bash
cd frontend
flutter pub get
flutter run --dart-define=FOTOSEARCH_API_BASE_URL=https://YOUR-PROJECT.vercel.app/api
```

Sustituye la URL por un backend propio y accesible; debe terminar en `/api`. Para preparar los modelos y ejecutar la API, consulta [ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Estado y límites

La rama documentada es `production` (`4d3aa40`); `master` conserva una arquitectura diferente que dio origen a FotoSearch Cloud. **No es completamente offline**: las consultas necesitan embeddings de texto del backend y la traducción puede requerir un servicio remoto. La URL de API se fija al compilar.

La precisión depende del modelo, los atributos de la imagen y los permisos de galería. Este sprint verificó código e historial, sin ejecutar inferencia, pruebas ni builds. No se certifica aquí un despliegue operativo.

## Contribución y créditos

El historial registra el desarrollo bajo el alias **Andrecodev**: `9012a2f` establece la arquitectura MobileCLIP y `be47765`–`4d3aa40` ajustan indexación, búsqueda y traducción. Esta documentación no reasigna ese historial ni presenta los modelos preentrenados como creación propia. Deben revisarse las licencias de MobileCLIP y sus artefactos antes de redistribuirlos.

[Arquitectura, flujo de datos y dependencias](docs/ARCHITECTURE.md).
