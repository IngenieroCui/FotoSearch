import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _galleryPermissionOption = PermissionRequestOption(
  androidPermission: AndroidPermission(
    type: RequestType.image,
    mediaLocation: false,
  ),
);

/// La URL guardada desde Ajustes tiene prioridad después del primer inicio.
/// Los valores predeterminados viven en `.env`; las variables `--dart-define`
/// permiten sobrescribirlas en compilaciones automatizadas.
abstract final class AppConfig {
  static String get backendUrl => _string(
        const String.fromEnvironment('FOTOSEARCH_API_BASE_URL'),
        'FOTOSEARCH_API_BASE_URL',
        'http://10.0.2.2:8000',
      );
  static int get requestTimeoutSeconds => _int(
        const String.fromEnvironment('FOTOSEARCH_REQUEST_TIMEOUT_SECONDS'),
        'FOTOSEARCH_REQUEST_TIMEOUT_SECONDS',
        30,
      );
  static int get thumbnailSide => _int(
        const String.fromEnvironment('FOTOSEARCH_THUMBNAIL_SIDE'),
        'FOTOSEARCH_THUMBNAIL_SIDE',
        768,
      );
  static int get thumbnailQuality => _int(
        const String.fromEnvironment('FOTOSEARCH_THUMBNAIL_QUALITY'),
        'FOTOSEARCH_THUMBNAIL_QUALITY',
        82,
      );
  static int get searchLimit => _int(
        const String.fromEnvironment('FOTOSEARCH_SEARCH_LIMIT'),
        'FOTOSEARCH_SEARCH_LIMIT',
        30,
      );
  static int get indexBatchSize => _int(
        const String.fromEnvironment('FOTOSEARCH_INDEX_BATCH_SIZE'),
        'FOTOSEARCH_INDEX_BATCH_SIZE',
        48,
      ).clamp(1, 64).toInt();

  static String _string(String buildValue, String key, String fallback) =>
      buildValue.isNotEmpty ? buildValue : (dotenv.env[key]?.trim().isNotEmpty == true ? dotenv.env[key]!.trim() : fallback);

  static int _int(String buildValue, String key, int fallback) =>
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
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2454d6)),
          useMaterial3: true,
        ),
        home: const FotoSearchHome(),
      );
}

class ApiClient {
  ApiClient(this.baseUrl);
  final String baseUrl;
  Uri _uri(String path, {Map<String, String>? queryParameters}) => Uri.parse('${baseUrl.replaceFirst(RegExp(r'/$'), '')}$path').replace(queryParameters: queryParameters);
  Duration get _timeout => Duration(seconds: AppConfig.requestTimeoutSeconds);

