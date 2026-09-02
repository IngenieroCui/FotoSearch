import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_search/index/local_embedding_index.dart';
import 'local_search/local_search_config.dart';
import 'local_search/local_search_engine.dart';
import 'local_search/mobileclip/mobileclip_image_encoder.dart';
import 'local_search/mobileclip/mobileclip_query_client.dart';
import 'local_search/models/local_photo_embedding.dart';
import 'local_search/storage/local_search_database.dart';

const _galleryPermissionOption = PermissionRequestOption(
  androidPermission: AndroidPermission(
    type: RequestType.image,
    mediaLocation: false,
  ),
);

abstract final class AppConfig {
  static String get apiBaseUrl => _string(
    const String.fromEnvironment('FOTOSEARCH_API_BASE_URL'),
    'FOTOSEARCH_API_BASE_URL',
    'http://10.0.2.2:8000/api',
  );

  static int get requestTimeoutSeconds => _number(
    const String.fromEnvironment('FOTOSEARCH_REQUEST_TIMEOUT_SECONDS'),
    'FOTOSEARCH_REQUEST_TIMEOUT_SECONDS',
    30,
  );

  static int get searchLimit => _number(
    const String.fromEnvironment('FOTOSEARCH_SEARCH_LIMIT'),
    'FOTOSEARCH_SEARCH_LIMIT',
    30,
  );

  static String _string(String buildValue, String key, String fallback) {
    if (buildValue.trim().isNotEmpty) return buildValue.trim();
    final environmentValue = dotenv.env[key]?.trim();
    return environmentValue?.isNotEmpty == true ? environmentValue! : fallback;
  }

  static int _number(String buildValue, String key, int fallback) =>
      int.tryParse(_string(buildValue, key, '$fallback')) ?? fallback;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  runApp(const FotoSearchApp());
}

class FotoSearchApp extends StatelessWidget {
  const FotoSearchApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'FotoSearch',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: const FotoSearchHome(),
  );
}

class FotoSearchHome extends StatefulWidget {
  const FotoSearchHome({super.key});

  @override
  State<FotoSearchHome> createState() => _FotoSearchHomeState();
}

class _FotoSearchHomeState extends State<FotoSearchHome> {
  final _database = LocalSearchDatabase();
  final _index = LocalEmbeddingIndex();
  final _imageEncoder = MobileClipImageEncoder();
  final _queryController = TextEditingController();
  List<AssetEntity> _assets = const [];
  Map<String, AssetEntity> _assetsById = const {};
  List<Map<String, dynamic>> _results = const [];
  String _apiBaseUrl = AppConfig.apiBaseUrl;
  String _indexNotice = '';
  String? _notice;
  String _lastQuery = '';
  int _tab = 0;
  bool _indexing = false;
  bool _searching = false;
  bool _cancelRequested = false;

  MobileClipQueryClient get _queryClient => MobileClipQueryClient(
    baseUrl: _apiBaseUrl,
    timeout: Duration(seconds: AppConfig.requestTimeoutSeconds),
  );
  LocalSearchEngine get _searchEngine => LocalSearchEngine(
    queryClient: _queryClient,
    database: _database,
    index: _index,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _queryController.dispose();
    unawaited(_imageEncoder.dispose());
    unawaited(_database.close());
    super.dispose();
  }

  Future<void> _initialize() async {
    final preferences = await SharedPreferences.getInstance();
    final savedUrl = preferences.getString('api_base_url')?.trim();
    if (savedUrl?.isNotEmpty == true) {
      _apiBaseUrl = savedUrl!;
    }
    await _loadGallery(requestPermission: true);
  }

