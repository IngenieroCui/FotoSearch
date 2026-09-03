import 'dart:typed_data';

import '../local_search/local_search_config.dart';
import '../local_search/local_vector.dart';
import '../local_search/storage/local_search_database.dart';
import 'personal_query.dart';

class PersonalizationService {
  PersonalizationService(this.database);

  final LocalSearchDatabase database;

  Future<List<LocalPersonalConcept>> concepts() async {
    await database.open();
    return database.personalConcepts();
  }

  Future<PersonalQuery> resolveQuery(String query) async {
    final available = await concepts();
    return resolveWithConcepts(query, available);
  }

  static PersonalQuery resolveWithConcepts(
    String query,
    List<LocalPersonalConcept> concepts,
  ) {
    var remaining = _normalize(query);
    final matched = <LocalPersonalConcept>[];
    final ordered = List<LocalPersonalConcept>.of(concepts)
      ..sort((a, b) => b.name.length.compareTo(a.name.length));
    for (final concept in ordered) {
      final aliases = concept.id == 'me'
          ? const ['mi persona', 'conmigo', 'mío', 'mio', 'mí', 'yo']
          : [concept.name];
      var found = false;
      for (final alias in aliases) {
        final pattern = RegExp(
          '(^|\\s)${RegExp.escape(_normalize(alias))}(?=\\s|\$)',
          caseSensitive: false,
        );
        if (pattern.hasMatch(remaining)) {
          remaining = remaining.replaceAll(pattern, ' ');
          found = true;
        }
      }
      if (found) matched.add(concept);
    }
    remaining = _cleanConnectors(remaining);
    return PersonalQuery(
      originalQuery: query,
      semanticQuery: remaining,
      matchedConcepts: matched,
    );
  }

  Future<LocalPersonalConcept> saveConcept({
    required String id,
    required String name,
    required String kind,
    required Map<String, Float32List> examples,
  }) async {
    if (examples.length < 3 || examples.length > 5) {
      throw ArgumentError('Selecciona entre 3 y 5 fotos.');
    }
    final concept = LocalPersonalConcept(
      id: id,
      name: name.trim().toLowerCase(),
      kind: kind,
      prototype: buildPrototype(examples.values.toList()),
      examples: examples.values.toList(growable: false),
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await database.savePersonalConcept(concept, examples);
    return concept;
  }

  Future<void> deleteConcept(String id) => database.deletePersonalConcept(id);

  static Float32List buildPrototype(List<Float32List> examples) {
    if (examples.isEmpty) throw ArgumentError('examples must not be empty');
    final mean = Float32List(LocalSearchConfig.embeddingDimensions);
    for (final example in examples) {
      if (example.length != LocalSearchConfig.embeddingDimensions) {
        throw ArgumentError('Each example must contain 512 values.');
      }
      for (var index = 0; index < mean.length; index++) {
        mean[index] += example[index] / examples.length;
      }
    }
    return LocalVector.normalized(mean);
  }

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[¿?¡!.,;:]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _cleanConnectors(String value) {
    final connectors = RegExp(
      r'^(con|y|en|de|del|with|and|in|of)\b|\b(con|y|en|de|del|with|and|in|of)$',
      caseSensitive: false,
    );
    var cleaned = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    var previous = '';
    while (cleaned != previous) {
      previous = cleaned;
      cleaned = cleaned
          .replaceAll(connectors, ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    return cleaned;
  }
}
