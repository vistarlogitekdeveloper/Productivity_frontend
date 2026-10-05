/// Immutable SDK configuration passed to [VistarEventTracker.init].
class TrackerConfig {
  TrackerConfig({
    required this.appId,
    required this.writeKey,
    required this.baseUrl,
    this.appVersion,
    this.ingestPath = '/api/v1/eventtracker/events',
    this.flushInterval = const Duration(seconds: 15),
    this.maxBatchSize = 50,
    this.maxQueueSize = 1000,
    this.sessionTimeout = const Duration(minutes: 30),
    this.requestTimeout = const Duration(seconds: 20),
    this.baseBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(minutes: 5),
    this.autoCaptureLifecycle = true,
    this.autoCaptureErrors = true,
    this.captureAppOpen = true,
    this.requireConsent = false,
    this.debug = false,
  })  : assert(appId != ''),
        assert(writeKey != ''),
        assert(maxBatchSize > 0),
        assert(maxQueueSize >= maxBatchSize);

  /// Which app/website this is (multi-tenant key). Sent as the `x-app-id` header.
  final String appId;

  /// Per-app write key (sent as `x-write-key`). Treat as a public-ish client
  /// credential — it only permits appending events, never reading.
  final String writeKey;

  /// API origin, e.g. `https://api.vistar...`. No trailing slash required.
  final String baseUrl;

  /// Optional app version stamped into every event's context.
  final String? appVersion;

  final String ingestPath;
  final Duration flushInterval;
  final int maxBatchSize;
  final int maxQueueSize;
  final Duration sessionTimeout;
  final Duration requestTimeout;
  final Duration baseBackoff;
  final Duration maxBackoff;

  /// Auto-emit app_open / app_foreground / app_background from lifecycle.
  final bool autoCaptureLifecycle;

  /// Route FlutterError / uncaught async errors to a `client_error` event.
  final bool autoCaptureErrors;

  /// Emit a single app_open on init.
  final bool captureAppOpen;

  /// When true, nothing is captured until [VistarEventTracker.setConsent](true)
  /// is called (GDPR / India DPDP friendly).
  final bool requireConsent;

  final bool debug;

  /// Full ingest URL with any duplicate slash collapsed.
  String get ingestUrl {
    final b = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final p = ingestPath.startsWith('/') ? ingestPath : '/$ingestPath';
    return '$b$p';
  }
}