  Future<Map<String, dynamic>> health() async => _json(await http.get(_uri('/health')).timeout(_timeout));
  Future<Map<String, dynamic>> stats(String deviceId) async => _json(await http.get(_uri('/index/stats', queryParameters: {'device_id': deviceId})).timeout(_timeout));
  Future<List<dynamic>> concepts() async => _json(await http.get(_uri('/concepts')).timeout(_timeout)) as List<dynamic>;
  Future<Map<String, dynamic>> search(String deviceId, String query) async => _json(await http.post(_uri('/search'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'device_id': deviceId, 'query': query, 'limit': AppConfig.searchLimit})).timeout(_timeout));

  Future<Set<String>> pendingAssetIds(String deviceId, List<AssetEntity> assets) async {
    final response = await http
        .post(
          _uri('/index/pending'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'device_id': deviceId,
            'items': assets
                .map((asset) => {'asset_id': asset.id, 'modified_at': asset.modifiedDateTime.toIso8601String()})
                .toList(),
          }),
        )
        .timeout(_timeout);
    final json = _json(response) as Map<String, dynamic>;
    return (json['pending_asset_ids'] as List<dynamic>).cast<String>().toSet();
  }

  Future<IndexBatchResult> indexBatch(String deviceId, List<AssetEntity> assets) async {
    final entries = <Map<String, dynamic>>[];
    final files = <http.MultipartFile>[];
    var failed = 0;
    for (final asset in assets) {
      try {
        final bytes = await asset.thumbnailDataWithSize(
          ThumbnailSize(AppConfig.thumbnailSide, AppConfig.thumbnailSide),
          format: ThumbnailFormat.jpeg,
          quality: AppConfig.thumbnailQuality,
        );
        if (bytes == null || bytes.isEmpty) {
          failed++;
          continue;
        }
        entries.add({
          'asset_id': asset.id,
          'modified_at': asset.modifiedDateTime.toIso8601String(),
          'metadata': {
            'created_at': asset.createDateTime.toIso8601String(),
            'width': asset.width,
            'height': asset.height,
          },
        });
        files.add(http.MultipartFile.fromBytes('images', bytes, filename: '${asset.id}.jpg'));
      } catch (_) {
        failed++;
      }
    }
    if (entries.isEmpty) return IndexBatchResult(failed: failed);
    final request = http.MultipartRequest('POST', _uri('/index/images'))
      ..fields['device_id'] = deviceId
      ..fields['items'] = jsonEncode(entries)
      ..files.addAll(files);
    final response = await http.Response.fromStream(await request.send().timeout(_timeout));
    final result = _json(response) as Map<String, dynamic>;
    return IndexBatchResult(
      indexed: result['indexed'] as int? ?? 0,
      skipped: result['skipped'] as int? ?? 0,
      failed: failed + (result['failed'] as int? ?? 0),
    );
  }

  Future<void> feedback(String deviceId, String query, String assetId, bool relevant) async {
    await _expect(await http.post(_uri('/feedback'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'device_id': deviceId, 'query': query, 'asset_id': assetId, 'relevant': relevant, 'learn': true})).timeout(_timeout));
  }

  Future<void> correction(String deviceId, String query, AssetEntity asset) async {
    final bytes = await asset.thumbnailDataWithSize(ThumbnailSize(AppConfig.thumbnailSide, AppConfig.thumbnailSide), quality: AppConfig.thumbnailQuality);
    if (bytes == null) return;
    final request = http.MultipartRequest('POST', _uri('/feedback/correction'))
      ..fields.addAll({'device_id': deviceId, 'query': query, 'asset_id': asset.id, 'modified_at': asset.modifiedDateTime.toIso8601String()})
      ..files.add(http.MultipartFile.fromBytes('image', bytes, filename: '${asset.id}.jpg'));
    await _expect(await request.send().timeout(_timeout));
  }

  Future<void> enroll(List<AssetEntity> assets) async {
    final request = http.MultipartRequest('POST', _uri('/identities/face/enroll'));
    for (final asset in assets) {
      final bytes = await asset.thumbnailDataWithSize(ThumbnailSize(AppConfig.thumbnailSide, AppConfig.thumbnailSide), quality: 90);
      if (bytes != null) request.files.add(http.MultipartFile.fromBytes('images', bytes, filename: '${asset.id}.jpg'));
    }
    await _expect(await request.send().timeout(_timeout));
  }

  Future<void> createConcept(String name, List<AssetEntity> assets) async {
    final request = http.MultipartRequest('POST', _uri('/concepts'))..fields['name'] = name;
    for (final asset in assets) {
      final bytes = await asset.thumbnailDataWithSize(ThumbnailSize(AppConfig.thumbnailSide, AppConfig.thumbnailSide), quality: 90);
      if (bytes != null) request.files.add(http.MultipartFile.fromBytes('images', bytes, filename: '${asset.id}.jpg'));
    }
    await _expect(await request.send().timeout(_timeout));
  }

  Future<void> deleteConcept(String id) async => _expect(await http.delete(_uri('/concepts/$id')).timeout(_timeout));

  dynamic _json(http.Response response) {
    _expect(response);
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<void> _expect(http.BaseResponse response) async {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final body = response is http.StreamedResponse ? await response.stream.bytesToString() : (response as http.Response).body;
    throw Exception('Backend (${response.statusCode}): $body');
  }
}

