import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

enum GalleryState { checkingPermission, loading, ready, limited, denied, error }

class IndexPage extends StatelessWidget {
  const IndexPage({
    super.key,
    required this.previewAssets,
    required this.galleryCount,
    required this.indexedCount,
    required this.busy,
    required this.inspected,
    required this.totalPending,
    required this.successful,
    required this.omitted,
    required this.notice,
    required this.galleryState,
    required this.galleryError,
    required this.onRefresh,
    required this.onIndex,
    required this.onCancel,
    required this.onOpenSettings,
  });

  final List<AssetEntity> previewAssets;
  final int galleryCount;
  final int indexedCount;
  final bool busy;
  final int inspected;
  final int totalPending;
  final int successful;
  final int omitted;
  final String notice;
  final GalleryState galleryState;
  final String? galleryError;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onIndex;
  final VoidCallback onCancel;
  final Future<void> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
    children: [
      Text('Galería', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 6),
      Text('Fotos encontradas: $galleryCount'),
      if (galleryState == GalleryState.checkingPermission) ...[
        const SizedBox(height: 16),
        const _GalleryProgress(text: 'Comprobando acceso a tu galería…'),
      ] else if (galleryState == GalleryState.loading) ...[
        const SizedBox(height: 16),
        const _GalleryProgress(text: 'Cargando tu galería…'),
      ] else if (galleryState == GalleryState.denied) ...[
        const SizedBox(height: 16),
        _PermissionCard(
          text: 'FotoSearch necesita acceso a tu galería.',
          onPressed: onOpenSettings,
        ),
      ] else if (galleryState == GalleryState.limited) ...[
        const SizedBox(height: 16),
        _PermissionCard(
          text:
              'Acceso limitado: FotoSearch solo puede buscar en $galleryCount fotos.',
          onPressed: onOpenSettings,
        ),
      ] else if (galleryState == GalleryState.error) ...[
        const SizedBox(height: 16),
        _ErrorCard(
          text: galleryError ?? 'No se pudo cargar tu galería.',
          buttonText: 'Intentar de nuevo',
          onPressed: onRefresh,
        ),
      ],
      if (busy) ...[
        const SizedBox(height: 20),
        LinearProgressIndicator(
          value: totalPending == 0 ? null : inspected / totalPending,
        ),
        const SizedBox(height: 10),
        Text('Indexando $inspected / $totalPending'),
        Text('$successful correctas · $omitted omitidas'),
      ],
      const SizedBox(height: 20),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: busy ? null : onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Actualizar galería'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: busy ? null : onIndex,
        icon: const Icon(Icons.auto_awesome_motion),
        label: const Text('Escanear / continuar'),
      ),
      if (busy)
        TextButton(
          onPressed: onCancel,
          child: const Text('Pausar y continuar luego'),
        ),
      if (notice.isNotEmpty) ...[const SizedBox(height: 14), Text(notice)],
      if (!busy && indexedCount > 0) ...[
        const SizedBox(height: 20),
        Card(
          child: ListTile(
            leading: const Icon(Icons.check_circle_outline),
            title: const Text('Índice listo'),
            subtitle: Text('$indexedCount fotos disponibles para búsqueda'),
          ),
        ),
      ],
      const SizedBox(height: 24),
      Text('Vista previa', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
        ),
        itemCount: previewAssets.length.clamp(0, 12),
        itemBuilder: (_, index) => ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: _Thumbnail(asset: previewAssets[index]),
        ),
      ),
    ],
  );
}

class _GalleryProgress extends StatelessWidget {
  const _GalleryProgress({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      const SizedBox(width: 10),
      Expanded(child: Text(text)),
    ],
  );
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({required this.text, required this.onPressed});
  final String text;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: onPressed,
            child: const Text('Dar acceso a toda la galería'),
          ),
        ],
      ),
    ),
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.text,
    required this.buttonText,
    required this.onPressed,
  });
  final String text;
  final String buttonText;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: onPressed, child: Text(buttonText)),
        ],
      ),
    ),
  );
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.asset});
  final AssetEntity asset;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: asset.thumbnailDataWithSize(const ThumbnailSize(180, 180)),
    builder: (_, snapshot) => snapshot.data == null
        ? const ColoredBox(color: Colors.black12)
        : Image.memory(snapshot.data!, fit: BoxFit.cover),
  );
}
