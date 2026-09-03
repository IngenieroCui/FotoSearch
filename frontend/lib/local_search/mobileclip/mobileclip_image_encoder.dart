import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../local_search_config.dart';
import '../local_vector.dart';

enum MobileClipModel { fp32, fp16 }

enum MobileClipModelSource { asset, file }

class MobileClipLoadFailure {
  const MobileClipLoadFailure({
    required this.model,
    required this.source,
    required this.stage,
    required this.errorType,
    required this.message,
  });

  final MobileClipModel model;
  final MobileClipModelSource source;
  final String stage;
  final String errorType;
  final String message;

  @override
  String toString() =>
      '${model.name} | ${source.name} | $stage | $errorType: $message';
}

class MobileClipEngineException implements Exception {
  const MobileClipEngineException(this.failures);

  final List<MobileClipLoadFailure> failures;

  @override
  String toString() => 'MobileCLIP engine initialization failed.';
}

class _ModelCandidate {
  const _ModelCandidate({
    required this.model,
    required this.asset,
    required this.expectedSize,
    required this.fileName,
  });

  final MobileClipModel model;
  final String asset;
  final int expectedSize;
  final String fileName;
}

/// Local MobileCLIP-S0 visual encoder backed by the pinned Xenova ONNX model.
class MobileClipImageEncoder {
  Future<void>? _loadFuture;
  OrtSession? _session;
  String? _inputName;
  String? _outputName;
  MobileClipModel? _activeModel;
  MobileClipModelSource? _activeSource;
  Duration? _initialLoadDuration;
  bool _disposed = false;
  bool _batchSelectionLogged = false;
  int _sessionBatchSize = LocalSearchConfig.indexInferenceBatchSize;

  Duration? get initialLoadDuration => _initialLoadDuration;
  bool get isLoaded => _session != null;
  int get sessionBatchSize => _sessionBatchSize;
  String? get activeModel => _activeModel?.name;
  String? get activeSource => _activeSource?.name;
  String? get inputName => _inputName;
  String? get outputName => _outputName;

  Future<void> load() {
    if (_disposed) {
      throw StateError('MobileClipImageEncoder has been disposed.');
    }
    if (_session != null) return Future.value();
    final existing = _loadFuture;
    if (existing != null) return existing;

    late final Future<void> tracked;
    tracked = _loadWithFallbacks().whenComplete(() {
      if (_session == null && identical(_loadFuture, tracked)) {
        _loadFuture = null;
      }
    });
    _loadFuture = tracked;
    return tracked;
  }

  Future<Float32List> encode(Uint8List imageBytes) async {
    final values = await _encodeExact([imageBytes]);
    return values.single;
  }

  Future<List<Float32List>> encodeBatch(List<Uint8List> images) async {
    if (images.isEmpty) return const [];
    if (images.length > LocalSearchConfig.indexInferenceBatchSize) {
      throw ArgumentError.value(
        images.length,
        'images.length',
        'must be <= 64',
      );
    }
    var candidate = math.min(_sessionBatchSize, images.length);
    var reducedAfterFailure = false;
    while (true) {
      try {
        final result = <Float32List>[];
        for (var offset = 0; offset < images.length; offset += candidate) {
          result.addAll(
            await _encodeExact(
              images.sublist(
                offset,
                math.min(offset + candidate, images.length),
              ),
            ),
          );
        }
        if (reducedAfterFailure && candidate < _sessionBatchSize) {
          _sessionBatchSize = candidate;
        }
        if (kDebugMode && !_batchSelectionLogged) {
          _batchSelectionLogged = true;
          debugPrint('MobileCLIP inference batch selected: $_sessionBatchSize');
        }
        return result;
      } catch (_) {
        final next = _nextBatchSize(candidate);
        if (next == null) rethrow;
        candidate = next;
        reducedAfterFailure = true;
      }
    }
  }

