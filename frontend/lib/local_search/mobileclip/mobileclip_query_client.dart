import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../app_config.dart';
import '../models/mobileclip_query_plan.dart';

enum BackendHealthStatus { connected, offline, unavailable, invalidResponse }

class BackendHealthResult {
  const BackendHealthResult({required this.status, this.message});

  final BackendHealthStatus status;
  final String? message;
}

class MobileClipQueryClient {
  const MobileClipQueryClient();

  static const _offlineMessage =
      'No se pudo conectar. Comprueba tu conexión a Internet e inténtalo de nuevo.';
  static const _unavailableMessage =
      'El servicio de búsqueda no está disponible temporalmente. Inténtalo de nuevo en unos minutos.';
  static const _invalidResponseMessage =
      'FotoSearch recibió una respuesta inesperada del servicio. Inténtalo de nuevo.';

  Duration get _timeout =>
      const Duration(seconds: AppConfig.requestTimeoutSeconds);

  Uri _uri(String path) {
    final baseUrl = AppConfig.apiBaseUrl.trim().replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    if (baseUrl.isEmpty) {
      throw StateError('FotoSearch could not find the search service.');
    }
    return Uri.parse('$baseUrl/$path');
  }

  Future<BackendHealthResult> health() async {
    try {
      final response = await http
          .get(_uri('health'))
          .timeout(const Duration(seconds: AppConfig.healthTimeoutSeconds));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const BackendHealthResult(
          status: BackendHealthStatus.unavailable,
          message: _unavailableMessage,
        );
      }
      return parseHealthResponse(response);
    } on FormatException catch (error) {
      if (kDebugMode) debugPrint(error.toString());
      return const BackendHealthResult(
        status: BackendHealthStatus.invalidResponse,
        message: _invalidResponseMessage,
      );
    } on TimeoutException catch (error) {
      if (kDebugMode) debugPrint(error.toString());
      return const BackendHealthResult(
        status: BackendHealthStatus.offline,
        message: _offlineMessage,
      );
    } on SocketException catch (error) {
      if (kDebugMode) debugPrint(error.toString());
      return const BackendHealthResult(
        status: BackendHealthStatus.offline,
        message: _offlineMessage,
      );
    } on http.ClientException catch (error) {
      if (kDebugMode) debugPrint(error.toString());
      return const BackendHealthResult(
        status: BackendHealthStatus.offline,
        message: _offlineMessage,
      );
    } catch (error) {
      if (kDebugMode) debugPrint(error.toString());
      return const BackendHealthResult(
        status: BackendHealthStatus.offline,
        message: _offlineMessage,
      );
    }
  }

  @visibleForTesting
  BackendHealthResult parseHealthResponse(http.Response response) {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) {
      throw const FormatException('health response must be an object');
    }
    final body = decoded.map((key, value) => MapEntry(key.toString(), value));
    final status = body['status'];
    final modelAvailable = body['mobileclip_text_available'];
    if (status == 'ok' && modelAvailable == true) {
      return const BackendHealthResult(status: BackendHealthStatus.connected);
    }
    if (status == 'degraded' || modelAvailable != true) {
      return const BackendHealthResult(
        status: BackendHealthStatus.unavailable,
        message: _unavailableMessage,
      );
    }
    throw const FormatException('unexpected health response');
  }

  Future<MobileClipQueryPlan> createPlan(
    String query, {
    List<String> conceptNames = const [],
  }) async {
    final response = await http
        .post(
          _uri('mobileclip/query-plan'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'query': query, 'concept_names': conceptNames}),
        )
        .timeout(_timeout);
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
