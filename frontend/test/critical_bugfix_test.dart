import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:fotosearch/local_search/mobileclip/mobileclip_query_client.dart';
import 'package:fotosearch/ui/index_page.dart';
import 'package:fotosearch/ui/settings_page.dart';
import 'package:fotosearch/ui/results_page.dart';

void main() {
  test('health parser requires a healthy service and model', () {
    const client = MobileClipQueryClient();

    final connected = client.parseHealthResponse(
      http.Response(
        jsonEncode({'status': 'ok', 'mobileclip_text_available': true}),
        200,
      ),
    );
    expect(connected.status, BackendHealthStatus.connected);

    final unavailable = client.parseHealthResponse(
      http.Response(
        jsonEncode({'status': 'degraded', 'mobileclip_text_available': false}),
        200,
      ),
    );
    expect(unavailable.status, BackendHealthStatus.unavailable);
  });

  testWidgets('gallery loading is not shown as missing access', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: IndexPage(
          previewAssets: const [],
          galleryCount: 0,
          indexedCount: 0,
          busy: false,
          inspected: 0,
          totalPending: 0,
          successful: 0,
          omitted: 0,
          notice: '',
          galleryState: GalleryState.loading,
          galleryError: null,
          onRefresh: () async {},
          onIndex: () async {},
          onCancel: () {},
          onOpenSettings: () async {},
        ),
      ),
    );

    expect(find.text('Cargando tu galería…'), findsOneWidget);
    expect(find.text('FotoSearch necesita acceso a tu galería.'), findsNothing);
  });

  testWidgets('settings exposes human connection status and retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          backendHealth: const BackendHealthResult(
            status: BackendHealthStatus.connected,
          ),
          connectionChecking: false,
          galleryCount: 0,
          indexedCount: 0,
          permissionGranted: false,
          permissionLimited: false,
          onReviewPermissions: () async {},
          onRecreateIndex: () async {},
          onRetryConnection: () async {},
        ),
      ),
    );

    expect(find.text('Conectado'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
    expect(find.text('Backend'), findsNothing);
    expect(find.text('Production'), findsNothing);
  });

  testWidgets('empty results use the Spanish recovery state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ResultsPage(
          results: const [],
          query: 'camiseta roja',
          assetsById: const {},
          onBackToSearch: () {},
        ),
      ),
    );

    expect(find.text('No encontramos una coincidencia clara'), findsOneWidget);
    expect(find.text('Volver a buscar'), findsOneWidget);
    expect(find.text('Toca para ver'), findsNothing);
  });
}
