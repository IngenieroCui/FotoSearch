import 'package:flutter/material.dart';

import '../personalization/personal_query.dart';

class PersonalizationPage extends StatelessWidget {
  const PersonalizationPage({
    super.key,
    required this.concepts,
    required this.busy,
    required this.onConfigureMe,
    required this.onAdd,
    required this.onDelete,
  });

  final List<LocalPersonalConcept> concepts;
  final bool busy;
  final Future<void> Function() onConfigureMe;
  final Future<void> Function() onAdd;
  final Future<void> Function(LocalPersonalConcept) onDelete;

  @override
  Widget build(BuildContext context) {
    final me = concepts.where((concept) => concept.id == 'me').firstOrNull;
    final custom = concepts
        .where((concept) => concept.kind == 'custom')
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: [
        Text(
          'Hazlo más tuyo',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        const Text('Crea accesos para las personas y cosas que más buscas.'),
        const SizedBox(height: 24),
        Card(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.person_outline),
                    SizedBox(width: 10),
                    Text(
                      'Yo',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  me == null
                      ? 'Selecciona de 3 a 5 fotos tuyas variadas.'
                      : 'Configurado con ${me.examples.length} fotos',
                ),
                if (me == null) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'Usa fotos con distintos fondos, ropa y lugares para obtener mejores resultados.',
                  ),
                ],
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: busy ? null : onConfigureMe,
                  child: Text(me == null ? 'Configurar' : 'Actualizar'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 26),
        Row(
          children: [
            Expanded(
              child: Text(
                'Mis conceptos',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            TextButton.icon(
              onPressed: busy ? null : onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Agregar'),
            ),
          ],
        ),
        if (custom.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Text(
              'Crea “mi mascota”, “mi carro” o cualquier concepto visual.',
            ),
          ),
        for (final concept in custom)
          Card(
            child: ListTile(
              leading: const Icon(Icons.bookmark_outline),
              title: Text(concept.name),
              subtitle: Text('${concept.examples.length} fotos'),
              trailing: IconButton(
                tooltip: 'Eliminar',
                onPressed: busy ? null : () => onDelete(concept),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          ),
        const SizedBox(height: 28),
        const Text(
          'Los conceptos se guardan en tu teléfono y no cambian el modelo de búsqueda.',
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