class IndexBatchResult {
  const IndexBatchResult({this.indexed = 0, this.skipped = 0, this.failed = 0});
  final int indexed;
  final int skipped;
  final int failed;
}

class FotoSearchHome extends StatefulWidget {
  const FotoSearchHome({super.key});
  @override
  State<FotoSearchHome> createState() => _FotoSearchHomeState();
}

class _FotoSearchHomeState extends State<FotoSearchHome> {
  String _url = AppConfig.backendUrl;
  String _deviceId = '';
  int _tab = 0;
  List<AssetEntity> _assets = [];
  List<Map<String, dynamic>> _results = [];
  final Map<String, bool> _feedbackByAsset = {};
  String _lastQuery = '';
  bool _busy = false;
  bool _cancelRequested = false;
  String? _notice;
  ApiClient get _api => ApiClient(_url);

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _loadSettings();
    await _loadGallery(requestPermission: true);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() { _url = prefs.getString('backend_url') ?? _url; _deviceId = prefs.getString('device_id') ?? DateTime.now().microsecondsSinceEpoch.toString(); });
    await prefs.setString('device_id', _deviceId);
  }

  Future<void> _loadGallery({bool requestPermission = true}) async {
    final permission = requestPermission
        ? await PhotoManager.requestPermissionExtend(requestOption: _galleryPermissionOption)
        : await PhotoManager.getPermissionState(requestOption: _galleryPermissionOption);
    if (!permission.hasAccess) {
      if (!mounted) return;
      setState(() => _notice = permission == PermissionState.denied || permission == PermissionState.restricted
          ? 'Permite el acceso a Fotos desde los ajustes del sistema para continuar.'
          : 'Se necesita permiso de galería.');
      return;
    }
    final paths = await PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: true);
    if (paths.isEmpty) { setState(() => _assets = []); return; }
    final count = await paths.first.assetCountAsync;
    final items = await paths.first.getAssetListPaged(page: 0, size: count);
    setState(() {
      _assets = items;
      _notice = permission.isLimited
          ? 'Acceso limitado: ${items.length} fotos seleccionadas. Puedes ampliarlo en Ajustes.'
          : 'Fotos encontradas: ${items.length}';
    });
  }

  Future<void> _index() async {
    if (_assets.isEmpty) await _loadGallery();
    if (_assets.isEmpty) return;
    final start = await _indexResumePosition();
    var indexed = 0;
    var skipped = 0;
    var failed = 0;
    setState(() {
      _busy = true;
      _cancelRequested = false;
      _notice = start == 0 ? 'Indexando 0/${_assets.length}' : 'Reanudando $start/${_assets.length}';
    });
    try {
      const checkBatchSize = 192;
      for (var offset = start; offset < _assets.length; offset += checkBatchSize) {
        if (_cancelRequested) break;
        final checkEnd = (offset + checkBatchSize).clamp(0, _assets.length).toInt();
        final candidates = _assets.sublist(offset, checkEnd);
        final pendingIds = await _api.pendingAssetIds(_deviceId, candidates);
        final pending = candidates.where((asset) => pendingIds.contains(asset.id)).toList();
        skipped += candidates.length - pending.length;

        for (var batchStart = 0; batchStart < pending.length; batchStart += AppConfig.indexBatchSize) {
          if (_cancelRequested) break;
          final batchEnd = (batchStart + AppConfig.indexBatchSize).clamp(0, pending.length).toInt();
          final result = await _api.indexBatch(_deviceId, pending.sublist(batchStart, batchEnd));
          indexed += result.indexed;
          skipped += result.skipped;
          failed += result.failed;
          if (mounted) setState(() => _notice = 'Indexando ${offset + batchEnd}/${_assets.length} · $indexed nuevas · $failed omitidas');
        }
        if (_cancelRequested) break;
        await _saveIndexCheckpoint(candidates.last.id);
        if (mounted) setState(() => _notice = 'Indexando $checkEnd/${_assets.length} · $indexed nuevas · $failed omitidas');
      }
      if (_cancelRequested) {
        setState(() => _notice = 'Indexado pausado. Continuará desde este punto al tocar Escanear.');
      } else {
        await _clearIndexCheckpoint();
        setState(() => _notice = 'Índice sincronizado: $indexed nuevas, $skipped ya existentes, $failed omitidas.');
      }
    } catch (e) { setState(() => _notice = '$e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<int> _indexResumePosition() async {
    final prefs = await SharedPreferences.getInstance();
    final lastAssetId = prefs.getString('index_cursor_asset_id');
    if (lastAssetId == null) return 0;
    final lastIndex = _assets.indexWhere((asset) => asset.id == lastAssetId);
    return lastIndex < 0 ? 0 : lastIndex + 1;
  }

  Future<void> _saveIndexCheckpoint(String assetId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('index_cursor_asset_id', assetId);
  }

  Future<void> _clearIndexCheckpoint() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('index_cursor_asset_id');
  }

  void _cancelIndex() => setState(() => _cancelRequested = true);

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() { _busy = true; _notice = null; });
    try {
      final response = await _api.search(_deviceId, query);
      setState(() {
        _lastQuery = query.trim();
        _results = (response['results'] as List).cast<Map<String, dynamic>>();
        _feedbackByAsset.clear();
        _tab = 2;
        _notice = response['requires_identity_setup'] == true
            ? 'Configura “Yo” en Personalizar para que esta búsqueda identifique tu rostro.'
            : response['not_confident'] == true
                ? 'Solo se muestran coincidencias con suficiente relevancia.'
                : null;
      });
    } catch (e) { setState(() => _notice = '$e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  AssetEntity? _asset(String id) { for (final asset in _assets) { if (asset.id == id) return asset; } return null; }

  Future<List<AssetEntity>?> _selectPhotos(BuildContext context, {int min = 1, int max = 5}) async => showModalBottomSheet<List<AssetEntity>>(context: context, isScrollControlled: true, builder: (_) => GalleryPicker(assets: _assets, min: min, max: max));

  Future<void> _configureMe() async {
    final selected = await _selectPhotos(context, min: 3);
    if (!mounted || selected == null || selected.length < 3) return;
    await _api.enroll(selected);
    if (mounted) setState(() => _notice = 'Identidad “Yo” configurada.');
  }

  Future<void> _createConcept() async {
    final name = await _askName(context);
    if (!mounted || name == null || name.isEmpty) return;
    final selected = await _selectPhotos(context, min: 3);
    if (!mounted || selected == null || selected.length < 3) return;
    await _api.createConcept(name, selected);
    if (mounted) setState(() => _notice = 'Concepto creado: $name');
  }

  Future<void> _submitFeedback(String assetId, bool relevant) async {
    try {
      await _api.feedback(_deviceId, _lastQuery, assetId, relevant);
      if (!mounted) return;
      setState(() => _feedbackByAsset[assetId] = relevant);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(relevant
              ? 'Marcada como relevante. Se usará en esta y búsquedas parecidas.'
              : 'Marcada como no relevante. Reduciré fotos parecidas.'),
        ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo guardar el feedback: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      SearchPage(onSearch: _search, busy: _busy),
      IndexPage(assets: _assets, busy: _busy, notice: _notice, onLoad: _loadGallery, onIndex: _index, onCancel: _cancelIndex),
      ResultsPage(results: _results, query: _lastQuery, notice: _notice, assetFor: _asset, feedbackByAsset: _feedbackByAsset, onFeedback: _submitFeedback, onCorrect: () async { final selected = await _selectPhotos(context); if (selected?.isNotEmpty == true) { await _api.correction(_deviceId, _lastQuery, selected!.first); if (mounted) setState(() => _notice = 'Corrección aprendida. Busca de nuevo para ver el cambio.'); } }),
      PersonalizationPage(assets: _assets, onEnroll: _configureMe, onConcept: _createConcept, api: _api),
      SettingsPage(url: _url, onSave: (url) async { final prefs = await SharedPreferences.getInstance(); await prefs.setString('backend_url', url); setState(() { _url = url; _notice = 'URL guardada.'; }); }),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('FotoSearch'), actions: [_HealthButton(api: _api)]),
      body: SafeArea(child: Column(children: [if (_notice != null) MaterialBanner(content: Text(_notice!), actions: [TextButton(onPressed: () => setState(() => _notice = null), child: const Text('Cerrar'))]), Expanded(child: pages[_tab])])),
      bottomNavigationBar: NavigationBar(selectedIndex: _tab, onDestinationSelected: (value) => setState(() => _tab = value), destinations: const [NavigationDestination(icon: Icon(Icons.search), label: 'Buscar'), NavigationDestination(icon: Icon(Icons.photo_library_outlined), label: 'Índice'), NavigationDestination(icon: Icon(Icons.grid_view), label: 'Resultados'), NavigationDestination(icon: Icon(Icons.person_outline), label: 'Personalizar'), NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Ajustes')]),
    );
  }

  Future<String?> _askName(BuildContext context) async { final controller = TextEditingController(); return showDialog<String>(context: context, builder: (context) => AlertDialog(title: const Text('Nuevo concepto'), content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Ej. mi mascota')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')), FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Continuar'))])); }
}

class SearchPage extends StatefulWidget { const SearchPage({super.key, required this.onSearch, required this.busy}); final Future<void> Function(String) onSearch; final bool busy; @override State<SearchPage> createState() => _SearchPageState(); }
class _SearchPageState extends State<SearchPage> { final query = TextEditingController(); @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [const Spacer(), const Icon(Icons.auto_awesome, size: 54), const SizedBox(height: 14), Text('Encuentra tus recuerdos', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 22), TextField(controller: query, onSubmitted: widget.onSearch, decoration: InputDecoration(hintText: 'Ej. yo con camisa roja', prefixIcon: const Icon(Icons.search), border: const OutlineInputBorder()), textInputAction: TextInputAction.search), const SizedBox(height: 12), FilledButton.icon(onPressed: widget.busy ? null : () => widget.onSearch(query.text), icon: const Icon(Icons.search), label: const Text('Buscar')), const SizedBox(height: 18), Wrap(spacing: 8, runSpacing: 8, children: ['yo con camisa roja', 'mi mascota', 'foto en la playa'].map((e) => ActionChip(label: Text(e), onPressed: () { query.text = e; widget.onSearch(e); })).toList()), const Spacer() ])); }

class IndexPage extends StatelessWidget {
  const IndexPage({super.key, required this.assets, required this.busy, required this.notice, required this.onLoad, required this.onIndex, required this.onCancel});
  final List<AssetEntity> assets;
  final bool busy;
  final String? notice;
  final Future<void> Function() onLoad, onIndex;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final match = RegExp(r'(\d+)/(\d+)').firstMatch(notice ?? '');
    final progress = match == null ? null : int.parse(match.group(1)!) / int.parse(match.group(2)!);
    final preview = assets.take(30).toList();
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Galería', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Text('Fotos encontradas: ${assets.length}'),
        if (progress != null) ...[const SizedBox(height: 12), LinearProgressIndicator(value: progress)],
        if (notice != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(notice!)),
        OutlinedButton.icon(onPressed: busy ? null : onLoad, icon: const Icon(Icons.folder_open), label: const Text('Actualizar galería')),
        const SizedBox(height: 8),
        FilledButton.icon(onPressed: busy ? null : onIndex, icon: const Icon(Icons.sync), label: Text(busy ? 'Procesando…' : 'Escanear / continuar')),
        if (busy) TextButton.icon(onPressed: onCancel, icon: const Icon(Icons.pause_circle_outline), label: const Text('Pausar y continuar luego')),
        if (preview.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Vista previa', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Expanded(child: GridView.builder(
            itemCount: preview.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 4, mainAxisSpacing: 4),
            itemBuilder: (_, index) => ClipRRect(borderRadius: BorderRadius.circular(6), child: AssetThumbnail(asset: preview[index], size: 180)),
          )),
        ],
      ]),
    );
  }
}

