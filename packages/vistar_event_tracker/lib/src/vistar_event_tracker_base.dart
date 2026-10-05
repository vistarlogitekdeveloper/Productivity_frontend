import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

import 'api_client.dart';
import 'device_context.dart';
import 'event.dart';
import 'event_catalog.dart';
import 'event_queue.dart';
import 'identity_manager.dart';
import 'logger.dart';
import 'session_manager.dart';
import 'storage.dart';
import 'tracker_config.dart';
import 'uuid.dart';

/// The Vistar analytics client. Use the shared [instance]:
///
/// ```dart
/// await VistarEventTracker.instance.init(TrackerConfig(
///   appId: 'vistar_driver_app',
///   writeKey: 'wk_...',
///   baseUrl: 'https://api.vistar...',
/// ));
/// VistarEventTracker.instance.track(VistarEvents.orderPlaced, properties: {'amount': 250});
/// ```
class VistarEventTracker with WidgetsBindingObserver {
  VistarEventTracker._();

  /// Process-wide singleton.
  static final VistarEventTracker instance = VistarEventTracker._();

  late IdentityManager _identity;
  late SessionManager _session;
  late DeviceContext _device;
  late EventQueue _queue;
  late TrackerLogger _log;

  bool _initialized = false;
  bool _consent = true;
  bool _lifecycleBound = false;
  void Function(FlutterErrorDetails)? _prevFlutterOnError;

  bool get isInitialized => _initialized;

  /// Initialise the SDK. Safe to await early in `main()`. Idempotent — a second
  /// call is ignored. [store] / [apiClient] are injectable for tests.
  Future<void> init(
    TrackerConfig config, {
    KeyValueStore? store,
    ApiClient? apiClient,
  }) async {
    if (_initialized) return;
    _log = TrackerLogger(config.debug);
    _consent = !config.requireConsent; // withheld until granted when required

    final kv = store ?? SharedPreferencesStore();
    _identity = IdentityManager(kv);
    await _identity.load();
    _session = SessionManager(config.sessionTimeout);
    _device = DeviceContext.build(config);
    _queue = EventQueue(
      config: config,
      store: kv,
      api: apiClient ?? HttpApiClient(config),
      logger: _log,
    );
    await _queue.restore();
    _initialized = true;

    if (config.autoCaptureLifecycle) _bindLifecycle();
    if (config.autoCaptureErrors) _bindErrorHandlers();
    _queue.start();

    if (config.captureAppOpen) _capture(VistarEvents.appOpen, EventType.system);
    _log.log('initialised for app "${config.appId}" -> ${config.ingestUrl}');
  }

  // ---- Public API -------------------------------------------------------

  /// Track a custom event. Prefer [VistarEvents] constants for the name.
  void track(String eventName, {Map<String, dynamic>? properties, EventType type = EventType.action}) {
    _capture(eventName, type, properties);
  }

  /// Track a screen/page view. Stored under `properties.screen` (what the
  /// backend's top-screens metric reads).
  void screen(String screenName, {Map<String, dynamic>? properties}) {
    _capture(VistarEvents.screenViewed, EventType.screenView, {
      'screen': screenName,
      ...?properties,
    });
  }

  /// Associate the current anonymous user with a known [userId] (+ optional
  /// traits). Emits `user_identified`.
  Future<void> identify(String userId, {Map<String, dynamic>? traits}) async {
    await _identity.identify(userId, traits);
    _capture(VistarEvents.userIdentified, EventType.system, {
      if (traits != null) 'traits': traits,
    });
  }

  /// Clear identity on logout: forgets user_id, resets traits, mints a fresh
  /// anonymous_id, and starts a new session.
  Future<void> reset() async {
    _capture(VistarEvents.userLoggedOut, EventType.system);
    await flush();
    await _identity.reset();
    _session.rotate();
  }

  /// Grant/withhold consent at runtime. With [TrackerConfig.requireConsent],
  /// nothing is captured until this is called with `true`.
  void setConsent(bool granted) {
    _consent = granted;
    _log.log('consent = $granted');
  }

  /// Force-send everything queued right now (returns when the attempt finishes).
  Future<void> flush() => _initialized ? _queue.flush() : Future.value();

  /// Detach hooks and stop the flush timer. Rarely needed in app code; useful
  /// in tests.
  Future<void> dispose() async {
    if (!_initialized) return;
    _queue.stop();
    if (_lifecycleBound) {
      WidgetsBinding.instance.removeObserver(this);
      _lifecycleBound = false;
    }
    if (_prevFlutterOnError != null) {
      FlutterError.onError = _prevFlutterOnError;
      _prevFlutterOnError = null;
    }
    await flush();
    _initialized = false;
  }

  // ---- Internals --------------------------------------------------------

  void _capture(String name, EventType type, [Map<String, dynamic>? properties]) {
    if (!_initialized || !_consent) return;
    final now = DateTime.now().toUtc();
    final s = _session.touch(now);
    // Emit a session_start at the front of a new session (but never recurse).
    if (s.isNew && name != VistarEvents.sessionStart) {
      _enqueue(VistarEvents.sessionStart, EventType.system, const {}, now, s.id);
    }
    _enqueue(name, type, properties ?? const {}, now, s.id);
  }

  void _enqueue(String name, EventType type, Map<String, dynamic> props, DateTime now, String sessionId) {
    _queue.enqueue(Event(
      eventId: uuidV4(),
      eventName: name,
      eventType: type,
      anonymousId: _identity.anonymousId,
      userId: _identity.userId,
      sessionId: sessionId,
      tsClient: now.toIso8601String(),
      properties: props,
      context: _device.snapshot(),
    ));
  }

  void _bindLifecycle() {
    if (_lifecycleBound) return;
    WidgetsBinding.instance.addObserver(this);
    _lifecycleBound = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_initialized) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _capture(VistarEvents.appForeground, EventType.system);
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _capture(VistarEvents.appBackground, EventType.system);
        unawaited(flush()); // best-effort flush before the OS may suspend us
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  void _bindErrorHandlers() {
    _prevFlutterOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _captureError(details.exceptionAsString(), details.stack?.toString(), fatal: false);
      _prevFlutterOnError?.call(details); // preserve default red-screen logging
    };
    // Uncaught async errors from the platform.
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      _captureError(error.toString(), stack.toString(), fatal: true);
      return false; // let the platform continue its default handling
    };
  }

  void _captureError(String message, String? stack, {required bool fatal}) {
    _capture(VistarEvents.clientError, EventType.error, {
      'message': message.length > 2000 ? message.substring(0, 2000) : message,
      if (stack != null) 'stack': stack.length > 4000 ? stack.substring(0, 4000) : stack,
      'fatal': fatal,
    });
  }
}
