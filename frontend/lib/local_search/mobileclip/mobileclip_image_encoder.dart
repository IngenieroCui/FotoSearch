import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as image;

import '../local_search_config.dart';
import '../local_vector.dart';

/// Local MobileCLIP-S0 visual encoder backed by the pinned Xenova ONNX model.
class MobileClipImageEncoder {
  Future<void>? _loadFuture;
  OrtSession? _session;
  String? _inputName;
  String? _outputName;
  Duration? _initialLoadDuration;
  bool _disposed = false;

  Duration? get initialLoadDuration => _initialLoadDuration;
  bool get isLoaded => _session != null;

  Future<void> load() {
    if (_disposed) {
      throw StateError('MobileClipImageEncoder has been disposed.');
    }
    return _loadFuture ??= _load();
  }

  Future<Float32List> encode(Uint8List imageBytes) async {
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

    final input = await OrtValue.fromList(_preprocess(imageBytes), [
      1,
      3,
      LocalSearchConfig.imageSide,
      LocalSearchConfig.imageSide,
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
      if (!_isEmbeddingShape(output.shape)) {
        throw StateError(
          'MobileCLIP output "$outputName" has invalid shape ${output.shape}; expected [1, 512].',
        );
      }
      final values = await output.asFlattenedList();
      if (values.length != LocalSearchConfig.embeddingDimensions) {
        throw StateError(
          'MobileCLIP output has ${values.length} values; expected '
          '${LocalSearchConfig.embeddingDimensions}.',
        );
      }
      final embedding = Float32List.fromList(
        values.map((value) => (value as num).toDouble()).toList(),
      );
      return LocalVector.normalized(embedding);
    } finally {
      await input.dispose();
      if (outputs != null) {
        for (final output in outputs.values) {
          await output.dispose();
        }
      }
    }
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

  Future<void> _load() async {
    final stopwatch = Stopwatch()..start();
    try {
      final session = await OnnxRuntime().createSessionFromAsset(
        LocalSearchConfig.visionModelAsset,
      );
      final inputInfo = await session.getInputInfo();
      final outputInfo = await session.getOutputInfo();
      final inputs = inputInfo.where(_isVisualInput).toList();
      final outputs = outputInfo.where(_isEmbeddingOutput).toList();
      if (inputs.length != 1 || outputs.length != 1) {
        await session.close();
        throw StateError(
          'Unexpected MobileCLIP I/O metadata. Inputs: $inputInfo; outputs: $outputInfo',
        );
      }
      final inputName = inputs.single['name'] as String?;
      final outputName = outputs.single['name'] as String?;
      if (inputName == null ||
          outputName == null ||
          !session.inputNames.contains(inputName) ||
          !session.outputNames.contains(outputName)) {
        await session.close();
        throw StateError(
          'MobileCLIP I/O names are absent from the ONNX session.',
        );
      }
      if (_disposed) {
        await session.close();
        throw StateError('MobileClipImageEncoder was disposed while loading.');
      }
      _session = session;
      _inputName = inputName;
      _outputName = outputName;
    } finally {
      stopwatch.stop();
      _initialLoadDuration ??= stopwatch.elapsed;
    }
  }

  static bool _isVisualInput(Map<String, dynamic> info) =>
      info['type'] == 'float32' && _isVisualInputShape(_shape(info));

  static bool _isEmbeddingOutput(Map<String, dynamic> info) =>
      info['type'] == 'float32' && _isEmbeddingShape(_shape(info));

  static List<int> _shape(Map<String, dynamic> info) =>
      (info['shape'] as List<dynamic>)
          .map((value) => (value as num).toInt())
          .toList();

  static bool _isVisualInputShape(List<int> shape) =>
      shape.length == 4 &&
      (shape[0] == 1 || shape[0] == -1) &&
      shape[1] == 3 &&
      shape[2] == LocalSearchConfig.imageSide &&
      shape[3] == LocalSearchConfig.imageSide;

  static bool _isEmbeddingShape(List<int> shape) =>
      shape.length == 2 &&
      (shape.first == 1 || shape.first == -1) &&
      shape.last == LocalSearchConfig.embeddingDimensions;

  static Float32List _preprocess(Uint8List imageBytes) {
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
    final tensor = Float32List(3 * side * side);
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        final pixel = cropped.getPixel(x, y);
        final offset = y * side + x;
        tensor[offset] = pixel.r / 255.0;
        tensor[side * side + offset] = pixel.g / 255.0;
        tensor[2 * side * side + offset] = pixel.b / 255.0;
      }
    }
    return tensor;
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