  Future<void> _loadGallery({bool requestPermission = false}) async {
    final permission = requestPermission
        ? await PhotoManager.requestPermissionExtend(
            requestOption: _galleryPermissionOption,
          )
        : await PhotoManager.getPermissionState(
            requestOption: _galleryPermissionOption,
          );
    if (!permission.hasAccess) {
      if (mounted) {
        setState(
          () => _notice = 'Da permiso a la galería para usar FotoSearch.',
        );
      }
      return;
    }
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
    );
    if (paths.isEmpty) {
      if (mounted) setState(() => _assets = const []);
      return;
    }
    final count = await paths.first.assetCountAsync;
    final assets = <AssetEntity>[];
    for (var page = 0; page * 1000 < count; page++) {
      assets.addAll(
        await paths.first.getAssetListPaged(page: page, size: 1000),
      );
    }
    if (!mounted) return;
    setState(() {
      _assets = assets;
      _assetsById = {for (final asset in assets) asset.id: asset};
      _notice = permission.isLimited
          ? 'Acceso limitado: ${assets.length} fotos seleccionadas.'
          : '${assets.length} fotos disponibles.';
    });
  }

  Future<void> _indexPhotos() async {
    if (_indexing) return;
    if (_assets.isEmpty) await _loadGallery();
    if (_assets.isEmpty) return;
    setState(() {
      _indexing = true;
      _cancelRequested = false;
      _indexNotice = 'Preparando índice local…';
    });
    var newCount = 0;
    var modifiedCount = 0;
    var existingCount = 0;
    var failedCount = 0;
    var thumbnailMs = 0;
    var inferenceMs = 0;
    var sqliteMs = 0;
    var modelLoadMs = 0;
    final total = Stopwatch()..start();
    try {
      await _database.open();
      if (_index.length == 0 && await _database.photoCount() > 0) {
        await _index.reload(_database);
      }
      final states = await _database.photoStates();
      final pending = <AssetEntity>[];
      final galleryIds = <String>{};
      for (final asset in _assets) {
        galleryIds.add(asset.id);
        final state = states[asset.id];
        if (state != null &&
            state.modifiedAtMs ==
                asset.modifiedDateTime.millisecondsSinceEpoch &&
            state.embeddingVersion == LocalSearchConfig.embeddingVersion) {
          existingCount++;
        } else {
          pending.add(asset);
          state == null ? newCount++ : modifiedCount++;
        }
      }
      // Reserve the exact known number of new rows; no exponential over-allocation.
      _index.ensureCapacity(_index.length + newCount);
      if (pending.isNotEmpty) {
        final watch = Stopwatch()..start();
        await _imageEncoder.load();
        watch.stop();
        modelLoadMs = watch.elapsedMilliseconds;
      }
      final buffer = <LocalPhotoEmbedding>[];
      var processed = 0;

      Future<void> flush() async {
        if (buffer.isEmpty) return;
        final values = List<LocalPhotoEmbedding>.of(buffer);
        buffer.clear();
        final watch = Stopwatch()..start();
        final persisted = await _database.upsertPhotosBatch(values);
        watch.stop();
        sqliteMs += watch.elapsedMilliseconds;
        failedCount += persisted.failed.length;
        for (final photo in persisted.photos) {
          _index.upsert(photo);
        }
      }

      for (final asset in pending) {
        if (_cancelRequested) break;
        try {
          final thumbnailWatch = Stopwatch()..start();
          final bytes = await asset.thumbnailDataWithSize(
            const ThumbnailSize(
              LocalSearchConfig.localThumbnailSide,
              LocalSearchConfig.localThumbnailSide,
            ),
            format: ThumbnailFormat.jpeg,
            quality: LocalSearchConfig.localThumbnailQuality,
          );
          thumbnailWatch.stop();
          thumbnailMs += thumbnailWatch.elapsedMilliseconds;
          if (bytes == null || bytes.isEmpty) {
            failedCount++;
          } else {
            final inferenceWatch = Stopwatch()..start();
            final embedding = await _imageEncoder.encode(bytes);
            inferenceWatch.stop();
            inferenceMs += inferenceWatch.elapsedMilliseconds;
            buffer.add(
              LocalPhotoEmbedding(
                assetId: asset.id,
                modifiedAtMs: asset.modifiedDateTime.millisecondsSinceEpoch,
                createdAtMs: asset.createDateTime.millisecondsSinceEpoch,
                width: asset.width,
                height: asset.height,
                embedding: embedding,
                embeddingVersion: LocalSearchConfig.embeddingVersion,
                indexedAtMs: DateTime.now().millisecondsSinceEpoch,
              ),
            );
            if (buffer.length >= 16) await flush();
          }
        } catch (_) {
          failedCount++;
        }
        processed++;
        if (mounted && (processed == pending.length || processed % 8 == 0)) {
          setState(
            () => _indexNotice =
                'Indexando $processed/${pending.length} · $failedCount omitidas',
          );
        }
      }
      await flush();
      if (!_cancelRequested) {
        final stale = Set<String>.of(_index.assetIds).difference(galleryIds);
        if (stale.isNotEmpty) {
          final watch = Stopwatch()..start();
          await _database.deletePhotosByIds(stale);
          watch.stop();
          sqliteMs += watch.elapsedMilliseconds;
          _index.removeAssetIds(stale);
        }
      }
      total.stop();
      if (kDebugMode) {
        debugPrint(
          'LOCAL INDEX: total=${total.elapsedMilliseconds}ms; modelLoad=${modelLoadMs}ms; thumbnail=${thumbnailMs}ms; inference=${inferenceMs}ms; SQLite=${sqliteMs}ms; matrix=${_index.matrixMegabytes.toStringAsFixed(1)}MB',
        );
      }
      if (mounted) {
        setState(
          () => _indexNotice = _cancelRequested
              ? 'Indexado pausado: lo restante se conservará como pendiente.'
              : 'Índice local listo: $newCount nuevas, $modifiedCount modificadas, $existingCount existentes, $failedCount omitidas.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _indexNotice = 'No se pudo indexar: $error');
    } finally {
      if (total.isRunning) total.stop();
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
      final plan = await _queryClient.createPlan(query);
      if (plan.requiresMe) {
        setState(
          () => _notice =
              'Las búsquedas personalizadas todavía no están disponibles.',
        );
        return;
      }
      final response = await _searchEngine.searchPlan(
        plan,
        limit: AppConfig.searchLimit,
      );
      if (!mounted) return;
      setState(() {
        _lastQuery = query;
        _results = (response['results'] as List).cast<Map<String, dynamic>>();
        _notice = response['not_confident'] == true
            ? 'Solo se muestran coincidencias con suficiente relevancia.'
            : null;
        _tab = 2;
      });
    } catch (error) {
      if (mounted) setState(() => _notice = 'No se pudo buscar: $error');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _saveUrl(String value) async {
    final url = value.trim().replaceFirst(RegExp(r'/$'), '');
    if (url.isEmpty || !Uri.tryParse(url)!.hasScheme) {
      setState(() => _notice = 'Escribe una URL HTTP(S) válida.');
      return;
    }
    await (await SharedPreferences.getInstance()).setString(
      'api_base_url',
      url,
    );
    if (mounted) setState(() => _apiBaseUrl = url);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _SearchPage(
        controller: _queryController,
        busy: _searching,
        notice: _notice,
        onSearch: _search,
        onSettings: () => setState(() => _tab = 3),
      ),
      _IndexPage(
        photoCount: _assets.length,
        busy: _indexing,
        notice: _indexNotice,
        onRefresh: _loadGallery,
        onIndex: _indexPhotos,
        onCancel: () => setState(() => _cancelRequested = true),
      ),
      _ResultsPage(
        results: _results,
        query: _lastQuery,
        assetsById: _assetsById,
      ),
      _SettingsPage(url: _apiBaseUrl, onSave: _saveUrl),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('FotoSearch')),
      body: SafeArea(child: pages[_tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (value) => setState(() => _tab = value),
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
          NavigationDestination(icon: Icon(Icons.settings), label: 'Ajustes'),
        ],
      ),
    );
  }
}

class _SearchPage extends StatelessWidget {
  const _SearchPage({
    required this.controller,
    required this.busy,
    required this.notice,
    required this.onSearch,
    required this.onSettings,
  });
  final TextEditingController controller;
  final bool busy;
  final String? notice;
  final VoidCallback onSearch;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Busca en tus fotos',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text('Las fotos y sus embeddings permanecen en el teléfono.'),
        const SizedBox(height: 20),
        TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => onSearch(),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'perro, playa, camiseta roja…',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: busy ? null : onSearch,
          icon: busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.search),
          label: const Text('Buscar'),
        ),
        if (notice != null) ...[const SizedBox(height: 16), Text(notice!)],
        const Spacer(),
        TextButton(
          onPressed: onSettings,
          child: const Text('Configurar URL del backend'),
        ),
      ],
    ),
  );
}

