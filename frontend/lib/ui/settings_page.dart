import 'package:flutter/material.dart';

import '../local_search/mobileclip/mobileclip_query_client.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.backendHealth,
    required this.connectionChecking,
    required this.galleryCount,
    required this.indexedCount,
    required this.permissionGranted,
    required this.permissionLimited,
    required this.onReviewPermissions,
    required this.onRecreateIndex,
    required this.onRetryConnection,
  });

  final BackendHealthResult? backendHealth;
  final bool connectionChecking;
  final int galleryCount;
  final int indexedCount;
  final bool permissionGranted;
  final bool permissionLimited;
  final Future<void> Function() onReviewPermissions;
  final Future<void> Function() onRecreateIndex;
  final Future<void> Function() onRetryConnection;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
    children: [
      Text('Ajustes', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 20),
      _ConnectionCard(
        health: backendHealth,
        checking: connectionChecking,
        onRetry: onRetryConnection,
      ),
      _SectionCard(
        title: 'Privacidad',
        children: const [
          Text(
            'Las fotografías y sus embeddings visuales permanecen en este dispositivo.',
          ),
        ],
      ),
      _SectionCard(
        title: 'Galería',
        children: [
          _StatusRow(label: 'Fotos disponibles', value: '$galleryCount'),
          const SizedBox(height: 6),
          Text(
            !permissionGranted
                ? 'Sin acceso'
                : permissionLimited
                ? 'Acceso limitado'
                : 'Acceso completo',
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: onReviewPermissions,
            child: const Text('Revisar permisos'),
          ),
        ],
      ),
      _SectionCard(
        title: 'Índice',
        children: [
          _StatusRow(label: 'Fotos indexadas', value: '$indexedCount'),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: onRecreateIndex,
            icon: const Icon(Icons.delete_sweep_outlined),
            label: const Text('Recrear índice local'),
          ),
        ],
      ),
    ],
  );
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.health,
    required this.checking,
    required this.onRetry,
  });

  final BackendHealthResult? health;
  final bool checking;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final connected = health?.status == BackendHealthStatus.connected;
    final message = health?.message;
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Conexión', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                if (checking)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    connected ? Icons.check : Icons.wifi_off,
                    color: connected ? Colors.green : null,
                  ),
                const SizedBox(width: 10),
                Text(
                  checking
                      ? 'Comprobando conexión…'
                      : connected
                      ? 'Conectado'
                      : 'Sin conexión',
                ),
              ],
            ),
            if (message != null) ...[const SizedBox(height: 10), Text(message)],
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: checking ? null : onRetry,
                icon: checking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 14),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(value),
      ],
    ),
  );
}
