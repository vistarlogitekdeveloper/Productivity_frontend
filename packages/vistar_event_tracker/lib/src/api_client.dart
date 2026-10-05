import 'dart:convert';

import 'package:http/http.dart' as http;

import 'tracker_config.dart';

/// Outcome of trying to ship one batch.
enum SendResult {
  /// 2xx — remove the batch from the queue.
  success,

  /// Transient (network error, timeout, 429, 5xx) — keep the batch, back off.
  retry,

  /// Permanent client error (400/401/403/413) — drop the batch; retrying can't
  /// help and would block the queue forever.
  dropped,
}

abstract class ApiClient {
  Future<SendResult> send(List<Map<String, dynamic>> events);
}

/// Default HTTP client. Uses package:http so it works on mobile AND Flutter web.
class HttpApiClient implements ApiClient {
  HttpApiClient(this.config, {http.Client? client}) : _client = client ?? http.Client();

  final TrackerConfig config;
  final http.Client _client;

  @override
  Future<SendResult> send(List<Map<String, dynamic>> events) async {
    final uri = Uri.parse(config.ingestUrl);
    try {
      final res = await _client
          .post(
            uri,
            headers: {
              'content-type': 'application/json',
              'x-app-id': config.appId,
              'x-write-key': config.writeKey,
            },
            body: jsonEncode(events),
          )
          .timeout(config.requestTimeout);

      final code = res.statusCode;
      if (code >= 200 && code < 300) return SendResult.success;
      // 429 (rate limited) and 5xx are worth retrying; other 4xx are not.
      if (code == 429 || code >= 500) return SendResult.retry;
      if (code >= 400) return SendResult.dropped;
      return SendResult.retry;
    } catch (_) {
      // Network down, DNS failure, timeout — keep the batch for a later flush.
      return SendResult.retry;
    }
  }

  void close() => _client.close();
}