class _IndexPage extends StatelessWidget {
  const _IndexPage({
    required this.photoCount,
    required this.busy,
    required this.notice,
    required this.onRefresh,
    required this.onIndex,
    required this.onCancel,
  });
  final int photoCount;
  final bool busy;
  final String notice;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onIndex;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Índice local', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          '$photoCount fotos en la galería. MobileCLIP y SQLite se ejecutan localmente.',
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: busy ? null : onIndex,
          child: Text(busy ? 'Indexando…' : 'Escanear fotos'),
        ),
        if (busy) TextButton(onPressed: onCancel, child: const Text('Pausar')),
        OutlinedButton(
          onPressed: busy ? null : onRefresh,
          child: const Text('Actualizar galería'),
        ),
        if (notice.isNotEmpty) ...[const SizedBox(height: 16), Text(notice)],
      ],
    ),
  );
}

class _ResultsPage extends StatelessWidget {
  const _ResultsPage({
    required this.results,
    required this.query,
    required this.assetsById,
  });
  final List<Map<String, dynamic>> results;
  final String query;
  final Map<String, AssetEntity> assetsById;

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) {
      return const Center(child: Text('Tus resultados aparecerán aquí.'));
    }
    if (results.isEmpty) {
      return Center(child: Text('No encontramos fotos para “$query”.'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final result = results[index];
        return _AssetThumbnail(asset: assetsById[result['asset_id'] as String]);
      },
    );
  }
}

class _AssetThumbnail extends StatelessWidget {
  const _AssetThumbnail({required this.asset});
  final AssetEntity? asset;

  @override
  Widget build(BuildContext context) {
    if (asset == null) return const ColoredBox(color: Colors.black12);
    return FutureBuilder<Uint8List?>(
      future: asset!.thumbnailDataWithSize(const ThumbnailSize(256, 256)),
      builder: (context, snapshot) => snapshot.data == null
          ? const ColoredBox(color: Colors.black12)
          : Image.memory(snapshot.data!, fit: BoxFit.cover),
    );
  }
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({required this.url, required this.onSave});
  final String url;
  final Future<void> Function(String) onSave;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.url,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Backend MobileCLIP',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text(
          'URL HTTPS de Vercel o una URL local de desarrollo. No guardes secretos aquí.',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'FOTOSEARCH_API_BASE_URL',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => widget.onSave(_controller.text),
          child: const Text('Guardar URL'),
        ),
      ],
    ),
  );
}
