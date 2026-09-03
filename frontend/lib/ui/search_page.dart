import 'package:flutter/material.dart';

class SearchPage extends StatelessWidget {
  const SearchPage({
    super.key,
    required this.controller,
    required this.busy,
    required this.notice,
    required this.galleryCount,
    required this.hasMe,
    required this.hasPet,
    required this.onSearch,
  });

  final TextEditingController controller;
  final bool busy;
  final String? notice;
  final int galleryCount;
  final bool hasMe;
  final bool hasPet;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final examples = <String>[
      'camiseta roja',
      'perro negro',
      'foto en la playa',
      if (hasPet) 'mi mascota',
      if (hasMe) 'yo en la playa',
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  const Text('FotoSearch'),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Encuentra cualquier recuerdo',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Busca en tu propia galería con palabras naturales.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 28),
        TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => onSearch(),
          decoration: const InputDecoration(
            filled: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(18)),
              borderSide: BorderSide.none,
            ),
            prefixIcon: Icon(Icons.search),
            hintText: 'Ej. persona con camiseta roja',
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: busy ? null : onSearch,
            icon: busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.manage_search),
            label: const Text('Buscar fotos'),
          ),
        ),
        if (notice != null) ...[
          const SizedBox(height: 16),
          Text(
            notice!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 28),
        Text('Prueba con', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: examples
              .map(
                (value) => ActionChip(
                  label: Text(value),
                  onPressed: () {
                    controller.text = value;
                    onSearch();
                  },
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 40),
        Card(
          child: ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text('$galleryCount fotos disponibles en tu galería'),
          ),
        ),
      ],
    );
  }
}