  Future<List<Float32List>> _encodeExact(List<Uint8List> imageBytes) async {
    await load();
    final session = _session;
    final inputName = _inputName;
    final outputName = _outputName;
    if (session == null ||
        inputName == null ||
        outputName == null ||
        _disposed) {
      throw StateError('MobileCLIP session is not available.');
    }

    final side = LocalSearchConfig.imageSide;
    final tensor = Float32List(imageBytes.length * 3 * side * side);
    for (var index = 0; index < imageBytes.length; index++) {
      _preprocessInto(imageBytes[index], tensor, index);
    }
    final input = await OrtValue.fromList(tensor, [
      imageBytes.length,
      3,
      side,
      side,
    ]);
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run({inputName: input});
      final output = outputs[outputName];
      if (output == null) {
        throw StateError(
          'Expected MobileCLIP output "$outputName" was not returned.',
        );
      }
      final values = await output.asFlattenedList();
      final expected =
          imageBytes.length * LocalSearchConfig.embeddingDimensions;
      if (values.length != expected) {
        throw StateError(
          'MobileCLIP output has ${values.length} values; expected '
          '$expected.',
        );
      }
      if (kDebugMode) {
        debugPrint(
          'MobileCLIP output shape=${output.shape} values=${values.length}',
        );
      }
      return List<Float32List>.generate(imageBytes.length, (row) {
        final embedding = Float32List(LocalSearchConfig.embeddingDimensions);
        final offset = row * LocalSearchConfig.embeddingDimensions;
        for (var column = 0; column < embedding.length; column++) {
          embedding[column] = (values[offset + column] as num).toDouble();
        }
        return LocalVector.normalized(embedding);
      }, growable: false);
    } finally {
      await input.dispose();
      if (outputs != null) {
        for (final output in outputs.values) {
          await output.dispose();
        }
      }
    }
  }

  static int? _nextBatchSize(int current) {
    for (final size in const [64, 32, 16, 8, 1]) {
      if (size < current) return size;
    }
    return null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final loading = _loadFuture;
    if (loading != null) {
      try {
        await loading;
      } catch (_) {
        // The failed load has no native session left to close.
      }
    }
    final session = _session;
    _session = null;
    if (session != null) await session.close();
  }

  Future<void> _loadWithFallbacks() async {
    final stopwatch = Stopwatch()..start();
    final failures = <MobileClipLoadFailure>[];
    const candidates = [
      _ModelCandidate(
        model: MobileClipModel.fp32,
        asset: LocalSearchConfig.visionModelPrimaryAsset,
        expectedSize: 45543630,
        fileName: 'vision_model.onnx',
      ),
      _ModelCandidate(
        model: MobileClipModel.fp16,
        asset: LocalSearchConfig.visionModelFallbackAsset,
        expectedSize: 22876479,
        fileName: 'vision_model_fp16.onnx',
      ),
    ];
    try {
      for (final candidate in candidates) {
        ByteData assetData;
        try {
          assetData = await rootBundle.load(candidate.asset);
        } catch (error) {
          _recordLoadFailure(
            failures,
            candidate,
            MobileClipModelSource.asset,
            'asset_read',
            error,
          );
          continue;
        }
        final bytes = assetData.buffer.asUint8List(
          assetData.offsetInBytes,
          assetData.lengthInBytes,
        );
        if (bytes.length != candidate.expectedSize) {
          final error = StateError(
            'MODEL_ASSET_INVALID_SIZE asset=${candidate.asset} '
            'expected=${candidate.expectedSize} actual=${bytes.length}',
          );
          _recordLoadFailure(
            failures,
            candidate,
            MobileClipModelSource.asset,
            'asset_size',
            error,
          );
          continue;
        }

        OrtSession? assetSession;
        try {
          assetSession = await OnnxRuntime().createSessionFromAsset(
            candidate.asset,
          );
        } catch (error) {
          _recordLoadFailure(
            failures,
            candidate,
            MobileClipModelSource.asset,
            'session_from_asset',
            error,
          );
        }
        if (assetSession != null &&
            await _activateSession(
              assetSession,
              candidate,
              MobileClipModelSource.asset,
              failures,
            )) {
          return;
        }

        File modelFile;
        try {
          final support = await getApplicationSupportDirectory();
          final directory = Directory(
            path.join(support.path, 'fotosearch_models'),
          );
          await directory.create(recursive: true);
          modelFile = File(path.join(directory.path, candidate.fileName));
          final validExisting =
              await modelFile.exists() &&
              await modelFile.length() == candidate.expectedSize;
          if (!validExisting) {
            await modelFile.writeAsBytes(bytes, flush: true);
          }
        } catch (error) {
          _recordLoadFailure(
            failures,
            candidate,
            MobileClipModelSource.file,
            'filesystem_write',
            error,
          );
          continue;
        }

        OrtSession? fileSession;
        try {
          fileSession = await OnnxRuntime().createSession(modelFile.path);
        } catch (error) {
          _recordLoadFailure(
            failures,
            candidate,
            MobileClipModelSource.file,
            'session_from_file',
            error,
          );
        }
        if (fileSession != null &&
            await _activateSession(
              fileSession,
              candidate,
              MobileClipModelSource.file,
              failures,
            )) {
          return;
        }
      }
      final exception = MobileClipEngineException(List.unmodifiable(failures));
      if (kDebugMode) {
        debugPrint('MOBILECLIP ENGINE FAILURE\n${failures.join('\n')}');
      }
      throw exception;
    } finally {
      stopwatch.stop();
      if (_session != null) {
        _initialLoadDuration ??= stopwatch.elapsed;
        if (kDebugMode) {
          debugPrint(
            'MOBILECLIP ENGINE READY\n'
            'model=${_activeModel?.name}\n'
            'source=${_activeSource?.name}\n'
            'input=$_inputName\n'
            'output=$_outputName\n'
            'preferredBatch=$_sessionBatchSize\n'
            'loadMs=${stopwatch.elapsedMilliseconds}',
          );
        }
      }
    }
  }

  Future<bool> _activateSession(
    OrtSession session,
    _ModelCandidate candidate,
    MobileClipModelSource source,
    List<MobileClipLoadFailure> failures,
  ) async {
    var accepted = false;
    try {
      final inputName = session.inputNames.contains('pixel_values')
          ? 'pixel_values'
          : session.inputNames.length == 1
          ? session.inputNames.single
          : null;
      final outputName = session.outputNames.contains('image_embeds')
          ? 'image_embeds'
          : session.outputNames.length == 1
          ? session.outputNames.single
          : null;
      if (inputName == null || outputName == null) {
        throw StateError(
          'Unable to select input/output names. inputs=${session.inputNames} '
          'outputs=${session.outputNames}',
        );
      }

      List<Map<String, dynamic>>? inputInfo;
      List<Map<String, dynamic>>? outputInfo;
      try {
        inputInfo = await session.getInputInfo();
      } catch (error) {
        if (kDebugMode) {
          debugPrint('MobileCLIP getInputInfo failed: $error');
        }
      }
      try {
        outputInfo = await session.getOutputInfo();
      } catch (error) {
        if (kDebugMode) {
          debugPrint('MobileCLIP getOutputInfo failed: $error');
        }
      }
      if (kDebugMode) {
        debugPrint(
          'MobileCLIP candidate=${candidate.model.name} '
          'inputNames=${session.inputNames} outputNames=${session.outputNames} '
          'inputInfo=$inputInfo outputInfo=$outputInfo',
        );
      }
      final candidateBatchSize =
          _fixedBatchSize(inputInfo) ??
          LocalSearchConfig.indexInferenceBatchSize;

      try {
        await _selfTestSession(session, inputName, outputName);
      } catch (error) {
        _recordLoadFailure(failures, candidate, source, 'self_test', error);
        return false;
      }
      if (_disposed) {
        throw StateError('MobileClipImageEncoder was disposed while loading.');
      }
      _session = session;
      _inputName = inputName;
      _outputName = outputName;
      _activeModel = candidate.model;
      _activeSource = source;
      _sessionBatchSize = candidateBatchSize;
      accepted = true;
      return true;
    } catch (error) {
      _recordLoadFailure(
        failures,
        candidate,
        source,
        'input_output_names',
        error,
      );
      return false;
    } finally {
      if (!accepted) {
        try {
          await session.close();
        } catch (_) {
          // The candidate is already unusable; preserve its original failure.
        }
      }
    }
  }

  Future<void> _selfTestSession(
    OrtSession session,
    String inputName,
    String outputName,
  ) async {
    final side = LocalSearchConfig.imageSide;
    final values = Float32List(3 * side * side);
    final input = await OrtValue.fromList(values, [1, 3, side, side]);
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run({inputName: input});
      final output = outputs[outputName];
      if (output == null) {
        throw StateError('Self-test output "$outputName" is missing.');
      }
      final flattened = await output.asFlattenedList();
      if (flattened.length != LocalSearchConfig.embeddingDimensions) {
        throw StateError(
          'Self-test returned ${flattened.length} values; expected 512.',
        );
      }
      var squaredNorm = 0.0;
      for (final raw in flattened) {
        if (raw is! num || !raw.toDouble().isFinite) {
          throw StateError('Self-test returned a non-finite value.');
        }
        final value = raw.toDouble();
        squaredNorm += value * value;
      }
      if (!squaredNorm.isFinite || squaredNorm <= 0) {
        throw StateError('Self-test returned a zero-norm embedding.');
      }
    } finally {
      await input.dispose();
      if (outputs != null) {
        for (final output in outputs.values) {
          await output.dispose();
        }
      }
    }
  }

  static int? _fixedBatchSize(List<Map<String, dynamic>>? inputInfo) {
    if (inputInfo == null || inputInfo.isEmpty) return null;
    final rawShape = inputInfo.first['shape'];
    if (rawShape is! List || rawShape.length != 4) return null;
    final shape = rawShape
        .map((value) => value is num ? value.toInt() : null)
        .toList(growable: false);
    return shape[0] == 1 &&
            shape[1] == 3 &&
            shape[2] == LocalSearchConfig.imageSide &&
            shape[3] == LocalSearchConfig.imageSide
        ? 1
        : null;
  }

  static void _recordLoadFailure(
    List<MobileClipLoadFailure> failures,
    _ModelCandidate candidate,
    MobileClipModelSource source,
    String stage,
    Object error,
  ) {
    final sanitized = error
        .toString()
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .trim();
    failures.add(
      MobileClipLoadFailure(
        model: candidate.model,
        source: source,
        stage: stage,
        errorType: error.runtimeType.toString(),
        message: sanitized.length <= 500
            ? sanitized
            : '${sanitized.substring(0, 500)}…',
      ),
    );
  }

  static Float32List _preprocess(Uint8List imageBytes) {
    final destination = Float32List(
      3 * LocalSearchConfig.imageSide * LocalSearchConfig.imageSide,
    );
    _preprocessInto(imageBytes, destination, 0);
    return destination;
  }

  static void _preprocessInto(
    Uint8List imageBytes,
    Float32List destination,
    int imageIndex,
  ) {
    final decoded = image.decodeImage(imageBytes);
    if (decoded == null) throw ArgumentError('Unable to decode image bytes.');
    final rgb = decoded.convert(format: image.Format.uint8, numChannels: 3);
    final scaled = _resizeShortestSide(rgb, LocalSearchConfig.imageSide);
    final cropped = image.copyCrop(
      scaled,
      x: (scaled.width - LocalSearchConfig.imageSide) ~/ 2,
      y: (scaled.height - LocalSearchConfig.imageSide) ~/ 2,
      width: LocalSearchConfig.imageSide,
      height: LocalSearchConfig.imageSide,
    );
    final side = LocalSearchConfig.imageSide;
    final baseOffset = imageIndex * 3 * side * side;
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        final pixel = cropped.getPixel(x, y);
        final offset = y * side + x;
        destination[baseOffset + offset] = pixel.r / 255.0;
        destination[baseOffset + side * side + offset] = pixel.g / 255.0;
        destination[baseOffset + 2 * side * side + offset] = pixel.b / 255.0;
      }
    }
  }

  static image.Image _resizeShortestSide(image.Image source, int target) {
    final scale = target / math.min(source.width, source.height);
    final width = (source.width * scale).round();
    final height = (source.height * scale).round();
    return image.copyResize(
      source,
      width: width,
      height: height,
      interpolation: image.Interpolation.linear,
    );
  }

  @visibleForTesting
  static Float32List preprocessForTesting(Uint8List imageBytes) =>
      _preprocess(imageBytes);
}
