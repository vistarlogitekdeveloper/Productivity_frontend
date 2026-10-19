import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/core/retry_interceptor.dart';

/// Serves a scripted sequence: an int is that HTTP status, 'drop' is a dropped
/// connection, 'timeout' a connect timeout.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.script);
  final List<Object> script;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    final step = script[calls < script.length ? calls : script.length - 1];
    calls++;
    if (step == 'drop') {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'XMLHttpRequest onError',
      );
    }
    if (step == 'slow') {
      throw DioException.receiveTimeout(
        requestOptions: options,
        timeout: const Duration(seconds: 60),
      );
    }
    if (step == 'timeout') {
      throw DioException.connectionTimeout(
        requestOptions: options,
        timeout: const Duration(seconds: 15),
      );
    }
    return ResponseBody.fromString(
      '{"success":true}',
      step as int,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Stands in for the telemetry interceptor: what it would report.
class _Reporter extends Interceptor {
  final reported = <DioException>[];
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.requestOptions.extra[RetryInterceptor.skipTelemetryKey] != true) {
      reported.add(err);
    }
    handler.next(err);
  }
}

({Dio dio, _ScriptedAdapter adapter, _Reporter reporter, List<Duration> waits})
build(List<Object> script) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  final adapter = _ScriptedAdapter(script);
  dio.httpClientAdapter = adapter;
  final waits = <Duration>[];
  final reporter = _Reporter();
  dio.interceptors
    ..add(RetryInterceptor(dio, sleep: (d) async => waits.add(d)))
    ..add(reporter);
  return (dio: dio, adapter: adapter, reporter: reporter, waits: waits);
}

void main() {
  test('a GET that drops once succeeds on retry and reports nothing', () async {
    final t = build(['drop', 200]);
    final r = await t.dio.get<dynamic>('/supervisor/trolley-photos/1/image');
    expect(r.statusCode, 200);
    expect(t.adapter.calls, 2);
    expect(t.reporter.reported, isEmpty);
    expect(t.waits.single.inMilliseconds, inInclusiveRange(1000, 1250));
  });

  test(
    'a GET that keeps dropping is tried 3 times and reported once',
    () async {
      final t = build(['drop', 'timeout', 'drop']);
      await expectLater(
        t.dio.get<dynamic>('/manager/plans'),
        throwsA(isA<DioException>()),
      );
      expect(t.adapter.calls, 3);
      expect(t.reporter.reported, hasLength(1));
      expect(t.reporter.reported.single.type, DioExceptionType.connectionError);
      expect(t.waits.map((d) => d.inMilliseconds ~/ 1000), [1, 3]);
    },
  );

  test('a proxy 503 on a GET is retried', () async {
    final t = build([503, 200]);
    expect((await t.dio.get<dynamic>('/manager/dashboard')).statusCode, 200);
    expect(t.reporter.reported, isEmpty);
  });

  test(
    'a POST is never retried (it may already have saved the slip)',
    () async {
      final t = build(['drop', 200]);
      await expectLater(
        t.dio.post<dynamic>('/supervisor/trolley-photos/1/image', data: {}),
        throwsA(isA<DioException>()),
      );
      expect(t.adapter.calls, 1);
      expect(t.reporter.reported, hasLength(1));
    },
  );

  test('a 4xx or a 500 on a GET is not retried', () async {
    for (final status in [404, 500]) {
      final t = build([status, 200]);
      await expectLater(
        t.dio.get<dynamic>('/manager/plans/x'),
        throwsA(isA<DioException>()),
      );
      expect(t.adapter.calls, 1, reason: '$status');
    }
  });

  test(
    'a receive timeout (server reached, just slow) is not retried',
    () async {
      final t = build(['slow', 200]);
      await expectLater(
        t.dio.get<dynamic>('/manager/production-summary'),
        throwsA(isA<DioException>()),
      );
      expect(t.adapter.calls, 1);
      expect(t.reporter.reported, hasLength(1));
    },
  );

  test('a request cancelled during the wait is not sent again', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
    final adapter = _ScriptedAdapter(['drop', 200]);
    dio.httpClientAdapter = adapter;
    final token = CancelToken();
    dio.interceptors.add(
      RetryInterceptor(dio, sleep: (_) async => token.cancel()),
    );
    await expectLater(
      dio.get<dynamic>('/supervisor/trolley-photos/1/image', cancelToken: token),
      throwsA(isA<DioException>()),
    );
    expect(adapter.calls, 1);
  });
}
