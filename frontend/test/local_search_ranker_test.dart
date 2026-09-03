import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fotosearch/local_search/index/local_embedding_index.dart';
import 'package:fotosearch/local_search/local_search_config.dart';
import 'package:fotosearch/local_search/local_vector.dart';
import 'package:fotosearch/local_search/models/local_photo_embedding.dart';
import 'package:fotosearch/local_search/models/mobileclip_query_plan.dart';
import 'package:fotosearch/local_search/ranking/local_search_ranker.dart';
import 'package:fotosearch/personalization/personal_query.dart';

void main() {
  Float32List vector(Map<int, double> values) {
    final result = Float32List(512);
    values.forEach((index, value) => result[index] = value);
    return LocalVector.normalized(result);
  }

  LocalPhotoEmbedding photo(String id, Map<int, double> values) =>
      LocalPhotoEmbedding(
        assetId: id,
        modifiedAtMs: 1,
        createdAtMs: 1,
        width: 10,
        height: 20,
        embedding: vector(values),
        embeddingVersion: 'mobileclip-s0-xenova-fp16-v1',
        indexedAtMs: 1,
      );

  MobileClipQueryPlan plan({
    required List<Float32List> queries,
    MobileClipQueryConstraints? constraints,
  }) => MobileClipQueryPlan(
    embeddingVersion: 'mobileclip-s0-xenova-fp16-v1',
    queryPipelineVersion: 'query-v5-english-only',
    original: 'query',
    semanticText: 'query',
    requiresMe: false,
    variants: const ['query'],
    jointVariants: List.generate(queries.length, (index) => 'variant $index'),
    queryEmbeddings: queries,
    constraints:
        constraints ??
        const MobileClipQueryConstraints(
          object: null,
          attribute: null,
          targetColorJoint: null,
          colorCompetitors: [],
        ),
  );

  List<LocalSearchHit> rank(
    List<LocalPhotoEmbedding> photos,
    MobileClipQueryPlan value,
  ) {
    final index = LocalEmbeddingIndex()..replaceForTesting(photos);
    return LocalSearchRanker().rank(index, value);
  }

  List<_ReferenceHit> referenceRank(
    List<LocalPhotoEmbedding> photos,
    MobileClipQueryPlan value,
  ) {
    final index = LocalEmbeddingIndex()..replaceForTesting(photos);
    final candidates = <_ReferenceCandidate>[];
    for (var photoIndex = 0; photoIndex < index.length; photoIndex++) {
      var bestQueryIndex = 0;
      var semanticScore = double.negativeInfinity;
      for (
        var queryIndex = 0;
        queryIndex < value.queryEmbeddings.length;
        queryIndex++
      ) {
        final score = index.similarityAt(
          photoIndex,
          value.queryEmbeddings[queryIndex],
        );
        if (score > semanticScore) {
          semanticScore = score;
          bestQueryIndex = queryIndex;
        }
      }
      candidates.add(
        _ReferenceCandidate(
          photoIndex: photoIndex,
          semanticScore: semanticScore,
          bestQueryIndex: bestQueryIndex,
        ),
      );
    }
    candidates.sort(
      (left, right) => right.semanticScore.compareTo(left.semanticScore),
    );
    final hits = <_ReferenceHit>[];
    for (final candidate in candidates.take(100)) {
      final constraint = value.constraints;
      final jointScore = candidate.semanticScore;
      var objectScore = 0.0;
      var attributeScore = 0.0;
      var coverageScore = 0.0;
      var colorCompetitionScore = 0.0;
      var compositionalScore = jointScore;
      if (constraint.object != null && constraint.attribute != null) {
        objectScore = index.similarityAt(
          candidate.photoIndex,
          constraint.object!.embedding,
        );
        attributeScore = index.similarityAt(
          candidate.photoIndex,
          constraint.attribute!.embedding,
        );
        coverageScore = objectScore < attributeScore
            ? objectScore
            : attributeScore;
        compositionalScore =
            LocalSearchConfig.compositionalJointWeight * jointScore +
            LocalSearchConfig.compositionalCoverageWeight * coverageScore;
      }
      if (constraint.targetColorJoint != null &&
          constraint.colorCompetitors.isNotEmpty) {
        final target = index.similarityAt(
          candidate.photoIndex,
          constraint.targetColorJoint!.embedding,
        );
        var alternative = double.negativeInfinity;
        for (final competitor in constraint.colorCompetitors) {
          final score = index.similarityAt(
            candidate.photoIndex,
            competitor.embedding,
          );
          if (score > alternative) alternative = score;
        }
        colorCompetitionScore = target - alternative;
        compositionalScore +=
            LocalSearchConfig.compositionalColorCompetitionWeight *
            colorCompetitionScore;
      }
      hits.add(
        _ReferenceHit(
          assetId: index.photoAt(candidate.photoIndex).assetId,
          semanticScore: candidate.semanticScore,
          finalScore: LocalSearchConfig.semanticWeight * compositionalScore,
          bestQueryVariant: value.jointVariants[candidate.bestQueryIndex],
        ),
      );
    }
    hits.sort((left, right) => right.finalScore.compareTo(left.finalScore));
    return hits;
  }

  test('selects the maximum semantic query variant', () {
    final hits = rank(
      [
        photo('a', {0: 1}),
        photo('b', {1: 1}),
      ],
      plan(
        queries: [
          vector({0: 1}),
          vector({1: 1}),
        ],
      ),
    );
    expect(
      hits.firstWhere((hit) => hit.assetId == 'a').bestQueryVariant,
      'variant 0',
    );
    expect(
      hits.firstWhere((hit) => hit.assetId == 'b').bestQueryVariant,
      'variant 1',
    );
  });

  test('keeps only semantic Top 100 candidates before reranking', () {
    final photos = List.generate(
      101,
      (index) => photo('p$index', {0: 1, 1: index / 100}),
    );
    final hits = rank(
      photos,
      plan(
        queries: [
          vector({0: 1}),
        ],
      ),
    );
    expect(hits, hasLength(100));
    expect(hits.map((hit) => hit.assetId), isNot(contains('p100')));
  });

  test('compositional soft-AND can promote coverage', () {
    final constraints = MobileClipQueryConstraints(
      object: MobileClipTextConstraint(
        text: 'object',
        embedding: vector({0: 1}),
      ),
      attribute: MobileClipTextConstraint(
        text: 'attribute',
        embedding: vector({1: 1}),
      ),
      targetColorJoint: null,
      colorCompetitors: const [],
    );
    final hits = rank(
      [
        photo('joint-only', {2: 1, 0: 1, 1: -0.2}),
        photo('covered', {2: 0.9, 0: 1, 1: 1}),
      ],
      plan(
        queries: [
          vector({2: 1}),
        ],
        constraints: constraints,
      ),
    );
    expect(hits.first.assetId, 'covered');
  });

  test('color competition contributes its fixed 0.10 margin', () {
    final constraints = MobileClipQueryConstraints(
      object: null,
      attribute: null,
      targetColorJoint: MobileClipTextConstraint(
        text: 'red',
        embedding: vector({3: 1}),
      ),
      colorCompetitors: [
        MobileClipTextConstraint(text: 'blue', embedding: vector({4: 1})),
      ],
    );
    final hit = rank(
      [
        photo('red', {2: 1, 3: 1, 4: -1}),
      ],
      plan(
        queries: [
          vector({2: 1}),
        ],
        constraints: constraints,
      ),
    ).single;
    expect(hit.colorCompetitionScore, greaterThan(0));
    expect(
      hit.compositionalScore,
      closeTo(hit.jointScore + 0.1 * hit.colorCompetitionScore, 1e-9),
    );
  });

  test('bounded heap is equivalent to the former all-candidates ranking', () {
    final photos = List<LocalPhotoEmbedding>.generate(
      600,
      (index) => photo('synthetic-$index', {
        0: 1,
        1: index / 599,
        2: (index % 97) / 97,
        3: (599 - index) / 599,
        4: (index % 43) / 43,
      }),
    );
    final constraints = MobileClipQueryConstraints(
      object: MobileClipTextConstraint(
        text: 'object',
        embedding: vector({1: 1}),
      ),
      attribute: MobileClipTextConstraint(
        text: 'attribute',
        embedding: vector({2: 1}),
      ),
      targetColorJoint: MobileClipTextConstraint(
        text: 'red',
        embedding: vector({3: 1}),
      ),
      colorCompetitors: [
        MobileClipTextConstraint(text: 'blue', embedding: vector({4: 1})),
      ],
    );
    final value = plan(
      queries: [
        vector({0: 1, 1: .25}),
        vector({2: 1, 3: .15}),
      ],
      constraints: constraints,
    );

    final actual = rank(photos, value);
    final expected = referenceRank(photos, value);

    expect(actual, hasLength(100));
    expect(
      actual.map((hit) => hit.assetId),
      expected.map((hit) => hit.assetId),
    );
    for (var index = 0; index < actual.length; index++) {
      expect(
        actual[index].semanticScore,
        closeTo(expected[index].semanticScore, 1e-12),
      );
      expect(
        actual[index].finalScore,
        closeTo(expected[index].finalScore, 1e-12),
      );
      expect(actual[index].bestQueryVariant, expected[index].bestQueryVariant);
    }
  });

  test('concept-only ranking is led by the photo closest to the concept', () {
    final index = LocalEmbeddingIndex()
      ..replaceForTesting([
        photo('concept', {0: 1}),
        photo('other', {1: 1}),
      ]);
    final concept = LocalPersonalConcept(
      id: 'pet',
      name: 'mi mascota',
      kind: 'custom',
      prototype: vector({0: 1}),
      examples: [
        vector({0: 1}),
      ],
      createdAtMs: 1,
    );
    final hits = LocalSearchRanker().rank(
      index,
      plan(
        queries: [
          vector({2: 1}),
        ],
      ),
      concepts: [concept],
      personalOnly: true,
    );
    expect(hits.first.assetId, 'concept');
  });

  test('semantic plus concept favors the photo satisfying both', () {
    final index = LocalEmbeddingIndex()
      ..replaceForTesting([
        photo('semantic-only', {0: 1}),
        photo('both', {0: 1, 1: 1}),
        photo('concept-only', {1: 1}),
      ]);
    final concept = LocalPersonalConcept(
      id: 'me',
      name: 'yo',
      kind: 'me',
      prototype: vector({1: 1}),
      examples: [
        vector({1: 1}),
      ],
      createdAtMs: 1,
    );
    final hits = LocalSearchRanker().rank(
      index,
      plan(
        queries: [
          vector({0: 1}),
        ],
      ),
      concepts: [concept],
    );
    expect(hits.first.assetId, 'both');
  });
}

class _ReferenceCandidate {
  const _ReferenceCandidate({
    required this.photoIndex,
    required this.semanticScore,
    required this.bestQueryIndex,
  });

  final int photoIndex;
  final double semanticScore;
  final int bestQueryIndex;
}

class _ReferenceHit {
  const _ReferenceHit({
    required this.assetId,
    required this.semanticScore,
    required this.finalScore,
    required this.bestQueryVariant,
  });

  final String assetId;
  final double semanticScore;
  final double finalScore;
  final String bestQueryVariant;
}
