import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fotosearch/local_search/index/local_embedding_index.dart';
import 'package:fotosearch/local_search/models/local_photo_embedding.dart';

void main() {
  LocalPhotoEmbedding photo(String assetId, double value) =>
      LocalPhotoEmbedding(
        assetId: assetId,
        modifiedAtMs: value.toInt(),
        createdAtMs: 1,
        width: 10,
        height: 20,
        embedding: Float32List(512)..[0] = value,
        embeddingVersion: 'mobileclip-s0-xenova-fp16-v1',
        indexedAtMs: 1,
      );

  test('upsert overwrites vectors and removal keeps the index dense', () {
    final index = LocalEmbeddingIndex()..ensureCapacity(3);
    index.upsert(photo('a', 1));
    index.upsert(photo('b', 2));
    index.upsert(photo('a', 3));

    expect(index.length, 2);
    expect(index.indexOfAsset('a'), isNotNull);
    expect(
      index.similarityAt(index.indexOfAsset('a')!, Float32List(512)..[0] = 1),
      3,
    );

    index.removeAssetIds({'a'});
    expect(index.length, 1);
    expect(index.indexOfAsset('a'), isNull);
    expect(index.photoAt(0).assetId, 'b');
    expect(index.similarityAt(0, Float32List(512)..[0] = 1), 2);
  });
}
