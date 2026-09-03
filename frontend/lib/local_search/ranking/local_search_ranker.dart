import 'dart:typed_data';

import '../index/local_embedding_index.dart';
import '../local_search_config.dart';
import '../models/local_photo_embedding.dart';
import '../models/mobileclip_query_plan.dart';
import '../../personalization/personal_query.dart';

class LocalSearchHit {
  const LocalSearchHit({
    required this.assetId,
    required this.score,
    required this.finalScore,
    required this.semanticScore,
    required this.relevanceScore,
    required this.bestQueryVariant,
    required this.jointScore,
    required this.objectScore,
    required this.attributeScore,
    required this.coverageScore,
    required this.colorCompetitionScore,
    required this.compositionalScore,
    required this.metadata,
  });

  final String assetId;
  final double score;
  final double finalScore;
  final double semanticScore;
  final double relevanceScore;
  final String bestQueryVariant;
  final double jointScore;
  final double objectScore;
  final double attributeScore;
  final double coverageScore;
  final double colorCompetitionScore;
  final double compositionalScore;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toMap() => {
    'asset_id': assetId,
    'score': score,
    'final_score': finalScore,
    'semantic_score': semanticScore,
    'relevance_score': relevanceScore,
    'best_query_variant': bestQueryVariant,
    'joint_score': jointScore,
    'object_score': objectScore,
    'attribute_score': attributeScore,
    'coverage_score': coverageScore,
    'color_competition_score': colorCompetitionScore,
    'compositional_score': compositionalScore,
    'metadata': metadata,
  };
}

class LocalSearchRanker {
  Duration? lastStageADuration;
  Duration? lastStageBDuration;

  List<LocalSearchHit> rank(
    LocalEmbeddingIndex index,
    MobileClipQueryPlan plan, {
    List<LocalPersonalConcept> concepts = const [],
    bool personalOnly = false,
  }) {
    if (plan.queryEmbeddings.isEmpty && concepts.isEmpty) {
      lastStageADuration = Duration.zero;
      lastStageBDuration = Duration.zero;
      return const [];
    }
    final stageAWatch = Stopwatch()..start();
    final semanticCandidates = _SemanticMinHeap(
      LocalSearchConfig.semanticCandidates,
    );
    for (var photoIndex = 0; photoIndex < index.length; photoIndex++) {
      var bestIndex = 0;
      var bestScore = double.negativeInfinity;
      for (
        var queryIndex = 0;
        queryIndex < plan.queryEmbeddings.length;
        queryIndex++
      ) {
        final score = index.similarityAt(
          photoIndex,
          plan.queryEmbeddings[queryIndex],
        );
        if (score > bestScore) {
          bestScore = score;
          bestIndex = queryIndex;
        }
      }
      semanticCandidates.add(
        _SemanticCandidate(
          photoIndex: photoIndex,
          semanticScore: bestScore,
          bestQueryIndex: bestIndex,
        ),
      );
    }
    final candidatesByPhoto = <int, _SemanticCandidate>{
      for (final candidate in semanticCandidates.toDescendingList())
        candidate.photoIndex: candidate,
    };
    for (final concept in concepts) {
      final personalCandidates = _SemanticMinHeap(
        LocalSearchConfig.semanticCandidates,
      );
      for (var photoIndex = 0; photoIndex < index.length; photoIndex++) {
        personalCandidates.add(
          _SemanticCandidate(
            photoIndex: photoIndex,
            semanticScore: index.similarityAt(photoIndex, concept.prototype),
            bestQueryIndex: 0,
          ),
        );
      }
      for (final candidate in personalCandidates.toDescendingList()) {
        candidatesByPhoto.putIfAbsent(
          candidate.photoIndex,
          () => _SemanticCandidate(
            photoIndex: candidate.photoIndex,
            semanticScore: plan.queryEmbeddings.isEmpty
                ? 0
                : _bestSemanticScore(index, candidate.photoIndex, plan),
            bestQueryIndex: plan.queryEmbeddings.isEmpty
                ? 0
                : _bestSemanticIndex(index, candidate.photoIndex, plan),
          ),
        );
      }
    }
    final topCandidates = candidatesByPhoto.values.toList(growable: false);
    stageAWatch.stop();
    lastStageADuration = stageAWatch.elapsed;
    final stageBWatch = Stopwatch()..start();
    final hits = <LocalSearchHit>[];
    for (final candidate in topCandidates) {
      final photo = index.photoAt(candidate.photoIndex);
      final constraint = plan.constraints;
      final jointScore = candidate.semanticScore;
      var objectScore = 0.0;
      var attributeScore = 0.0;
      var coverageScore = 0.0;
      var colorCompetitionScore = 0.0;
      var compositionalScore = candidate.semanticScore;
      if (constraint.object != null && constraint.attribute != null) {
        objectScore = _similarity(
          index,
          candidate.photoIndex,
          constraint.object!.embedding,
        );
        attributeScore = _similarity(
          index,
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
        final targetColorScore = _similarity(
          index,
          candidate.photoIndex,
          constraint.targetColorJoint!.embedding,
        );
        var alternativeScore = double.negativeInfinity;
        for (final competitor in constraint.colorCompetitors) {
          final score = _similarity(
            index,
            candidate.photoIndex,
            competitor.embedding,
          );
          if (score > alternativeScore) alternativeScore = score;
        }
        colorCompetitionScore = targetColorScore - alternativeScore;
        compositionalScore +=
            LocalSearchConfig.compositionalColorCompetitionWeight *
            colorCompetitionScore;
      }
      final personalScore = concepts.isEmpty
          ? 0.0
          : _combinedPersonalScore(index, candidate.photoIndex, concepts);
      final finalScore = concepts.isEmpty
          ? LocalSearchConfig.semanticWeight * compositionalScore
          : personalOnly
          ? personalScore
          : 0.55 * compositionalScore + 0.45 * personalScore;
      hits.add(
        LocalSearchHit(
          assetId: photo.assetId,
          score: finalScore,
          finalScore: finalScore,
          semanticScore: candidate.semanticScore,
          relevanceScore: candidate.semanticScore,
          bestQueryVariant: plan.jointVariants.isEmpty
              ? ''
              : plan.jointVariants[candidate.bestQueryIndex],
          jointScore: jointScore,
          objectScore: objectScore,
          attributeScore: attributeScore,
          coverageScore: coverageScore,
          colorCompetitionScore: colorCompetitionScore,
          compositionalScore: compositionalScore,
          metadata: _metadata(photo),
        ),
      );
    }
    hits.sort((left, right) => right.finalScore.compareTo(left.finalScore));
    stageBWatch.stop();
    lastStageBDuration = stageBWatch.elapsed;
    return hits;
  }

  static int _bestSemanticIndex(
    LocalEmbeddingIndex index,
    int photoIndex,
    MobileClipQueryPlan plan,
  ) {
    var bestIndex = 0;
    var bestScore = double.negativeInfinity;
    for (
      var queryIndex = 0;
      queryIndex < plan.queryEmbeddings.length;
      queryIndex++
    ) {
      final score = index.similarityAt(
        photoIndex,
        plan.queryEmbeddings[queryIndex],
      );
      if (score > bestScore) {
        bestScore = score;
        bestIndex = queryIndex;
      }
    }
    return bestIndex;
  }

  static double _bestSemanticScore(
    LocalEmbeddingIndex index,
    int photoIndex,
    MobileClipQueryPlan plan,
  ) => index.similarityAt(
    photoIndex,
    plan.queryEmbeddings[_bestSemanticIndex(index, photoIndex, plan)],
  );

  static double _combinedPersonalScore(
    LocalEmbeddingIndex index,
    int photoIndex,
    List<LocalPersonalConcept> concepts,
  ) {
    var combined = double.infinity;
    for (final concept in concepts) {
      final prototypeScore = index.similarityAt(photoIndex, concept.prototype);
      var exampleScore = double.negativeInfinity;
      for (final example in concept.examples) {
        final score = index.similarityAt(photoIndex, example);
        if (score > exampleScore) exampleScore = score;
      }
      if (exampleScore == double.negativeInfinity) {
        exampleScore = prototypeScore;
      }
      final score = 0.40 * prototypeScore + 0.60 * exampleScore;
      if (score < combined) combined = score;
    }
    return combined;
  }

  double _similarity(
    LocalEmbeddingIndex index,
    int photoIndex,
    Float32List query,
  ) => index.similarityAt(photoIndex, query);

  Map<String, dynamic> _metadata(LocalPhotoMetadata photo) {
    final metadata = <String, dynamic>{
      'width': photo.width,
      'height': photo.height,
    };
    if (photo.createdAtMs != null) {
      metadata['created_at'] = DateTime.fromMillisecondsSinceEpoch(
        photo.createdAtMs!,
      ).toIso8601String();
    }
    return metadata;
  }
}

class _SemanticCandidate {
  const _SemanticCandidate({
    required this.photoIndex,
    required this.semanticScore,
    required this.bestQueryIndex,
  });

