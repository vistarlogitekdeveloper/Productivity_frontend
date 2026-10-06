import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:vistar_event_tracker/vistar_event_tracker.dart';

import '../constants/app_constants.dart';

/// Usage analytics for Vistar Pulse (the DPL app), sent to the in-house event
/// tracker and read in the Platform Console under Analytics > Event tracker.
///
/// Off unless the build is given both:
///   --dart-define=ET_APP_ID=dpl_app --dart-define=ET_WRITE_KEY=wk_...
/// (and, optionally, --dart-define=ET_BASE_URL=https://uat-api... to send a
/// test build's events somewhere other than the API host the app uses)
/// (register the app in the Platform Console, Settings > Event tracker; the
/// write key only lets a client append events, so it may ship in the app).
///
/// What is sent:
///   * screen views, by route pattern (ids replaced: `/dpl/trips/:id`)
///   * sign-in / sign-out; the user as `dpl:<user id>`, with their role and
///     organisation code as traits
///   * named business actions, from successful API writes (see [_actions]):
///     `plan_created`, `label_printed`, `dispatch_slip_created`, ...
///   * failed API calls (5xx or no connection) and client errors (by type
///     only: never the message or stack, which can quote record content)
/// Never sent: request or response bodies, names, emails, part numbers,
/// quantities or any other record content.
///
/// NEVER IN THE WAY OF WORK. Nothing here is awaited by a screen, a sign-in or
/// a sign-out; start-up waits at most [_initBudget]; every call swallows its
/// own failures; the offline queue is capped at [_maxQueue] events (oldest
/// dropped), so it cannot crowd the sync outbox out of browser storage; and
/// sending happens in the background with the SDK's own backoff.
abstract final class Telemetry {
  static const _initBudget = Duration(seconds: 2);
  static const _maxQueue = 200;