class ResultsPage extends StatelessWidget {
  const ResultsPage({super.key, required this.results, required this.query, required this.notice, required this.assetFor, required this.feedbackByAsset, required this.onFeedback, required this.onCorrect});
  final List<Map<String, dynamic>> results;
  final String query;
  final String? notice;
  final AssetEntity? Function(String) assetFor;
  final Map<String, bool> feedbackByAsset;
  final Future<void> Function(String, bool) onFeedback;
  final Future<void> Function() onCorrect;

  @override
  Widget build(BuildContext context) => Column(children: [
        Padding(padding: const EdgeInsets.all(16), child: Align(alignment: Alignment.centerLeft, child: Text(query.isEmpty ? 'Busca algo para ver resultados' : 'Resultados para “$query”', style: Theme.of(context).textTheme.titleMedium))),
        Expanded(
          child: results.isEmpty
              ? const Center(child: Text('Aún no hay resultados.'))
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: .72, crossAxisSpacing: 8, mainAxisSpacing: 8),
                  itemCount: results.length,
                  itemBuilder: (_, index) {
                    final item = results[index];
                    final assetId = item['asset_id'] as String;
                    final asset = assetFor(assetId);
                    final feedback = feedbackByAsset[assetId];
                    final relevance = (item['relevance_score'] ?? item['semantic_score']) as num;
                    final label = relevance >= .30 ? 'Coincidencia alta' : relevance >= .24 ? 'Coincidencia media' : 'Coincidencia';
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(children: [
                        Expanded(child: asset == null ? const Center(child: Icon(Icons.broken_image)) : AssetThumbnail(asset: asset, size: 320)),
                        Padding(padding: const EdgeInsets.fromLTRB(8, 6, 8, 0), child: Align(alignment: Alignment.centerLeft, child: Text(label, style: Theme.of(context).textTheme.labelMedium))),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                          IconButton(tooltip: 'Sí, era relevante', color: feedback == true ? Theme.of(context).colorScheme.primary : null, onPressed: () => onFeedback(assetId, true), icon: Icon(feedback == true ? Icons.thumb_up : Icons.thumb_up_outlined)),
                          IconButton(tooltip: 'No era relevante', color: feedback == false ? Theme.of(context).colorScheme.error : null, onPressed: () => onFeedback(assetId, false), icon: Icon(feedback == false ? Icons.thumb_down : Icons.thumb_down_outlined)),
                        ]),
                      ]),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: OutlinedButton.icon(
            onPressed: query.isEmpty ? null : onCorrect,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('No está la foto que buscaba'),
          ),
        ),
      ]);
}

