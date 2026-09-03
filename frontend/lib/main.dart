import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';
import 'local_search/index/local_embedding_index.dart';
import 'local_search/local_search_config.dart';
import 'local_search/local_search_engine.dart';
import 'local_search/local_vector.dart';
import 'local_search/mobileclip/mobileclip_image_encoder.dart';
import 'local_search/mobileclip/mobileclip_query_client.dart';
import 'local_search/models/local_photo_embedding.dart';
import 'local_search/storage/local_search_database.dart';
import 'onboarding/onboarding_screen.dart';
import 'personalization/personal_query.dart';
import 'personalization/personalization_service.dart';
import 'ui/gallery_picker.dart';
import 'ui/index_page.dart';
import 'ui/personalization_page.dart';
import 'ui/results_page.dart';
import 'ui/search_page.dart';
import 'ui/settings_page.dart';

class IndexFailure {
  const IndexFailure({required this.assetId, required this.reason});
  final String assetId;
  final String reason;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final onboardingComplete =
      preferences.getBool('fotosearch_onboarding_v1_complete') ?? false;
  runApp(FotoSearchApp(onboardingComplete: onboardingComplete));
}

class FotoSearchApp extends StatefulWidget {
  const FotoSearchApp({super.key, required this.onboardingComplete});
  final bool onboardingComplete;

  @override
  State<FotoSearchApp> createState() => _FotoSearchAppState();
}

class _FotoSearchAppState extends State<FotoSearchApp> {
  late bool onboardingComplete = widget.onboardingComplete;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'FotoSearch',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.indigo,
        brightness: Brightness.light,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff8f8fc),
      cardTheme: const CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
      ),
    ),
    home: onboardingComplete
        ? const FotoSearchHome()
        : OnboardingScreen(
            onComplete: () => setState(() => onboardingComplete = true),
          ),
  );
}

class FotoSearchHome extends StatefulWidget {
  const FotoSearchHome({super.key});

  @override
  State<FotoSearchHome> createState() => _FotoSearchHomeState();
}

