import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';

/// Retries a GET that failed because the network dropped, before anyone sees
/// the failure.
///
/// The shop floor works on plant Wi-Fi: in October 2026 the event tracker
/// logged ~80 dpl_app `api_error`s, all `connectionError`, most of them
/// trolley-photo loads (`/supervisor/trolley-photos/:id/image`) and manager
/// screens. A second try a moment later nearly always goes through.
///
/// What is retried: GET only (a read is safe to repeat; a POST may already
/// have saved the slip or trip), on a dropped connection, a connect timeout,
/// or a 502/503/504 from the proxy (a redeploy or a restarting container).
/// Never a 4xx or a 500, never a cancelled request, and never a RECEIVE
/// timeout: the server got the request and is just slow (60 s, dplDioProvider),
/// and asking again would keep the user waiting minutes and load the server
/// twice more.
///
/// The intermediate attempts carry [skipTelemetryKey] so the telemetry
/// interceptor ignores them; only the request's final outcome is reported.
/// Add this interceptor BEFORE the telemetry interceptor.
class RetryInterceptor extends Interceptor {
  RetryInterceptor(
    this._dio, {
    this.retries = 2,
    this.baseDelay = const Duration(seconds: 1),
    Future<void> Function(Duration)? sleep,
    Random? random,
  }) : _sleep = sleep ?? Future<void>.delayed,
       _random = random ?? Random();

  final Dio _dio;

  /// Extra attempts after the first (2 → at most 3 requests).
  final int retries;

  /// First wait; each later wait is 3x the one before (1s, 3s), plus up to
  /// 25% jitter so the devices at one plant do not all retry in step.
  final Duration baseDelay;

  final Future<void> Function(Duration) _sleep;
  final Random _random;

  /// `RequestOptions.extra` flag on the attempts this interceptor sends.
  static const skipTelemetryKey = 'telemetry_skip';
  static const _attemptKey = 'retry_attempt';

  static const _retryTypes = {
    DioExceptionType.connectionError,
    DioExceptionType.connectionTimeout,
  };
  static const _retryStatuses = {502, 503, 504};

  static bool isRetryable(DioException err) {
    if (err.requestOptions.method.toUpperCase() != 'GET') return false;
    if (_retryTypes.contains(err.type)) return true;
    return err.type == DioExceptionType.badResponse &&
        _retryStatuses.contains(err.response?.statusCode);
  }

  Duration delayFor(int attempt) {
    final ms = baseDelay.inMilliseconds * pow(3, attempt - 1);
    return Duration(
      milliseconds: (ms * (1 + _random.nextDouble() * 0.25)).round(),
    );
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    // An attempt this interceptor sent itself: hand it straight back to the
    // loop below, which decides whether to go again.
    if (err.requestOptions.extra[_attemptKey] != null || !isRetryable(err)) {
      return handler.next(err);
    }

    final cancelToken = err.requestOptions.cancelToken;
    var last = err;
    for (var attempt = 1; attempt <= retries; attempt++) {
      await _sleep(delayFor(attempt));
      if (cancelToken?.isCancelled ?? false) break;
      final options = last.requestOptions.copyWith(
        extra: {
          ...last.requestOptions.extra,
          _attemptKey: attempt,
          skipTelemetryKey: true,
        },
      );
      try {
        final response = await _dio.fetch<dynamic>(options);
        // The retried fetch already ran every interceptor's onResponse.
        return handler.resolve(response);
      } on DioException catch (e) {
        last = e;
        if (!isRetryable(e)) break;
      }
    }
    // Report the failure under the ORIGINAL request (no skip flag), once.
    handler.next(last.copyWith(requestOptions: err.requestOptions));
  }
}
