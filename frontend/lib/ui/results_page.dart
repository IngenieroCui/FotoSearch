import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

class ResultsPage extends StatelessWidget {
  const ResultsPage({
    super.key,
    required this.results,
    required this.query,
    required this.assetsById,
    this.onBackToSearch,
  });

  final List<Map<String, dynamic>> results;
  final String query;
  final Map<String, AssetEntity> assetsById;
  final VoidCallback? onBackToSearch;

  @override
  Widget build(BuildContext context) {
    final assets = results
        .map((result) => assetsById[result['asset_id'] as String?])
        .whereType<AssetEntity>()
        .toList(growable: false);
    if (query.isEmpty || assets.isEmpty) {
      return _EmptyResults(
        hasQuery: query.isNotEmpty,
        onBackToSearch: onBackToSearch,
      );
    }
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            child: _ResultsHeader(query: query, count: assets.length),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: .86,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: assets.length,
            itemBuilder: (_, index) => _ResultCard(
              asset: assets[index],
              position: index + 1,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      _PhotoViewer(assets: assets, initialIndex: index),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ResultsHeader extends StatelessWidget {
  const _ResultsHeader({required this.query, required this.count});
  final String query;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.all(11),
                child: Icon(Icons.auto_awesome, color: colors.primary),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Resultados',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '“$query”',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 5),
                  Text('Encontramos $count fotos que podrían coincidir.'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.asset,
    required this.position,
    required this.onTap,
  });
  final AssetEntity asset;
  final int position;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final date = _spanishDate(asset.createDateTime);
    return Card(
      elevation: 1,
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .45)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _AssetImage(asset: asset, thumbnail: true),
            Positioned(
              top: 10,
              left: 10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .52),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Text(
                    '#$position',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 88,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xaa000000)],
                  ),
                ),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 20, 12, 11),
                    child: Row(
                      children: [
                        if (date != null) ...[
                          const Icon(
                            Icons.calendar_today_outlined,
                            size: 15,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            date,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                        const Spacer(),
                        const Icon(
                          Icons.open_in_full,
                          size: 16,
                          color: Colors.white,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults({required this.hasQuery, required this.onBackToSearch});
  final bool hasQuery;
  final VoidCallback? onBackToSearch;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasQuery ? Icons.travel_explore : Icons.search,
                size: 58,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                hasQuery
                    ? 'No encontramos una coincidencia clara'
                    : 'Tus resultados aparecerán aquí.',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              if (hasQuery) ...[
                const SizedBox(height: 8),
                const Text(
                  'Prueba describiendo otro color, objeto, persona o lugar.',
                  textAlign: TextAlign.center,
                ),
                if (onBackToSearch != null) ...[
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: onBackToSearch,
                    child: const Text('Volver a buscar'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({required this.assets, required this.initialIndex});
  final List<AssetEntity> assets;
  final int initialIndex;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late int index = widget.initialIndex;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      centerTitle: true,
      title: Text('${index + 1} de ${widget.assets.length}'),
    ),
    body: PageView.builder(
      controller: PageController(initialPage: widget.initialIndex),
      onPageChanged: (value) => setState(() => index = value),
      itemCount: widget.assets.length,
      itemBuilder: (_, value) => InteractiveViewer(
        child: Center(
          child: _AssetImage(asset: widget.assets[value], thumbnail: false),
        ),
      ),
    ),
  );
}

class _AssetImage extends StatelessWidget {
  const _AssetImage({required this.asset, required this.thumbnail});
  final AssetEntity asset;
  final bool thumbnail;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: thumbnail
        ? asset.thumbnailDataWithSize(
            const ThumbnailSize(420, 520),
            format: ThumbnailFormat.jpeg,
            quality: 82,
          )
        : asset.originBytes,
    builder: (_, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return _imagePlaceholder(context, Icons.image_outlined);
      }
      if (snapshot.hasError ||
          snapshot.data == null ||
          snapshot.data!.isEmpty) {
        return _imagePlaceholder(context, Icons.broken_image_outlined);
      }
      return Image.memory(
        snapshot.data!,
        fit: thumbnail ? BoxFit.cover : BoxFit.contain,
      );
    },
  );

  Widget _imagePlaceholder(BuildContext context, IconData icon) => ColoredBox(
    color: thumbnail
        ? Theme.of(context).colorScheme.surfaceContainerHighest
        : Colors.black,
    child: Center(
      child: Icon(
        icon,
        color: thumbnail
            ? Theme.of(context).colorScheme.onSurfaceVariant
            : Colors.white54,
        size: 28,
      ),
    ),
  );
}

String? _spanishDate(DateTime date) {
  if (date.year <= 1970) return null;
  const months = [
    'ene',
    'feb',
    'mar',
    'abr',
    'may',
    'jun',
    'jul',
    'ago',
    'sep',
    'oct',
    'nov',
    'dic',
  ];
  return '${date.day} ${months[date.month - 1]} ${date.year}';
}
