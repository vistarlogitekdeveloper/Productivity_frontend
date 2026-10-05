/// Vistar EventTracker SDK for Flutter (mobile + web).
///
/// Batches, persists offline, and ships events to the Vistar EventTracker API
/// with auto-capture of screen views, app lifecycle, and errors.
///
/// ```dart
/// import 'package:vistar_event_tracker/vistar_event_tracker.dart';
///
/// await VistarEventTracker.instance.init(TrackerConfig(
///   appId: 'vistar_driver_app',
///   writeKey: 'wk_xxx',
///   baseUrl: 'https://api.vistar...',
///   appVersion: '1.4.0',
/// ));
///
/// // in MaterialApp:
/// //   navigatorObservers: [VistarNavigatorObserver()],
///
/// VistarEventTracker.instance.track(VistarEvents.orderPlaced, properties: {'amount': 250});
/// ```
library;

export 'src/api_client.dart' show ApiClient, SendResult;
export 'src/event.dart' show Event, EventType;
export 'src/event_catalog.dart' show VistarEvents;
export 'src/navigator_observer.dart' show VistarNavigatorObserver;
export 'src/storage.dart' show KeyValueStore, InMemoryStore, SharedPreferencesStore;
export 'src/tracker_config.dart' show TrackerConfig;
export 'src/vistar_event_tracker_base.dart' show VistarEventTracker;
