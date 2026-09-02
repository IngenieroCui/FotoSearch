import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fotosearch/local_search/local_vector.dart';

void main() {
  Float32List vector(double seed) => Float32List.fromList(
    List<double>.generate(512, (index) => seed + index / 1000),
  );

  test('vector BLOB has 512 little-endian Float32 values', () {
    expect(LocalVector.vectorToBlob(vector(1)).lengthInBytes, 2048);
  });

  test('vector BLOB round-trips exactly as Float32', () {
    final original = vector(-0.5);
    final restored = LocalVector.blobToVector(
      LocalVector.vectorToBlob(original),
    );
    expect(restored, orderedEquals(original));
  });

  test('vector BLOB is explicitly little endian', () {
    final values = Float32List(512)..[0] = 1.0;
    final blob = LocalVector.vectorToBlob(values);
    expect(blob.sublist(0, 4), orderedEquals([0, 0, 128, 63]));
    expect(LocalVector.blobToVector(blob).first, 1.0);
  });

  test('NaN and infinity are rejected', () {
    expect(
      () => LocalVector.vectorToBlob(Float32List(512)..[3] = double.nan),
      throwsArgumentError,
    );
    expect(
      () => LocalVector.vectorToBlob(Float32List(512)..[3] = double.infinity),
      throwsArgumentError,
    );
  });

  test('incorrect BLOB size is rejected', () {
    expect(
      () => LocalVector.blobToVector(Uint8List(2047)),
      throwsArgumentError,
    );
  });

  test('dot product uses matching dimensions', () {
    final left = Float32List(512)..[0] = 2;
    final right = Float32List(512)..[0] = 3;
    expect(LocalVector.dotProduct(left, right), 6);
  });
}
