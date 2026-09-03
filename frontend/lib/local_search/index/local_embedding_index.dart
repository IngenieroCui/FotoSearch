import 'dart:typed_data';

import '../local_search_config.dart';
import '../local_vector.dart';
import '../models/local_photo_embedding.dart';
import '../storage/local_search_database.dart';

class LocalEmbeddingIndex {
  static const _pageSize = 256;

  Float32List _matrix = Float32List(0);
  List<LocalPhotoMetadata> _metadata = <LocalPhotoMetadata>[];
  Map<String, int> _indexByAssetId = <String, int>{};
  int _length = 0;
  int _capacity = 0;

  int get length => _length;
  int get capacity => _capacity;
  double get matrixMegabytes => _matrix.lengthInBytes / 1000000;

  /// Builds the sole in-memory embedding matrix in bounded SQLite pages.
  Future<void> reload(LocalSearchDatabase database) async {
    final count = await database.photoCount();
    _matrix = Float32List(count * LocalSearchConfig.embeddingDimensions);
    _metadata = <LocalPhotoMetadata>[];
    _indexByAssetId = <String, int>{};
    _length = 0;
    _capacity = count;
    for (var offset = 0; offset < count; offset += _pageSize) {
      final page = await database.photoPage(_pageSize, offset);
      for (final photo in page) {
        _writeAt(_length, photo);
        _length++;
      }
    }
  }

  void replaceForTesting(List<LocalPhotoEmbedding> photos) {
    _matrix = Float32List(
      photos.length * LocalSearchConfig.embeddingDimensions,
    );
    _metadata = <LocalPhotoMetadata>[];
    _indexByAssetId = <String, int>{};
    _length = 0;
    _capacity = photos.length;
    for (final photo in photos) {
      _writeAt(_length, photo);
      _length++;
    }
  }

  void ensureCapacity(int minimumCapacity) {
    if (minimumCapacity <= _capacity) return;
    final newCapacity = _capacity == 0
        ? minimumCapacity
        : (_capacity + _pageSize > minimumCapacity
              ? _capacity + _pageSize
              : minimumCapacity);
    final matrix = Float32List(
      newCapacity * LocalSearchConfig.embeddingDimensions,
    );
    matrix.setRange(
      0,
      _length * LocalSearchConfig.embeddingDimensions,
      _matrix,
    );
    _matrix = matrix;
    _capacity = newCapacity;
  }

  void upsert(LocalPhotoEmbedding photo) {
    final existing = _indexByAssetId[photo.assetId];
    if (existing != null) {
      _writeAt(existing, photo, replaceMetadata: true);
      return;
    }
    ensureCapacity(_length + 1);
    _writeAt(_length, photo);
    _length++;
  }

  void removeAssetIds(Set<String> assetIds) {
    for (final assetId in assetIds) {
      final removedIndex = _indexByAssetId.remove(assetId);
      if (removedIndex == null) continue;
      final lastIndex = _length - 1;
      if (removedIndex != lastIndex) {
        final lastMetadata = _metadata[lastIndex];
        final dimension = LocalSearchConfig.embeddingDimensions;
        _matrix.setRange(
          removedIndex * dimension,
          (removedIndex + 1) * dimension,
          _matrix,
          lastIndex * dimension,
        );
        _metadata[removedIndex] = lastMetadata;
        _indexByAssetId[lastMetadata.assetId] = removedIndex;
      }
      _metadata.removeLast();
      _length--;
    }
  }

  int? indexOfAsset(String assetId) => _indexByAssetId[assetId];

  double similarityAt(int photoIndex, Float32List query) {
    if (photoIndex < 0 || photoIndex >= _length) {
      throw RangeError.index(photoIndex, _metadata, 'photoIndex');
    }
    return LocalVector.dotProductAt(
      _matrix,
      photoIndex * LocalSearchConfig.embeddingDimensions,
      query,
    );
  }

  LocalPhotoMetadata photoAt(int index) {
    if (index < 0 || index >= _length) {
      throw RangeError.index(index, _metadata, 'index');
    }
    return _metadata[index];
  }

  Iterable<String> get assetIds => _indexByAssetId.keys;

  void clear() {
    _matrix = Float32List(0);
    _metadata = <LocalPhotoMetadata>[];
    _indexByAssetId = <String, int>{};
    _length = 0;
    _capacity = 0;
  }

  void _writeAt(
    int index,
    LocalPhotoEmbedding photo, {
    bool replaceMetadata = false,
  }) {
    final dimension = LocalSearchConfig.embeddingDimensions;
    _matrix.setRange(
      index * dimension,
      (index + 1) * dimension,
      photo.embedding,
    );
    if (replaceMetadata) {
      _metadata[index] = photo.metadata;
    } else {
      _metadata.add(photo.metadata);
    }
    _indexByAssetId[photo.assetId] = index;
  }
}