  final int photoIndex;
  final double semanticScore;
  final int bestQueryIndex;
}

/// Bounded min-heap: Stage A retains at most 100 candidates for O(N log 100)
/// time and O(100) candidate memory.
class _SemanticMinHeap {
  _SemanticMinHeap(this._maximum);

  final int _maximum;
  final List<_SemanticCandidate> _items = <_SemanticCandidate>[];

  void add(_SemanticCandidate candidate) {
    if (_items.length < _maximum) {
      _items.add(candidate);
      _siftUp(_items.length - 1);
      return;
    }
    if (candidate.semanticScore <= _items.first.semanticScore) return;
    _items[0] = candidate;
    _siftDown(0);
  }

  List<_SemanticCandidate> toDescendingList() {
    final result = List<_SemanticCandidate>.of(_items);
    result.sort(
      (left, right) => right.semanticScore.compareTo(left.semanticScore),
    );
    return result;
  }

  void _siftUp(int index) {
    while (index > 0) {
      final parent = (index - 1) ~/ 2;
      if (_items[parent].semanticScore <= _items[index].semanticScore) return;
      final item = _items[parent];
      _items[parent] = _items[index];
      _items[index] = item;
      index = parent;
    }
  }

  void _siftDown(int index) {
    while (true) {
      final left = index * 2 + 1;
      if (left >= _items.length) return;
      final right = left + 1;
      final child =
          right < _items.length &&
              _items[right].semanticScore < _items[left].semanticScore
          ? right
          : left;
      if (_items[index].semanticScore <= _items[child].semanticScore) return;
      final item = _items[index];
      _items[index] = _items[child];
      _items[child] = item;
      index = child;
    }
  }
}