class PersonalizationPage extends StatefulWidget { const PersonalizationPage({super.key, required this.assets, required this.onEnroll, required this.onConcept, required this.api}); final List<AssetEntity> assets; final Future<void> Function() onEnroll, onConcept; final ApiClient api; @override State<PersonalizationPage> createState() => _PersonalizationPageState(); }
class _PersonalizationPageState extends State<PersonalizationPage> { List<dynamic> concepts = []; @override void initState() { super.initState(); _refresh(); } Future<void> _refresh() async { try { final values = await widget.api.concepts(); if (mounted) setState(() => concepts = values); } catch (_) {} } @override Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [Text('Personaliza FotoSearch', style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 10), ListTile(leading: const CircleAvatar(child: Icon(Icons.face)), title: const Text('Configurar “Yo”'), subtitle: const Text('Selecciona 3 a 5 fotos con tu rostro claro.'), trailing: const Icon(Icons.chevron_right), onTap: widget.assets.isEmpty ? null : widget.onEnroll), ListTile(leading: const CircleAvatar(child: Icon(Icons.add)), title: const Text('Crear concepto'), subtitle: const Text('Ej. mi mascota, mi carro, mi casa.'), trailing: const Icon(Icons.chevron_right), onTap: widget.assets.isEmpty ? null : () async { await widget.onConcept(); await _refresh(); }), const Divider(), ...concepts.map((c) => ListTile(title: Text(c['name'] as String), subtitle: Text((c['aliases'] as List).join(', ')), trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async { await widget.api.deleteConcept(c['id'] as String); await _refresh(); })),)]); }