class _FotoSearchHomeState extends State<FotoSearchHome>
    with WidgetsBindingObserver {
  final _database = LocalSearchDatabase();
  final _index = LocalEmbeddingIndex();
  final _imageEncoder = MobileClipImageEncoder();
  final _queryClient = const MobileClipQueryClient();
  final _queryController = TextEditingController();
  late final _personalization = PersonalizationService(_database);

  int _galleryCount = 0;
  List<AssetEntity> _previewAssets = const [];
  List<AssetEntity> _assets = const [];
  Map<String, AssetEntity> _assetsById = const {};
  Map<String, AssetEntity> _resultAssetsById = const {};
  bool _fullGalleryLoaded = false;
  List<Map<String, dynamic>> _results = const [];
  List<LocalPersonalConcept> _concepts = const [];
  List<IndexFailure> _failureSamples = const [];
  String _indexNotice = '';
  String? _notice;
  String _lastQuery = '';
  int _tab = 1;
  int _indexedCount = 0;
  int _inspected = 0;
  int _totalPending = 0;
  int _successful = 0;
  int _thumbnailFailures = 0;
  int _inferenceFailures = 0;
  int _databaseFailures = 0;
  GalleryState _galleryState = GalleryState.checkingPermission;
  String? _galleryError;
  Future<void>? _gallerySummaryFuture;
  Future<void>? _fullGalleryLoadFuture;
  bool _indexing = false;
  bool _searching = false;
  bool _personalizationBusy = false;
  bool _cancelRequested = false;
  BackendHealthResult? _backendHealth;
  bool _connectionChecking = false;

  bool get _permissionGranted =>
      _galleryState == GalleryState.loading ||
      _galleryState == GalleryState.ready ||
      _galleryState == GalleryState.limited;

  bool get _connected =>
      _backendHealth?.status == BackendHealthStatus.connected;

  LocalSearchEngine get _searchEngine => LocalSearchEngine(
    queryClient: _queryClient,
    database: _database,
    index: _index,
  );

  int get _omitted =>
      _thumbnailFailures + _inferenceFailures + _databaseFailures;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_checkHealth());
    unawaited(_initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadGallerySummary());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _queryController.dispose();
    unawaited(_imageEncoder.dispose());
    unawaited(_database.close());
    super.dispose();
  }

  Future<void> _initialize() async {
    await _database.open();
    await Future.wait([_loadGallerySummary(), _reloadConcepts()]);
    final indexed = await _database.photoCount();
    if (!mounted) return;
    setState(() {
      _indexedCount = indexed;
      if (kDebugMode) {
        debugPrint(
          'FotoSearch API host: ${Uri.parse(AppConfig.apiBaseUrl).host}',
        );
      }
    });
  }

  Future<void> _checkHealth({bool showFailureMessage = false}) async {
    if (_connectionChecking) return;
    if (mounted) setState(() => _connectionChecking = true);
    final result = await _queryClient.health();
    if (!mounted) return;
    setState(() {
      _backendHealth = result;
      _connectionChecking = false;
    });
    if (showFailureMessage && result.status != BackendHealthStatus.connected) {
      _showMessage(
        result.message ?? 'We could not connect. Check your Internet connection and try again.',
      );
    }
  }

  Future<void> _reloadConcepts() async {
    final concepts = await _personalization.concepts();
    if (mounted) setState(() => _concepts = concepts);
  }

  Future<void> _loadGallerySummary() =>
      _gallerySummaryFuture ??= _loadGallerySummaryInternal().whenComplete(() {
        _gallerySummaryFuture = null;
      });

  Future<void> _loadGallerySummaryInternal() async {
    final totalWatch = Stopwatch()..start();
    var permissionMs = 0;
    var countMs = 0;
    var previewMs = 0;
    if (mounted) {
      setState(() {
        _galleryState = GalleryState.checkingPermission;
        _galleryError = null;
      });
    }
    try {
      final permissionWatch = Stopwatch()..start();
      final permission = await PhotoManager.getPermissionState(
        requestOption: galleryPermissionOption,
      );
      permissionWatch.stop();
      permissionMs = permissionWatch.elapsedMilliseconds;
      if (!permission.hasAccess) {
        if (!mounted) return;
        setState(() {
          _galleryState = GalleryState.denied;
          _galleryCount = 0;
          _previewAssets = const [];
          _assets = const [];
          _assetsById = const {};
          _resultAssetsById = const {};
          _fullGalleryLoaded = false;
        });
        return;
      }
      if (mounted) {
        setState(() {
          _galleryState = permission.isLimited
              ? GalleryState.limited
              : GalleryState.loading;
        });
      }
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
      );
      var count = 0;
      var preview = <AssetEntity>[];
      if (paths.isNotEmpty) {
        final countWatch = Stopwatch()..start();
        count = await paths.first.assetCountAsync;
        countWatch.stop();
        countMs = countWatch.elapsedMilliseconds;
        final previewWatch = Stopwatch()..start();
        preview = await paths.first.getAssetListPaged(page: 0, size: 12);
        previewWatch.stop();
        previewMs = previewWatch.elapsedMilliseconds;
      }
      if (!mounted) return;
      setState(() {
        _galleryCount = count;
        _previewAssets = preview;
        _assets = const [];
        _assetsById = const {};
        _resultAssetsById = const {};
        _fullGalleryLoaded = false;
        _galleryState = permission.isLimited
            ? GalleryState.limited
            : GalleryState.ready;
      });
      totalWatch.stop();
      if (kDebugMode) {
        debugPrint(
          'GALLERY SUMMARY: count=$_galleryCount preview=${_previewAssets.length} '
          'totalMs=${totalWatch.elapsedMilliseconds} '
          'permissionMs=$permissionMs countMs=$countMs previewMs=$previewMs',
        );
      }
    } catch (error) {
      if (kDebugMode) debugPrint('GALLERY LOAD ERROR: $error');
      if (!mounted) return;
      setState(() {
        _galleryState = GalleryState.error;
        _galleryError =
            'No se pudo cargar tu galería. Intenta actualizarla de nuevo.';
        _galleryCount = 0;
        _previewAssets = const [];
        _assets = const [];
        _assetsById = const {};
        _resultAssetsById = const {};
        _fullGalleryLoaded = false;
      });
    }
  }

  Future<void> _ensureFullGalleryLoaded() => _fullGalleryLoaded
      ? Future<void>.value()
      : _fullGalleryLoadFuture ??= _ensureFullGalleryLoadedInternal()
            .whenComplete(() => _fullGalleryLoadFuture = null);

  Future<void> _ensureFullGalleryLoadedInternal() async {
    final totalWatch = Stopwatch()..start();
    final summary = _gallerySummaryFuture;
    if (summary != null) await summary;
    final permission = await PhotoManager.getPermissionState(
      requestOption: galleryPermissionOption,
    );
    if (!permission.hasAccess) {
      if (mounted) {
        setState(() {
          _galleryState = GalleryState.denied;
          _galleryCount = 0;
          _previewAssets = const [];
          _assets = const [];
          _assetsById = const {};
          _fullGalleryLoaded = false;
        });
      }
      return;
    }
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
    );
    final assets = <AssetEntity>[];
    if (paths.isNotEmpty) {
      for (var page = 0; page * 1000 < _galleryCount; page++) {
        assets.addAll(
          await paths.first.getAssetListPaged(page: page, size: 1000),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _assets = assets;
      _assetsById = {for (final asset in assets) asset.id: asset};
      _fullGalleryLoaded = true;
      _galleryState = permission.isLimited
          ? GalleryState.limited
          : GalleryState.ready;
    });
    totalWatch.stop();
    if (kDebugMode) {
      debugPrint(
        'FULL GALLERY LOAD: count=${assets.length} '
        'totalMs=${totalWatch.elapsedMilliseconds}',
      );
    }
  }

  void _recordFailure(String assetId, Object error) {
    if (kDebugMode) debugPrint('INDEX FAILURE asset=$assetId error=$error');
    if (_failureSamples.length < 5) {
      _failureSamples = [
        ..._failureSamples,
        IndexFailure(assetId: assetId, reason: error.toString()),
      ];
    }
  }

  Future<Uint8List?> _thumbnail(AssetEntity asset) =>
      asset.thumbnailDataWithSize(
        const ThumbnailSize(
          LocalSearchConfig.localThumbnailSide,
          LocalSearchConfig.localThumbnailSide,
        ),
        format: ThumbnailFormat.jpeg,
        quality: LocalSearchConfig.localThumbnailQuality,
      );

  Future<List<({AssetEntity asset, Uint8List bytes})>> _loadThumbnailChunk(
    List<AssetEntity> chunk,
  ) async {
    final valid = <({AssetEntity asset, Uint8List bytes})>[];
    for (
      var start = 0;
      start < chunk.length;
      start += LocalSearchConfig.thumbnailConcurrency
    ) {
      final group = chunk.sublist(
        start,
        math.min(start + LocalSearchConfig.thumbnailConcurrency, chunk.length),
      );
      final loaded = await Future.wait(
        group.map((asset) async {
          try {
            final bytes = await _thumbnail(asset);
            if (bytes == null || bytes.isEmpty) {
              throw StateError('No se pudo obtener el thumbnail JPEG.');
            }
            return (asset: asset, bytes: bytes);
          } catch (error) {
            _thumbnailFailures++;
            _recordFailure(asset.id, error);
            return null;
          }
        }),
      );
      valid.addAll(loaded.whereType<({AssetEntity asset, Uint8List bytes})>());
    }
    return valid;
  }

  LocalPhotoEmbedding _photo(AssetEntity asset, Float32List embedding) {
    if (embedding.length != LocalSearchConfig.embeddingDimensions ||
        embedding.any((value) => !value.isFinite)) {
      throw StateError('MobileCLIP devolvió un embedding inválido.');
    }
    LocalVector.l2Norm(embedding);
    return LocalPhotoEmbedding(
      assetId: asset.id,
      modifiedAtMs: asset.modifiedDateTime.millisecondsSinceEpoch,
      createdAtMs: asset.createDateTime.millisecondsSinceEpoch,
      width: asset.width,
      height: asset.height,
      embedding: embedding,
      embeddingVersion: LocalSearchConfig.embeddingVersion,
      indexedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<bool> _ensureGalleryReadyForIndexing() async {
    if (_indexing) return false;

    final loading = _gallerySummaryFuture;
    if (loading != null) await loading;
    if (_galleryState == GalleryState.checkingPermission ||
        _galleryState == GalleryState.loading) {
      await _loadGallerySummary();
    }
    if (_galleryState == GalleryState.denied) {
      _showMessage(
        'FotoSearch necesita acceso a tu galería para crear el índice.',
      );
      return false;
    }
    if (_galleryState == GalleryState.error) {
      await _loadGallerySummary();
      if (_galleryState == GalleryState.error) {
        _showMessage('No se pudo cargar tu galería. Intenta de nuevo.');
        return false;
      }
    }
    if (_galleryCount == 0) {
      _showMessage('No encontramos fotos disponibles para indexar.');
      return false;
    }
    return _galleryState == GalleryState.ready ||
        _galleryState == GalleryState.limited;
  }

  void _validateEmbedding(Float32List embedding) {
    if (embedding.length != LocalSearchConfig.embeddingDimensions ||
        embedding.any((value) => !value.isFinite)) {
      throw StateError('MobileCLIP returned an invalid embedding.');
    }
    LocalVector.l2Norm(embedding);
  }

  Future<List<({AssetEntity asset, Float32List embedding})>>
  _encodeChunkRobustly(
    List<({AssetEntity asset, Uint8List bytes})> valid,
  ) async {
    if (valid.isEmpty) return const [];
    try {
      final embeddings = await _imageEncoder.encodeBatch(
        valid.map((item) => item.bytes).toList(growable: false),
      );
      if (embeddings.length != valid.length) {
        throw StateError('MobileCLIP returned an unexpected batch length.');
      }
      for (final embedding in embeddings) {
        _validateEmbedding(embedding);
      }
      return List.generate(
        valid.length,
        (index) => (asset: valid[index].asset, embedding: embeddings[index]),
        growable: false,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          'Batch inference failed; retrying images individually: $error',
        );
      }
      final successful = <({AssetEntity asset, Float32List embedding})>[];
      for (final item in valid) {
        try {
          final embedding = await _imageEncoder.encode(item.bytes);
          _validateEmbedding(embedding);
          successful.add((asset: item.asset, embedding: embedding));
        } catch (error) {
          _inferenceFailures++;
          _recordFailure(item.asset.id, error);
        }
      }
      return successful;
    }
  }

  Future<void> _indexPhotos() async {
    if (_indexing) return;

    final ready = await _ensureGalleryReadyForIndexing();
    if (!ready || !mounted) return;

    setState(() {
      _indexing = true;
      _cancelRequested = false;
      _failureSamples = const [];
      _inspected = 0;
      _totalPending = 0;
      _successful = 0;
      _thumbnailFailures = 0;
      _inferenceFailures = 0;
      _databaseFailures = 0;
      _indexNotice = 'Preparando tu galería para el escaneo…';
    });

    var thumbnailMs = 0;
    var inferenceMs = 0;
    var sqliteMs = 0;
    var modelLoadMs = 0;
    final totalWatch = Stopwatch()..start();
    var completedAll = false;
    try {
      await _ensureFullGalleryLoaded();
      if (_assets.isEmpty) {
        _indexNotice = 'No encontramos fotos disponibles para indexar.';
        return;
      }
      await _database.open();
      if (_index.length == 0 && await _database.photoCount() > 0) {
        await _index.reload(_database);
      }
      final states = await _database.photoStates();
      final pending = <AssetEntity>[];
      final galleryIds = <String>{};
      for (final asset in _assetsById.values) {
        galleryIds.add(asset.id);
        final state = states[asset.id];
        if (state == null ||
            state.modifiedAtMs !=
                asset.modifiedDateTime.millisecondsSinceEpoch ||
            state.embeddingVersion != LocalSearchConfig.embeddingVersion) {
          pending.add(asset);
        }
      }
      _totalPending = pending.length;
      _index.ensureCapacity(_index.length + pending.length);
      if (pending.isEmpty) {
        completedAll = true;
        _indexNotice = 'Index ready · 0 new photos';
      } else {
        final modelWatch = Stopwatch()..start();
        try {
          await _imageEncoder.load();
        } catch (error, stackTrace) {
          if (kDebugMode) {
            debugPrint('MobileCLIP model load failed: $error\n$stackTrace');
          }
          _indexNotice = 'No se pudo iniciar el análisis de fotos. Pulsa Escanear para intentarlo de nuevo.';
          return;
        }
        modelWatch.stop();
        modelLoadMs = modelWatch.elapsedMilliseconds;

        final attempted = <AssetEntity>{};
        final preflightPhotos = <({AssetEntity asset, Uint8List bytes})>[];
        for (final asset in pending) {
          if (preflightPhotos.length == 3) break;
          attempted.add(asset);
          try {
            final thumbnailWatch = Stopwatch()..start();
            final bytes = await _thumbnail(asset);
            thumbnailWatch.stop();
            thumbnailMs += thumbnailWatch.elapsedMilliseconds;
            if (bytes == null || bytes.isEmpty) {
              throw StateError('Thumbnail is empty.');
            }
            preflightPhotos.add((asset: asset, bytes: bytes));
          } catch (error) {
            _thumbnailFailures++;
            _recordFailure(asset.id, error);
          }
        }
        _inspected = attempted.length;
        if (mounted) setState(() {});
        if (preflightPhotos.isEmpty) {
          _indexNotice = 'No se pudieron leer las primeras fotos. Actualiza la galería e inténtalo de nuevo.';
          return;
        }

        ({AssetEntity asset, Float32List embedding})? preflightResult;
        for (final photo in preflightPhotos) {
          try {
            final inferenceWatch = Stopwatch()..start();
            final embedding = await _imageEncoder.encode(photo.bytes);
            inferenceWatch.stop();
            inferenceMs += inferenceWatch.elapsedMilliseconds;
            _validateEmbedding(embedding);
            preflightResult = (asset: photo.asset, embedding: embedding);
            break;
          } catch (error, stackTrace) {
            _inferenceFailures++;
            _recordFailure(photo.asset.id, error);
            if (kDebugMode) {
              debugPrint(
                'MobileCLIP preflight photo failed '
                'asset=${photo.asset.id}: $error\n$stackTrace',
              );
            }
          }
        }
        if (preflightResult == null) {
          _indexNotice = 'FotoSearch no pudo analizar estas fotos. Actualiza tu galería y vuelve a escanear.';
          return;
        }

        final databaseWatch = Stopwatch()..start();
        final persisted = await _database.upsertPhotosBatch([
          _photo(preflightResult.asset, preflightResult.embedding),
        ]);
        databaseWatch.stop();
        sqliteMs += databaseWatch.elapsedMilliseconds;
        for (final photo in persisted.photos) {
          _index.upsert(photo);
          _successful++;
        }
        for (final photo in persisted.failed) {
          _databaseFailures++;
          _recordFailure(photo.assetId, 'Database rejected the photo.');
        }

        final remaining = pending
            .where((asset) => !attempted.contains(asset))
            .toList(growable: false);
        var cursor = 0;
        while (cursor < remaining.length && !_cancelRequested) {
          final chunk = remaining.sublist(
            cursor,
            math.min(
              cursor + LocalSearchConfig.indexInferenceBatchSize,
              remaining.length,
            ),
          );
          final thumbnailWatch = Stopwatch()..start();
          final valid = await _loadThumbnailChunk(chunk);
          thumbnailWatch.stop();
          thumbnailMs += thumbnailWatch.elapsedMilliseconds;
          if (valid.isNotEmpty) {
            final inferenceWatch = Stopwatch()..start();
            final encoded = await _encodeChunkRobustly(valid);
            inferenceWatch.stop();
            inferenceMs += inferenceWatch.elapsedMilliseconds;
            final photos = encoded
                .map((item) => _photo(item.asset, item.embedding))
                .toList(growable: false);
            final databaseWatch = Stopwatch()..start();
            final persisted = await _database.upsertPhotosBatch(photos);
            databaseWatch.stop();
            sqliteMs += databaseWatch.elapsedMilliseconds;
            for (final photo in persisted.photos) {
              _index.upsert(photo);
              _successful++;
            }
            for (final photo in persisted.failed) {
              _databaseFailures++;
              _recordFailure(photo.assetId, 'Database rejected the photo.');
            }
          }
          cursor += chunk.length;
          _inspected += chunk.length;
          if (mounted) setState(() {});
        }
        completedAll = cursor >= remaining.length && !_cancelRequested;
      }
      if (completedAll) {
        final stale = Set<String>.of(_index.assetIds).difference(galleryIds);
        if (stale.isNotEmpty) {
          final sqliteWatch = Stopwatch()..start();
          await _database.deletePhotosByIds(stale);
          sqliteWatch.stop();
          sqliteMs += sqliteWatch.elapsedMilliseconds;
          _index.removeAssetIds(stale);
        }
      }
      _indexedCount = await _database.photoCount();
      final errors = _inferenceFailures + _databaseFailures;
      _indexNotice = _cancelRequested
          ? 'Indexación pausada: el lote actual se guardó.'
          : '$_successful correctas · $_omitted omitidas · $errors errores';
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('INDEX FATAL ERROR: $error\n$stackTrace');
      }
      _indexNotice = 'No se pudo completar la indexación. El progreso guardado no se perdió. Intenta continuar.';
    } finally {
      totalWatch.stop();
      if (kDebugMode) {
        final minutes = totalWatch.elapsedMilliseconds / 60000;
        final rate = minutes > 0 ? _successful / minutes : 0;
        debugPrint(
          'LOCAL INDEX: batch=${_imageEncoder.sessionBatchSize}; '
          'rate=${rate.toStringAsFixed(1)} photos/min; '
          'thumbnail=${thumbnailMs}ms; ONNX=${inferenceMs}ms; '
          'SQLite=${sqliteMs}ms; modelLoad=${modelLoadMs}ms',
        );
      }
      if (mounted) setState(() => _indexing = false);
    }
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _notice = null;
    });
    try {
      final personalQuery = await _personalization.resolveQuery(query);
      final backendQuery = personalQuery.semanticQuery.isEmpty
          ? 'photo'
          : personalQuery.semanticQuery;
      final plan = await _queryClient.createPlan(backendQuery);
      final response = await _searchEngine.searchPlan(
        plan,
        limit: AppConfig.searchLimit,
        concepts: personalQuery.matchedConcepts,
        personalOnly: personalQuery.personalOnly,
      );
      final results = (response['results'] as List)
          .cast<Map<String, dynamic>>();
      final resultAssetsById = await _resolveResultAssets(results);
      if (!mounted) return;
      setState(() {
        _lastQuery = query;
        _results = results;
        _resultAssetsById = resultAssetsById;
        _notice = response['not_confident'] == true
            ? 'Solo se muestran coincidencias con suficiente relevancia.'
            : null;
        _tab = 2;
      });
    } catch (error) {
      if (mounted) {
        final message =
            _backendHealth?.status == BackendHealthStatus.unavailable
            ? 'El servicio de búsqueda no está disponible temporalmente.'
            : 'No se pudo realizar la búsqueda. Comprueba tu conexión a Internet e inténtalo de nuevo.';
        setState(() => _notice = message);
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<Map<String, AssetEntity>> _resolveResultAssets(
    List<Map<String, dynamic>> results,
  ) async {
    final ids = results
        .map((result) => result['asset_id'])
        .whereType<String>()
        .take(AppConfig.searchLimit)
        .toSet();
    final resolved = await Future.wait(
      ids.map((id) async {
        try {
          return (id: id, asset: await AssetEntity.fromId(id));
        } catch (_) {
          return (id: id, asset: null);
        }
      }),
    );
    return {
      for (final item in resolved)
        if (item.asset != null) item.id: item.asset!,
    };
  }

  Future<List<AssetEntity>?> _pickExamples() async {
    await _ensureFullGalleryLoaded();
    if (!mounted) return null;
    if (_assets.length < 3) {
      _showMessage('Necesitas al menos 3 fotos visibles en la galería.');
      return null;
    }
    return showModalBottomSheet<List<AssetEntity>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: .92,
        child: GalleryPicker(assets: _assets),
      ),
    );
  }

  Future<Map<String, Float32List>> _embeddingsFor(
    List<AssetEntity> selected,
  ) async {
    final result = <String, Float32List>{};
    final missing = <AssetEntity>[];
    for (final asset in selected) {
      final photo = await _database.photo(asset.id);
      if (photo == null) {
        missing.add(asset);
      } else {
        result[asset.id] = photo.embedding;
      }
    }
    if (missing.isNotEmpty) {
      await _imageEncoder.load();
      final valid = await _loadThumbnailChunk(missing);
      if (valid.length != missing.length) {
        throw StateError('No fue posible leer todas las fotos seleccionadas.');
      }
      final embeddings = await _imageEncoder.encodeBatch(
        valid.map((item) => item.bytes).toList(growable: false),
      );
      final photos = List.generate(
        valid.length,
        (index) => _photo(valid[index].asset, embeddings[index]),
      );
      final persisted = await _database.upsertPhotosBatch(photos);
      if (persisted.failed.isNotEmpty) {
        throw StateError(
          'No fue posible guardar todas las fotos seleccionadas.',
        );
      }
      for (final photo in persisted.photos) {
        _index.upsert(photo);
        result[photo.assetId] = photo.embedding;
      }
      _indexedCount = await _database.photoCount();
    }
    return result;
  }

  Future<void> _configureMe() =>
      _configureConcept(id: 'me', name: 'yo', kind: 'me');

  Future<void> _addConcept() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nuevo concepto'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Ej. mi mascota'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await _configureConcept(
      id: 'custom_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      kind: 'custom',
    );
  }

  Future<void> _configureConcept({
    required String id,
    required String name,
    required String kind,
  }) async {
    final selected = await _pickExamples();
    if (selected == null) return;
    setState(() => _personalizationBusy = true);
    try {
      final examples = await _embeddingsFor(selected);
      await _personalization.saveConcept(
        id: id,
        name: name,
        kind: kind,
        examples: examples,
      );
      await _reloadConcepts();
      _showMessage('$name quedó configurado localmente.');
    } catch (error) {
      _showMessage('No se pudo guardar el concepto: $error');
    } finally {
      if (mounted) setState(() => _personalizationBusy = false);
    }
  }

  Future<void> _deleteConcept(LocalPersonalConcept concept) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Eliminar “${concept.name}”'),
        content: const Text('Se eliminará el concepto local y sus ejemplos.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _personalization.deleteConcept(concept.id);
    await _reloadConcepts();
  }

  Future<void> _recreateIndex() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Recrear índice local'),
        content: const Text(
          'Se borrará el índice de fotos. Tus conceptos personales se conservarán.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Borrar índice'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _database.clearPhotos();
    _index.clear();
    if (mounted) {
      setState(() {
        _indexedCount = 0;
        _indexNotice =
            'Índice local borrado. Pulsa Escanear / continuar para recrearlo.';
        _tab = 1;
      });
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _selectTab(int value) {
    setState(() => _tab = value);
    if (value == 4) unawaited(_checkHealth());
  }

  Future<void> _retryConnection() => _checkHealth(showFailureMessage: true);

  @override
  Widget build(BuildContext context) {
    final pages = [
      SearchPage(
        controller: _queryController,
        busy: _searching,
        notice: _notice,
        galleryCount: _galleryCount,
        hasMe: _concepts.any((concept) => concept.id == 'me'),
        hasPet: _concepts.any((concept) => concept.name == 'mi mascota'),
        onSearch: _search,
      ),
      IndexPage(
        previewAssets: _previewAssets,
        galleryCount: _galleryCount,
        indexedCount: _indexedCount,
        busy: _indexing,
        inspected: _inspected,
        totalPending: _totalPending,
        successful: _successful,
        omitted: _omitted,
        notice: _indexNotice,
        galleryState: _galleryState,
        galleryError: _galleryError,
        onRefresh: () async {
          _fullGalleryLoaded = false;
          _assets = const [];
          _assetsById = const {};
          _resultAssetsById = const {};
          await _loadGallerySummary();
        },
        onIndex: _indexPhotos,
        onCancel: () => setState(() => _cancelRequested = true),
        onOpenSettings: PhotoManager.openSetting,
      ),
      ResultsPage(
        results: _results,
        query: _lastQuery,
        assetsById: _resultAssetsById,
        onBackToSearch: () => setState(() => _tab = 0),
      ),
      PersonalizationPage(
        concepts: _concepts,
        busy: _personalizationBusy,
        onConfigureMe: _configureMe,
        onAdd: _addConcept,
        onDelete: _deleteConcept,
      ),
      SettingsPage(
        backendHealth: _backendHealth,
        connectionChecking: _connectionChecking,
        galleryCount: _galleryCount,
        indexedCount: _indexedCount,
        permissionGranted: _permissionGranted,
        permissionLimited: _galleryState == GalleryState.limited,
        onReviewPermissions: PhotoManager.openSetting,
        onRecreateIndex: _recreateIndex,
        onRetryConnection: _retryConnection,
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('FotoSearch'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _connectionChecking
                        ? Colors.orange
                        : _connected
                        ? Colors.green
                        : Colors.grey,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _connectionChecking
                      ? 'Comprobando…'
                      : _connected
                      ? 'Conectado'
                      : 'Sin conexión',
                ),
              ],
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(index: _tab, children: pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _selectTab,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.search), label: 'Buscar'),
          NavigationDestination(
            icon: Icon(Icons.photo_library),
            label: 'Índice',
          ),
          NavigationDestination(
            icon: Icon(Icons.grid_view),
            label: 'Resultados',
          ),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Personalizar'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Ajustes'),
        ],
      ),
    );
  }
}
