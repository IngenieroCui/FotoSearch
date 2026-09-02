import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:fotosearch/local_search/models/local_photo_embedding.dart';
import 'package:fotosearch/local_search/storage/local_search_database.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SQLite persists a 512d local embedding round-trip', (_) async {
    final database = LocalSearchDatabase(
      databaseName: 'fotosearch_local_integration_test.db',
    );
    await database.open();
    await database.clearPhotos();
    final embedding = Float32List(512)..[0] = 1;
    await database.upsertPhoto(
      LocalPhotoEmbedding(
        assetId: 'integration-photo',
        modifiedAtMs: 1,
        createdAtMs: 2,
        width: 3,
        height: 4,
        embedding: embedding,
        embeddingVersion: 'mobileclip-s0-xenova-fp16-v1',
        indexedAtMs: 5,
      ),
    );
    final restored = await database.photo('integration-photo');
    expect(restored, isNotNull);
    expect(restored!.embedding, orderedEquals(embedding));
    await database.close();
  });
}
