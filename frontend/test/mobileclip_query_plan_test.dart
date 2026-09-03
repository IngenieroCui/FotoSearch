import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fotosearch/local_search/models/mobileclip_query_plan.dart';

void main() {
  List<double> unit(int dimension) {
    final values = List<double>.filled(512, 0);
    values[dimension] = 1;
    return values;
  }

  Map<String, dynamic> planJson() => {
    'embedding_version': 'mobileclip-s0-xenova-fp16-v1',
    'query_pipeline_version': 'query-v5-english-only',
    'original': 'camiseta roja',
    'semantic_text': 'red shirt',
    'requires_me': false,
    'variants': ['camiseta roja'],
    'joint_variants': ['red shirt'],
    'query_embeddings': [unit(0)],
    'constraints': {
      'object': {'text': 'shirt', 'embedding': unit(2)},
      'attribute': {'text': 'red', 'embedding': unit(3)},
      'target_color_joint': {'text': 'red shirt', 'embedding': unit(4)},
      'color_competitors': [
        {'text': 'blue shirt', 'embedding': unit(5)},
      ],
    },
  };

  test('parses normalized 512d query-plan and constraints', () {
    final plan = MobileClipQueryPlan.fromJson(planJson());
    expect(plan.queryEmbeddings.single.length, 512);
    expect(plan.constraints.object!.embedding.length, 512);
  });

  test('rejects incompatible versions', () {
    final json = planJson()..['embedding_version'] = 'wrong';
    expect(() => MobileClipQueryPlan.fromJson(json), throwsStateError);
  });

  test('rejects variants and embeddings with different lengths', () {
    final json = planJson()..['joint_variants'] = ['one', 'two'];
    expect(() => MobileClipQueryPlan.fromJson(json), throwsFormatException);
  });

  test('rejects non-finite vectors supplied directly', () {
    final json = planJson();
    (json['query_embeddings'] as List).first[0] = double.nan;
    expect(() => MobileClipQueryPlan.fromJson(json), throwsFormatException);
  });

  test('rejects vectors that are not already normalized', () {
    final json = planJson();
    (json['query_embeddings'] as List).first[0] = math.sqrt(4);
    expect(() => MobileClipQueryPlan.fromJson(json), throwsFormatException);
  });
}