class SettingsPage extends StatefulWidget { const SettingsPage({super.key, required this.url, required this.onSave}); final String url; final Future<void> Function(String) onSave; @override State<SettingsPage> createState() => _SettingsPageState(); }
class _SettingsPageState extends State<SettingsPage> { late final TextEditingController controller; @override void initState() { super.initState(); controller = TextEditingController(text: widget.url); } @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Text('Backend local', style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 12), const Text('Usa la IP local de tu PC. 10.0.2.2 solo funciona en el emulador Android.'), const SizedBox(height: 16), TextField(controller: controller, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'URL backend', hintText: 'http://192.168.1.20:8000', border: OutlineInputBorder())), const SizedBox(height: 12), FilledButton(onPressed: () => widget.onSave(controller.text.trim()), child: const Text('Guardar URL'))])); }

class _HealthButton extends StatefulWidget { const _HealthButton({required this.api}); final ApiClient api; @override State<_HealthButton> createState() => _HealthButtonState(); }
class _HealthButtonState extends State<_HealthButton> { String text = 'Verificar'; @override Widget build(BuildContext context) => TextButton(onPressed: () async { try { final r = await widget.api.health(); if (mounted) setState(() => text = r['status'] == 'ok' ? 'Conectado' : 'Error'); } catch (_) { if (mounted) setState(() => text = 'Sin conexión'); } }, child: Text(text)); }