  static const _appId = String.fromEnvironment('ET_APP_ID');
  static const _writeKey = String.fromEnvironment('ET_WRITE_KEY');
  static const _appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '');

  /// Where events go. Defaults to the API host the app talks to; set
  /// ET_BASE_URL to send a UAT or local build's events elsewhere.
  static const _baseUrlOverride = String.fromEnvironment('ET_BASE_URL');

  static bool get enabled => _appId != '' && _writeKey != '';

  static VistarEventTracker get _t => VistarEventTracker.instance;
  static bool get _on => enabled && _t.isInitialized;

  static String? _lastScreen;

  /// `https://api.vistarlogitek.com/api/v1/dpl` -> `https://api.vistarlogitek.com`.
  static String get _origin {
    if (_baseUrlOverride.isNotEmpty) return _baseUrlOverride;
    final u = Uri.parse(AppConstants.dplApiBaseUrl);
    return '${u.scheme}://${u.authority}';
  }

  static Future<void> init() async {
    if (!enabled) return;
    try {
      await _t
          .init(TrackerConfig(
            appId: _appId,
            writeKey: _writeKey,
            baseUrl: _origin,
            appVersion: _appVersion.isEmpty ? null : _appVersion,
            maxQueueSize: _maxQueue,
            // The SDK's own error capture sends the exception message and
            // stack, and a message can quote a server reply (a part number, a
            // slip number). [_captureErrors] sends the type only.
            autoCaptureErrors: false,
          ))
          .timeout(_initBudget);
      _captureErrors();
    } catch (_) {
      // Analytics must never stop the app from starting.
    }
  }

  /// Client errors, by type only. Chains to whatever handled them before, so
  /// the app's own error handling is unchanged.
  static void _captureErrors() {
    if (!_on) return;
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      _clientError(details.exception, fatal: false, library: details.library);
      previous?.call(details);
    };
    final dispatcher = PlatformDispatcher.instance;
    final previousAsync = dispatcher.onError;
    dispatcher.onError = (error, stack) {
      _clientError(error, fatal: true);
      return previousAsync?.call(error, stack) ?? false;
    };
  }

  static void _clientError(Object e, {required bool fatal, String? library}) {
    if (!_on) return;
    try {
      _t.track(
        VistarEvents.clientError,
        properties: {
          'error': e.runtimeType.toString(),
          'library': ?library,
          'fatal': fatal,
        },
        type: EventType.error,
      );
    } catch (_) {}
  }

  /// A screen, by its route pattern. Repeats of the same screen are dropped
  /// (the router reports a location change for query-string updates too).
  static void screen(String location) {
    if (!_on) return;
    final name = routePattern(location);
    if (name == _lastScreen) return;
    _lastScreen = name;
    _guard(() => _t.screen(name));
  }

  static void track(String name, [Map<String, dynamic>? properties]) {
    if (_on) _guard(() => _t.track(name, properties: properties));
  }

  /// A failure worth counting (shows under Errors in the dashboard).
  static void error(String name, Map<String, dynamic> properties) {
    if (_on) _guard(() => _t.track(name, properties: properties, type: EventType.error));
  }

  static void _guard(void Function() fn) {
    try {
      fn();
    } catch (_) {
      // Analytics never surfaces as an app error.
    }
  }

  /// The sign-out in flight: its reset sends what is queued first, which can
  /// take a while on a poor connection, so nobody waits for it.
  static Future<void>? _resetting;

  /// Fire and forget: the sign-in never waits for analytics.
  static void signedIn({required String userId, required String role, String? orgCode}) {
    if (!_on || userId.isEmpty) return;
    unawaited(() async {
      try {
        // A sign-out just before (a user change on a shared device) resets
        // the identity; let it finish so this one is not wiped by it.
        await _resetting?.timeout(const Duration(seconds: 5), onTimeout: () {});
        await _t.identify('dpl:$userId', traits: {'role': role, 'org': ?orgCode});
      } catch (_) {}
    }());
  }

  /// Fire and forget: the sign-out never waits for analytics.
  static void signedOut() {
    _lastScreen = null;
    if (!_on) return;
    _resetting = _t.reset().catchError((Object _) {});
  }

  /// `/dpl/trips/123/journey?tab=map` -> `/dpl/trips/:id/journey`.
  static String routePattern(String location) {
    final path = Uri.tryParse(location)?.path ?? location;
    final segments = path.split('/').map((s) {
      if (s.isEmpty) return s;
      if (RegExp(r'^\d+$').hasMatch(s)) return ':id';
      if (RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-', caseSensitive: false).hasMatch(s)) return ':id';
      // Serials, slip and trip numbers: anything with a digit and 6+ characters.
      if (s.length >= 6 && RegExp(r'\d').hasMatch(s) && RegExp(r'[A-Za-z-]').hasMatch(s)) return ':ref';
      return s;
    });
    return segments.join('/');
  }

  /// Successful API writes worth naming, by method and path (ids stripped).
  /// First match wins; anything else is not reported.
  static final List<(String, RegExp, String)> _actions = [
    ('POST', RegExp(r'^/manager/plans/upload-excel$'), 'plan_uploaded'),
    ('POST', RegExp(r'^/manager/plans$'), 'plan_created'),
    ('POST', RegExp(r'^/supervisor/plans/:id/items/:id/start$'), 'item_started'),
    ('POST', RegExp(r'^/supervisor/plans/:id/items/:id/stop$'), 'item_completed'),
    ('POST', RegExp(r'^/supervisor/plans/:id/items/:id/pause$'), 'item_paused'),
    ('POST', RegExp(r'^/supervisor/plans/:id/downtime/start$'), 'downtime_started'),
    ('POST', RegExp(r'^/supervisor/shift/submit$'), 'shift_submitted'),
    ('POST', RegExp(r'^/supervisor/identity/verify$'), 'identity_verified'),
    ('POST', RegExp(r'^/qa/stickers(/direct)?$'), 'label_printed'),
    ('POST', RegExp(r'^/qa/pallets/open$'), 'pallet_opened'),
    ('POST', RegExp(r'^/qa/pallets/:id/close$'), 'pallet_closed'),
    ('POST', RegExp(r'^/dispatch/trips$'), 'trip_created'),
    ('POST', RegExp(r'^/dispatch/trips/:id/label-scans$'), 'trip_label_scanned'),
    ('POST', RegExp(r'^/dispatch/trips/:id/send-for-pdi$'), 'trip_sent_for_pdi'),
    ('POST', RegExp(r'^/dispatch/trips/:id/gate-out$'), 'trip_gate_out'),
    ('POST', RegExp(r'^/dispatch/slips(/bulk)?$'), 'dispatch_slip_created'),
    ('POST', RegExp(r'^/dispatch/slips/:id/qa-approve$'), 'slip_qa_approved'),
    ('POST', RegExp(r'^/dispatch/slips/:id/pdi-approve$'), 'slip_pdi_approved'),
    ('POST', RegExp(r'^/dispatch/slips/:id/mark-dispatched$'), 'slip_dispatched'),
    ('POST', RegExp(r'^/returns$'), 'return_recorded'),
    ('POST', RegExp(r'^/stock/adjustments$'), 'stock_adjusted'),
    ('POST', RegExp(r'^/stock/counts$'), 'stock_count_started'),
    ('POST', RegExp(r'^/sync/push$'), 'offline_actions_synced'),
  ];

  /// The business event for a successful API call, or null.
  static String? actionFor(String method, String path) {
    final pattern = routePattern(path);
    for (final (m, re, name) in _actions) {
      if (m == method.toUpperCase() && re.hasMatch(pattern)) return name;
    }
    return null;
  }
}

/// Reports named actions and failed calls from the app's one HTTP client.
/// Adds no headers and changes nothing about the request.
class TelemetryInterceptor extends Interceptor {
  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    if (Telemetry.enabled) {
      final o = response.requestOptions;
      String? name;
      try {
        name = Telemetry.actionFor(o.method, o.path);
      } catch (_) {}
      if (name != null) Telemetry.track(name);
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (Telemetry.enabled) {
      final status = err.response?.statusCode;
      // 4xx is the server refusing something on purpose (validation, a
      // permission): not an error of the app. 5xx and no answer at all are.
      if (status == null || status >= 500) {
        Telemetry.error('api_error', {
          'endpoint': Telemetry.routePattern(err.requestOptions.path),
          'method': err.requestOptions.method,
          'status': ?status,
          'kind': err.type.name,
        });
      }
    }
    handler.next(err);
  }
}
