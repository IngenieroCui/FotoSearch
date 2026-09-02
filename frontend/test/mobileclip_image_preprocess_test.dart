import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fotosearch/local_search/local_search_config.dart';
import 'package:fotosearch/local_search/mobileclip/mobileclip_image_encoder.dart';

void main() {
  test('MobileCLIP preprocessing returns a finite 256px RGB NCHW tensor', () {
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

    final tensor = MobileClipImageEncoder.preprocessForTesting(bytes);

    expect(
      tensor.length,
      3 * LocalSearchConfig.imageSide * LocalSearchConfig.imageSide,
    );
    expect(tensor.every((value) => value.isFinite), isTrue);
    expect(tensor.every((value) => value >= 0 && value <= 1), isTrue);
  });
}
