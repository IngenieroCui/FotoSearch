import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/mobileclip_query_plan.dart';

class MobileClipQueryClient {
  MobileClipQueryClient({required this.baseUrl, required this.timeout});

  final String baseUrl;
  final Duration timeout;

  Future<MobileClipQueryPlan> createPlan(
    String query, {
    List<String> conceptNames = const [],
  }) async {
    final response = await http
        .post(
          Uri.parse(
            '${baseUrl.replaceFirst(RegExp(r'/$'), '')}/mobileclip/query-plan',
          ),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'query': query, 'concept_names': conceptNames}),
        )
        .timeout(timeout);
    final body = utf8.decode(response.bodyBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = body.length > 1000 ? '${body.substring(0, 1000)}…' : body;
      throw StateError(
        'MobileCLIP query plan failed (${response.statusCode}): $detail',
      );
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const FormatException('response must be an object');
      }
      return MobileClipQueryPlan.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } on FormatException catch (error) {
      throw FormatException('Invalid MobileCLIP query plan: ${error.message}');
    }
  }
}
