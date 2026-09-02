import 'dart:typed_data';

import '../local_search_config.dart';
import '../local_vector.dart';

class MobileClipTextConstraint {
  MobileClipTextConstraint({required this.text, required this.embedding});

  factory MobileClipTextConstraint.fromJson(Map<String, dynamic> json) =>
      MobileClipTextConstraint(
        text: _requiredString(json, 'text'),
        embedding: _embedding(json['embedding'], 'constraint embedding'),
      );

  final String text;
  final Float32List embedding;
}

class MobileClipQueryConstraints {
  const MobileClipQueryConstraints({
    required this.object,
    required this.attribute,
    required this.targetColorJoint,
    required this.colorCompetitors,
  });

  factory MobileClipQueryConstraints.fromJson(Map<String, dynamic> json) =>
      MobileClipQueryConstraints(
        object: _constraintOrNull(json['object'], 'constraints.object'),
        attribute: _constraintOrNull(
          json['attribute'],
          'constraints.attribute',
        ),
        targetColorJoint: _constraintOrNull(
          json['target_color_joint'],
          'constraints.target_color_joint',
        ),
        colorCompetitors: _maps(
          json['color_competitors'],
          'color_competitors',
        ).map(MobileClipTextConstraint.fromJson).toList(growable: false),
      );

  final MobileClipTextConstraint? object;
  final MobileClipTextConstraint? attribute;
  final MobileClipTextConstraint? targetColorJoint;
  final List<MobileClipTextConstraint> colorCompetitors;
}

class MobileClipQueryPlan {
  MobileClipQueryPlan({
    required this.embeddingVersion,
    required this.queryPipelineVersion,
    required this.original,
    required this.semanticText,
    required this.requiresMe,
    required this.variants,
    required this.jointVariants,
    required this.queryEmbeddings,
    required this.constraints,
  });

  factory MobileClipQueryPlan.fromJson(Map<String, dynamic> json) {
    final embeddingVersion = _requiredString(json, 'embedding_version');
    if (embeddingVersion != LocalSearchConfig.embeddingVersion) {
      throw StateError('Incompatible MobileCLIP embedding version');
    }
    final pipelineVersion = _requiredString(json, 'query_pipeline_version');
    if (pipelineVersion != LocalSearchConfig.queryPipelineVersion) {
      throw StateError('Incompatible query pipeline version');
    }
    final jointVariants = _strings(json['joint_variants'], 'joint_variants');
    final embeddings = _values(json['query_embeddings'], 'query_embeddings')
        .map((value) => _embedding(value, 'query embedding'))
        .toList(growable: false);
    if (jointVariants.length != embeddings.length) {
      throw FormatException(
        'joint_variants and query_embeddings must have the same length',
      );
    }
    return MobileClipQueryPlan(
      embeddingVersion: embeddingVersion,
      queryPipelineVersion: pipelineVersion,
      original: _requiredString(json, 'original'),
      semanticText: _requiredString(json, 'semantic_text'),
      requiresMe: _requiredBool(json, 'requires_me'),
      variants: _strings(json['variants'], 'variants'),
      jointVariants: jointVariants,
      queryEmbeddings: embeddings,
      constraints: MobileClipQueryConstraints.fromJson(
        _map(json['constraints'], 'constraints'),
      ),
    );
  }

  final String embeddingVersion;
  final String queryPipelineVersion;
  final String original;
  final String semanticText;
  final bool requiresMe;
  final List<String> variants;
  final List<String> jointVariants;
  final List<Float32List> queryEmbeddings;
  final MobileClipQueryConstraints constraints;
}

MobileClipTextConstraint? _constraintOrNull(Object? value, String label) =>
    value == null
    ? null
    : MobileClipTextConstraint.fromJson(_map(value, label));

Float32List _embedding(Object? value, String label) {
  final numbers = _values(value, label);
  if (numbers.length != LocalSearchConfig.embeddingDimensions) {
    throw FormatException('$label must contain exactly 512 numbers');
  }
  final vector = Float32List(numbers.length);
  for (var index = 0; index < numbers.length; index++) {
    final number = numbers[index];
    if (number is! num || !number.isFinite) {
      throw FormatException('$label contains a non-finite number');
    }
    vector[index] = number.toDouble();
  }
  final norm = LocalVector.l2Norm(vector);
  if (norm < 0.98 || norm > 1.02) {
    throw FormatException('$label is not L2-normalized (norm: $norm)');
  }
  return vector;
}

Map<String, dynamic> _map(Object? value, String label) {
  if (value is! Map) throw FormatException('$label must be an object');
  return value.map((key, item) => MapEntry(key.toString(), item));
}

List<Map<String, dynamic>> _maps(Object? value, String label) => _values(
  value,
  label,
).map((item) => _map(item, label)).toList(growable: false);

List<dynamic> _values(Object? value, String label) {
  if (value is! List) throw FormatException('$label must be a list');
  return value;
}

List<String> _strings(Object? value, String label) => _values(value, label)
    .map((item) {
      if (item is! String) throw FormatException('$label must contain strings');
      return item;
    })
    .toList(growable: false);

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key must be a bool');
  return value;
}
