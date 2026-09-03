import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fotosearch/local_search/local_vector.dart';
import 'package:fotosearch/local_search/mobileclip/mobileclip_image_encoder.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MobileCLIP loads an FP32 or FP16 engine', (tester) async {
    final encoder = MobileClipImageEncoder();
    addTearDown(encoder.dispose);

    await encoder.load();

    expect(encoder.isLoaded, isTrue);
    expect(encoder.activeModel, anyOf('fp32', 'fp16'));
  });

  testWidgets('MobileCLIP returns deterministic normalized 512d embeddings', (
    tester,
  ) async {
    final encoder = MobileClipImageEncoder();
    addTearDown(encoder.dispose);
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

    final first = await encoder.encode(image);
    final second = await encoder.encode(image);

    expect(first.length, 512);
    expect(LocalVector.l2Norm(first), closeTo(1.0, 1e-4));
    expect(first.every((value) => value.isFinite), isTrue);
    expect(
      LocalVector.cosineSimilarity(first, second),
      greaterThanOrEqualTo(.999),
    );
  });

  testWidgets('MobileCLIP encodes a batch of two images as two 512d vectors', (
    tester,
  ) async {
    final encoder = MobileClipImageEncoder();
    addTearDown(encoder.dispose);
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final embeddings = await encoder.encodeBatch([image, image]);
    expect(embeddings, hasLength(2));
    for (final embedding in embeddings) {
      expect(embedding, hasLength(512));
      expect(LocalVector.l2Norm(embedding), closeTo(1, 1e-4));
    }
  });
}
