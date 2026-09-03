import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

class GalleryPicker extends StatefulWidget {
  const GalleryPicker({super.key, required this.assets});
  final List<AssetEntity> assets;

  @override
  State<GalleryPicker> createState() => _GalleryPickerState();
}

class _GalleryPickerState extends State<GalleryPicker> {
  final selected = <String>{};

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        children: [
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Selecciona 3 a 5 fotos',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Text('${selected.length} de 5'),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              itemCount: widget.assets.length,
              itemBuilder: (_, index) {
                final asset = widget.assets[index];
                final isSelected = selected.contains(asset.id);
                return InkWell(
                  onTap: () => setState(() {
                    if (isSelected) {
                      selected.remove(asset.id);
                    } else if (selected.length < 5) {
                      selected.add(asset.id);
                    }
                  }),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      FutureBuilder<Uint8List?>(
                        future: asset.thumbnailDataWithSize(
                          const ThumbnailSize(240, 240),
                        ),
                        builder: (_, snapshot) => snapshot.data == null
                            ? const ColoredBox(color: Colors.black12)
                            : Image.memory(snapshot.data!, fit: BoxFit.cover),
                      ),
                      if (isSelected) ...[
                        ColoredBox(
                          color: Theme.of(context).colorScheme.primary
                              .withValues(alpha: .35),
                        ),
                        const Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                            padding: EdgeInsets.all(5),
                            child: Icon(
                              Icons.check_circle,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: selected.length < 3
                  ? null
                  : () => Navigator.pop(
                      context,
                      widget.assets
                          .where((asset) => selected.contains(asset.id))
                          .toList(),
                    ),
              child: const Text('Listo'),
            ),
          ),
        ],
      ),
    ),
  );
}
