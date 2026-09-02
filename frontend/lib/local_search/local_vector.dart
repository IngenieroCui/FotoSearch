import 'dart:math' as math;
import 'dart:typed_data';

abstract final class LocalVector {
  static double l2Norm(Float32List vector) {
    var sum = 0.0;
    for (final value in vector) {
      if (!value.isFinite) {
        throw ArgumentError.value(value, 'vector', 'contains NaN or Infinity');
      }
      sum += value * value;
    }
    final norm = math.sqrt(sum);
    if (!norm.isFinite || norm <= 0) {
      throw ArgumentError.value(norm, 'vector', 'has an invalid L2 norm');
    }
    return norm;
  }

  static Float32List normalized(Float32List vector) {
    final norm = l2Norm(vector);
    final result = Float32List(vector.length);
    for (var index = 0; index < vector.length; index++) {
      result[index] = vector[index] / norm;
    }
    l2Norm(result);
    return result;
  }

  static double cosineSimilarity(Float32List left, Float32List right) {
    return dotProduct(left, right);
  }

  static double dotProduct(Float32List left, Float32List right) {
    if (left.length != right.length) {
      throw ArgumentError('Vectors must have the same dimension.');
    }
    var dot = 0.0;
    for (var index = 0; index < left.length; index++) {
      dot += left[index] * right[index];
    }
    if (!dot.isFinite) throw ArgumentError('Cosine similarity is not finite.');
    return dot;
  }

  static double dotProductAt(
    Float32List matrix,
    int offset,
    Float32List query,
  ) {
    if (query.length != 512 ||
        offset < 0 ||
        offset + query.length > matrix.length) {
      throw ArgumentError('Invalid matrix offset or query dimension.');
    }
    var dot = 0.0;
    for (var index = 0; index < query.length; index++) {
      dot += matrix[offset + index] * query[index];
    }
    if (!dot.isFinite) throw ArgumentError('Dot product is not finite.');
    return dot;
  }

  static Uint8List vectorToBlob(Float32List vector) {
    if (vector.length != 512) {
      throw ArgumentError.value(vector.length, 'vector.length', 'must be 512');
    }
    final data = ByteData(512 * Float32List.bytesPerElement);
    for (var index = 0; index < vector.length; index++) {
      final value = vector[index];
      if (!value.isFinite) {
        throw ArgumentError.value(value, 'vector', 'contains NaN or Infinity');
      }
      data.setFloat32(
        index * Float32List.bytesPerElement,
        value,
        Endian.little,
      );
    }
    return data.buffer.asUint8List();
  }

  static Float32List blobToVector(Uint8List blob) {
    if (blob.lengthInBytes != 512 * Float32List.bytesPerElement) {
      throw ArgumentError.value(
        blob.lengthInBytes,
        'blob.lengthInBytes',
        'must be 2048',
      );
    }
    final data = ByteData.sublistView(blob);
    final vector = Float32List(512);
    for (var index = 0; index < vector.length; index++) {
      final value = data.getFloat32(
        index * Float32List.bytesPerElement,
        Endian.little,
      );
      if (!value.isFinite) {
        throw ArgumentError.value(value, 'blob', 'contains NaN or Infinity');
      }
      vector[index] = value;
    }
    return vector;
  }
}
