import 'dart:typed_data';

import '../local_search_config.dart';

class LocalPhotoState {
  const LocalPhotoState({
    required this.assetId,
    required this.modifiedAtMs,
    required this.embeddingVersion,
  });

  final String assetId;
  final int modifiedAtMs;
  final String embeddingVersion;
}

class LocalPhotoEmbedding {
  LocalPhotoEmbedding({
    required this.assetId,
    required this.modifiedAtMs,
    required this.createdAtMs,
    required this.width,
    required this.height,
    required this.embedding,
    required this.embeddingVersion,
    required this.indexedAtMs,
  }) {
    if (embedding.length != LocalSearchConfig.embeddingDimensions) {
      throw ArgumentError.value(
        embedding.length,
        'embedding.length',
        'must be ${LocalSearchConfig.embeddingDimensions}',
      );
    }
  }

  final String assetId;
  final int modifiedAtMs;
  final int? createdAtMs;
  final int width;
  final int height;
  final Float32List embedding;
  final String embeddingVersion;
  final int indexedAtMs;

  LocalPhotoMetadata get metadata => LocalPhotoMetadata(
    assetId: assetId,
    modifiedAtMs: modifiedAtMs,
    createdAtMs: createdAtMs,
    width: width,
    height: height,
    embeddingVersion: embeddingVersion,
    indexedAtMs: indexedAtMs,
  );
}

/// The non-vector portion kept by the in-memory index. Embeddings live only
/// in the index matrix, avoiding a second 512-float allocation per photo.
class LocalPhotoMetadata {
  const LocalPhotoMetadata({
    required this.assetId,
    required this.modifiedAtMs,
    required this.createdAtMs,
    required this.width,
    required this.height,
    required this.embeddingVersion,
    required this.indexedAtMs,
  });

  final String assetId;
  final int modifiedAtMs;
  final int? createdAtMs;
  final int width;
  final int height;
  final String embeddingVersion;
  final int indexedAtMs;
}
