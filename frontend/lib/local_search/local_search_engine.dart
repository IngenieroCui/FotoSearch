import 'package:flutter/foundation.dart';

import 'index/local_embedding_index.dart';
import 'local_search_config.dart';
import 'mobileclip/mobileclip_query_client.dart';
import 'models/mobileclip_query_plan.dart';
import 'ranking/local_search_ranker.dart';
import 'storage/local_search_database.dart';

class LocalSearchEngine {
  LocalSearchEngine({
    required this.queryClient,
    required this.database,
    required this.index,
    LocalSearchRanker? ranker,
  }) : _ranker = ranker ?? LocalSearchRanker();

  final MobileClipQueryClient queryClient;
  final LocalSearchDatabase database;
  final LocalEmbeddingIndex index;
  final LocalSearchRanker _ranker;
  Map<String, num> lastMetrics = const <String, num>{};

  Future<Map<String, dynamic>> search(String query, {int limit = 30}) async {
    final clean = query.trim();
    if (clean.isEmpty) {
      throw ArgumentError.value(query, 'query', 'must not be empty');
    }
    return searchPlan(await queryClient.createPlan(clean), limit: limit);
  }

  Future<Map<String, dynamic>> searchPlan(
    MobileClipQueryPlan plan, {
    int limit = 30,
  }) async {
    _validatePlan(plan);
    final totalWatch = Stopwatch()..start();
    await database.open();
    final loadWatch = Stopwatch()..start();
    // A non-empty database must be loaded on the first local search. Once
    // populated, indexing mutates this same index after each SQLite commit.
    if (index.length == 0 && await database.photoCount() > 0) {
      await index.reload(database);
    }
    loadWatch.stop();
    final hits = _ranker.rank(index, plan);
    final results = hits
        .take(limit)
        .map((hit) => hit.toMap())
        .toList(growable: false);
    final bestSemantic = results.fold<double>(
      double.negativeInfinity,
      (best, result) => ((result['semantic_score'] as num).toDouble() > best)
          ? (result['semantic_score'] as num).toDouble()
          : best,
    );
    totalWatch.stop();
    lastMetrics = {
      'indexLoadMs': loadWatch.elapsedMilliseconds,
      'stageAMs': _ranker.lastStageADuration?.inMilliseconds ?? 0,
      'stageBMs': _ranker.lastStageBDuration?.inMilliseconds ?? 0,
      'totalLocalMs': totalWatch.elapsedMilliseconds,
      'indexLength': index.length,
      'indexCapacity': index.capacity,
      'matrixMB': index.matrixMegabytes,
    };
    if (kDebugMode) {
      debugPrint(
        'LOCAL SEARCH: index load ${loadWatch.elapsedMilliseconds}ms; '
        'Stage A ${_ranker.lastStageADuration?.inMilliseconds ?? 0}ms; '
        'Stage B ${_ranker.lastStageBDuration?.inMilliseconds ?? 0}ms; '
        'total ${totalWatch.elapsedMilliseconds}ms; '
        'index ${index.length}/${index.capacity}; '
        'matrix ${index.matrixMegabytes.toStringAsFixed(1)}MB',
      );
    }
    final lowConfidence =
        results.isEmpty ||
        bestSemantic < LocalSearchConfig.searchConfidenceThreshold;
    return {
      'query': plan.original,
      'semantic_query': plan.semanticText,
      'normalized_query': plan.semanticText,
      'variants': plan.variants,
      'joint_variants': plan.jointVariants,
      'results': results,
      'low_confidence': lowConfidence,
      'not_confident': lowConfidence,
      'requires_identity_setup': false,
    };
  }

  void _validatePlan(MobileClipQueryPlan plan) {
    if (plan.embeddingVersion != LocalSearchConfig.embeddingVersion) {
      throw StateError('Incompatible MobileCLIP embedding version');
    }
    if (plan.queryPipelineVersion != LocalSearchConfig.queryPipelineVersion) {
      throw StateError('Incompatible query pipeline version');
    }
  }
}
