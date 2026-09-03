import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../local_search_config.dart';
import '../local_vector.dart';
import '../models/local_photo_embedding.dart';
import '../../personalization/personal_query.dart';

class LocalPhotoBatchUpsertResult {
  const LocalPhotoBatchUpsertResult({
    required this.photos,
    required this.failed,
  });

  final List<LocalPhotoEmbedding> photos;
  final List<LocalPhotoEmbedding> failed;
}

class LocalSearchDatabase {
  static const _databaseName = 'fotosearch_local.db';
  LocalSearchDatabase({String databaseName = _databaseName})
    : _databaseNameOverride = databaseName;

  final String _databaseNameOverride;
  Database? _database;

  Future<void> open() async {
    if (_database != null) return;
    final databasePath = path.join(
      await getDatabasesPath(),
      _databaseNameOverride,
    );
    final database = await openDatabase(
      databasePath,
      version: 2,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE photos (asset_id TEXT PRIMARY KEY, modified_at_ms INTEGER NOT NULL, created_at_ms INTEGER, width INTEGER NOT NULL, height INTEGER NOT NULL, embedding BLOB NOT NULL, embedding_version TEXT NOT NULL, indexed_at_ms INTEGER NOT NULL)',
        );
        await db.execute(
          'CREATE INDEX idx_photos_embedding_version ON photos(embedding_version)',
        );
        await _createPersonalizationTables(db);
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) await _createPersonalizationTables(db);
      },
    );
    try {
      await database.transaction((transaction) async {
        final rows = await transaction.query(
          'app_metadata',
          where: 'key = ?',
          whereArgs: ['image_embedding_version'],
          limit: 1,
        );
        final version = rows.isEmpty ? null : rows.single['value'] as String;
        if (version != null && version != LocalSearchConfig.embeddingVersion) {
          await transaction.delete('photos');
        }
        if (version == null || version != LocalSearchConfig.embeddingVersion) {
          await transaction.insert('app_metadata', {
            'key': 'image_embedding_version',
            'value': LocalSearchConfig.embeddingVersion,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });
      _database = database;
    } catch (_) {
      await database.close();
      rethrow;
    }
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    await database?.close();
  }

  Future<int> photoCount() async =>
      Sqflite.firstIntValue(
        await _requireDatabase().rawQuery('SELECT COUNT(*) FROM photos'),
      ) ??
      0;

  Future<Map<String, LocalPhotoState>> photoStates() async {
    final rows = await _requireDatabase().query(
      'photos',
      columns: ['asset_id', 'modified_at_ms', 'embedding_version'],
    );
    return {
      for (final row in rows)
        row['asset_id'] as String: LocalPhotoState(
          assetId: row['asset_id'] as String,
          modifiedAtMs: row['modified_at_ms'] as int,
          embeddingVersion: row['embedding_version'] as String,
        ),
    };
  }

  Future<LocalPhotoEmbedding?> photo(String assetId) async {
    final rows = await _requireDatabase().query(
      'photos',
      where: 'asset_id = ?',
      whereArgs: [assetId],
      limit: 1,
    );
    return rows.isEmpty ? null : _photoFromRow(rows.single);
  }

  Future<void> upsertPhoto(LocalPhotoEmbedding photo) =>
      _upsert(_requireDatabase(), photo);

  /// Persists a small inference buffer. If its transaction fails, retries each
  /// item so one bad row cannot abort the remaining local indexation.
  Future<LocalPhotoBatchUpsertResult> upsertPhotosBatch(
    List<LocalPhotoEmbedding> photos,
  ) async {
    if (photos.isEmpty) {
      return const LocalPhotoBatchUpsertResult(photos: [], failed: []);
    }
    final database = _requireDatabase();
    try {
      await database.transaction((transaction) async {
        final batch = transaction.batch();
        for (final photo in photos) {
          batch.insert(
            'photos',
            _photoValues(photo),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      });
      return LocalPhotoBatchUpsertResult(photos: photos, failed: const []);
    } catch (_) {
      final persisted = <LocalPhotoEmbedding>[];
      final failed = <LocalPhotoEmbedding>[];
      for (final photo in photos) {
        try {
          await _upsert(database, photo);
          persisted.add(photo);
        } catch (_) {
          failed.add(photo);
        }
      }
      return LocalPhotoBatchUpsertResult(photos: persisted, failed: failed);
    }
  }

  Future<List<LocalPhotoEmbedding>> photoPage(int limit, int offset) async {
    if (limit <= 0 || offset < 0) {
      throw ArgumentError('limit must be positive and offset non-negative.');
    }
    return (await _requireDatabase().query(
      'photos',
      orderBy: 'asset_id ASC',
      limit: limit,
      offset: offset,
    )).map(_photoFromRow).toList(growable: false);
  }

  Future<void> deletePhotosByIds(Set<String> assetIds) async {
    if (assetIds.isEmpty) return;
    final database = _requireDatabase();
    await database.transaction((transaction) async {
      final batch = transaction.batch();
      for (final assetId in assetIds) {
        batch.delete('photos', where: 'asset_id = ?', whereArgs: [assetId]);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<LocalPhotoEmbedding>> allPhotos() async =>
      (await _requireDatabase().query('photos'))
          .map(_photoFromRow)
          .toList(growable: false);

  Future<void> clearPhotos() => _requireDatabase().delete('photos');

  Future<List<LocalPersonalConcept>> personalConcepts() async {
    final database = _requireDatabase();
    final rows = await database.query(
      'personal_concepts',
      orderBy: 'created_at_ms ASC',
    );
    final concepts = <LocalPersonalConcept>[];
    for (final row in rows) {
      final prototypeBlob = row['prototype_embedding'];
      if (prototypeBlob is! Uint8List) {
        throw StateError('Stored personal prototype is not a BLOB.');
      }
      final exampleRows = await database.query(
        'personal_concept_examples',
        columns: ['embedding'],
        where: 'concept_id = ?',
        whereArgs: [row['id']],
      );
      concepts.add(
        LocalPersonalConcept(
          id: row['id'] as String,
          name: row['name'] as String,
          kind: row['kind'] as String,
          prototype: LocalVector.blobToVector(prototypeBlob),
          examples: exampleRows
              .map((example) {
                final blob = example['embedding'];
                if (blob is! Uint8List) {
                  throw StateError('Stored personal example is not a BLOB.');
                }
                return LocalVector.blobToVector(blob);
              })
              .toList(growable: false),
          createdAtMs: row['created_at_ms'] as int,
        ),
      );
    }
    return concepts;
  }

  Future<void> savePersonalConcept(
    LocalPersonalConcept concept,
    Map<String, Float32List> examples,
  ) async {
    if (concept.kind != 'me' && concept.kind != 'custom') {
      throw ArgumentError.value(concept.kind, 'kind', 'must be me or custom');
    }
    await _requireDatabase().transaction((transaction) async {
      await transaction.delete(
        'personal_concept_examples',
        where: 'concept_id = ?',
        whereArgs: [concept.id],
      );
      await transaction.insert('personal_concepts', {
        'id': concept.id,
        'name': concept.name,
        'kind': concept.kind,
        'prototype_embedding': LocalVector.vectorToBlob(concept.prototype),
        'created_at_ms': concept.createdAtMs,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      final batch = transaction.batch();
      for (final entry in examples.entries) {
        batch.insert('personal_concept_examples', {
          'concept_id': concept.id,
          'asset_id': entry.key,
          'embedding': LocalVector.vectorToBlob(entry.value),
        });
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> deletePersonalConcept(String id) async {
    await _requireDatabase().transaction((transaction) async {
      await transaction.delete(
        'personal_concept_examples',
        where: 'concept_id = ?',
        whereArgs: [id],
      );
      await transaction.delete(
        'personal_concepts',
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  static Future<void> _createPersonalizationTables(Database db) async {
    await db.execute(
      'CREATE TABLE personal_concepts (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, prototype_embedding BLOB NOT NULL, created_at_ms INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE personal_concept_examples (concept_id TEXT NOT NULL, asset_id TEXT NOT NULL, embedding BLOB NOT NULL, PRIMARY KEY(concept_id, asset_id))',
    );
  }

  Future<void> _upsert(DatabaseExecutor database, LocalPhotoEmbedding photo) =>
      database.insert(
        'photos',
        _photoValues(photo),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Map<String, Object?> _photoValues(LocalPhotoEmbedding photo) => {
    'asset_id': photo.assetId,
    'modified_at_ms': photo.modifiedAtMs,
    'created_at_ms': photo.createdAtMs,
    'width': photo.width,
    'height': photo.height,
    'embedding': LocalVector.vectorToBlob(photo.embedding),
    'embedding_version': photo.embeddingVersion,
    'indexed_at_ms': photo.indexedAtMs,
  };

  Database _requireDatabase() {
    final database = _database;
    if (database == null) throw StateError('LocalSearchDatabase is not open.');
    return database;
  }

  LocalPhotoEmbedding _photoFromRow(Map<String, Object?> row) {
    final blob = row['embedding'];
    if (blob is! Uint8List) throw StateError('Stored embedding is not a BLOB.');
    return LocalPhotoEmbedding(
      assetId: row['asset_id'] as String,
      modifiedAtMs: row['modified_at_ms'] as int,
      createdAtMs: row['created_at_ms'] as int?,
      width: row['width'] as int,
      height: row['height'] as int,
      embedding: LocalVector.blobToVector(blob),
      embeddingVersion: row['embedding_version'] as String,
      indexedAtMs: row['indexed_at_ms'] as int,
    );
  }
}
