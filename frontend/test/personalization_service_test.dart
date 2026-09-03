import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fotosearch/local_search/local_vector.dart';
import 'package:fotosearch/personalization/personal_query.dart';
import 'package:fotosearch/personalization/personalization_service.dart';

void main() {
  Float32List vector(int dimension) =>
      LocalVector.normalized(Float32List(512)..[dimension] = 1);

  final me = LocalPersonalConcept(
    id: 'me',
    name: 'yo',
    kind: 'me',
    prototype: Float32List(512)..[0] = 1,
    examples: const [],
    createdAtMs: 1,
  );
  final pet = LocalPersonalConcept(
    id: 'pet',
    name: 'mi mascota',
    kind: 'custom',
    prototype: Float32List(512)..[1] = 1,
    examples: const [],
    createdAtMs: 1,
  );

  test('resolves personal phrases and cleans semantic connectors', () {
    final cases = {
      'yo': ('', ['yo']),
      'yo con camiseta roja': ('camiseta roja', ['yo']),
      'mi mascota': ('', ['mi mascota']),
      'mi mascota en la playa': ('la playa', ['mi mascota']),
      'yo con mi mascota': ('', ['yo', 'mi mascota']),
    };
    for (final entry in cases.entries) {
      final resolved = PersonalizationService.resolveWithConcepts(entry.key, [
        me,
        pet,
      ]);
      expect(resolved.semanticQuery, entry.value.$1, reason: entry.key);
      expect(
        resolved.matchedConcepts.map((concept) => concept.name).toSet(),
        entry.value.$2.toSet(),
        reason: entry.key,
      );
    }
  });

  test('builds a normalized 512d prototype from three examples', () {
    final prototype = PersonalizationService.buildPrototype([
      vector(0),
      vector(1),
      vector(2),
    ]);
    expect(prototype, hasLength(512));
    expect(LocalVector.l2Norm(prototype), closeTo(1, 1e-6));
  });
}