class GalleryPicker extends StatefulWidget { const GalleryPicker({super.key, required this.assets, required this.min, required this.max}); final List<AssetEntity> assets; final int min, max; @override State<GalleryPicker> createState() => _GalleryPickerState(); }
class _GalleryPickerState extends State<GalleryPicker> { final selected = <AssetEntity>[]; @override Widget build(BuildContext context) => SafeArea(child: SizedBox(height: MediaQuery.of(context).size.height * .78, child: Column(children: [Padding(padding: const EdgeInsets.all(12), child: Row(children: [Text('Selecciona ${widget.min}-${widget.max} fotos (${selected.length})', style: Theme.of(context).textTheme.titleMedium), const Spacer(), FilledButton(onPressed: selected.length >= widget.min ? () => Navigator.pop(context, selected) : null, child: const Text('Listo'))])), Expanded(child: GridView.builder(itemCount: widget.assets.length, gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2), itemBuilder: (_, i) { final asset = widget.assets[i]; final picked = selected.any((x) => x.id == asset.id); return InkWell(onTap: () => setState(() { if (picked) { selected.removeWhere((x) => x.id == asset.id); } else if (selected.length < widget.max) { selected.add(asset); } }), child: Stack(fit: StackFit.expand, children: [AssetThumbnail(asset: asset, size: 200), if (picked) Container(color: Colors.blue.withValues(alpha: .45), child: const Icon(Icons.check_circle, color: Colors.white, size: 34))])); }))]))); }

class AssetThumbnail extends StatelessWidget {
  const AssetThumbnail({super.key, required this.asset, required this.size});
  final AssetEntity asset;
  final int size;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: asset.thumbnailDataWithSize(ThumbnailSize(size, size), quality: 80),
        builder: (_, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          return Image.memory(snapshot.data!, fit: BoxFit.cover, width: double.infinity, height: double.infinity);
        },
      );
}
