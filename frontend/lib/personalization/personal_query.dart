import 'dart:typed_data';

class PersonalQuery {
  const PersonalQuery({
    required this.originalQuery,
    required this.semanticQuery,
    required this.matchedConcepts,
  });

  final String originalQuery;
  final String semanticQuery;
  final List<LocalPersonalConcept> matchedConcepts;

  bool get personalOnly =>
      matchedConcepts.isNotEmpty && semanticQuery.trim().isEmpty;
}

class LocalPersonalConcept {
  const LocalPersonalConcept({
    required this.id,
    required this.name,
    required this.kind,
    required this.prototype,
    required this.examples,
    required this.createdAtMs,
  });

  final String id;
  final String name;
  final String kind;
  final Float32List prototype;
  final List<Float32List> examples;
  final int createdAtMs;
}
