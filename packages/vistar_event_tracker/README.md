# vistar_event_tracker

Official Vistar in-house analytics SDK for **Flutter (mobile + web)**. It batches
events, persists them offline, and ships them to the Vistar EventTracker API,
with auto-capture of screen views, app lifecycle, and errors.

Pairs with the backend module at `vistar_CRM/src/modules/eventtracker`
(`POST /api/v1/eventtracker/events`).

## Features

- `init / track / screen / identify / reset / flush` — a familiar analytics API.
- **Offline-first**: a durable queue (shared_preferences) survives restarts;
  batching + exponential-backoff retry handle flaky mobile networks.
- **Idempotent**: every event carries a client UUID, so retries are
  de-duplicated server-side — no double counting.
- **Auto-capture**: `screen_viewed` via a `NavigatorObserver`, `app_open` /
  `app_foreground` / `app_background` via lifecycle, and `client_error` via
  Flutter/async error hooks.
- **Sessions**: a `session_id` that rotates after ~30 min of inactivity, with a
  `session_start` emitted automatically.
- **Privacy**: an optional consent gate (`requireConsent`) and a `reset()` that
  mints a fresh anonymous id on logout.
- **Cross-platform**: uses `package:http` (no `dart:io`), so it runs on Flutter
  web as well as mobile/desktop.

## Install

While it lives outside pub.dev, depend on it by path or git:

```yaml
dependencies:
  vistar_event_tracker:
    path: ../vistar_event_tracker
    # or:
    # git:
    #   url: https://github.com/vistarlogitekdeveloper/vistar_event_tracker.git
```

## Quick start

```dart
import 'package:vistar_event_tracker/vistar_event_tracker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await VistarEventTracker.instance.init(TrackerConfig(
    appId: 'vistar_driver_app',      // sent as x-app-id
    writeKey: 'wk_xxx',              // from: npm run et:create-app -- vistar_driver_app "Driver App"
    baseUrl: 'https://api.vistar...', // your EventTracker API origin
    appVersion: '1.4.0',
  ));

  runApp(const MyApp());
}

// Auto screen views:
MaterialApp(
  navigatorObservers: [VistarNavigatorObserver()],
  // ...
);

// Anywhere:
final t = VistarEventTracker.instance;
t.track(VistarEvents.orderPlaced, properties: {'amount': 250});
await t.identify('u_8842', traits: {'plan': 'pro'});
t.screen('CheckoutScreen');
await t.reset(); // on logout
```

## API

| Method | Purpose |
|---|---|
| `init(TrackerConfig)` | One-time setup. Idempotent. |
| `track(name, {properties, type})` | Custom event. Use `VistarEvents.*` constants for `name`. |
| `screen(name, {properties})` | Screen/page view (stored under `properties.screen`). |
| `identify(userId, {traits})` | Link the anonymous user to a known id. |
| `reset()` | Logout: clears user, new anonymous id, new session. |
| `flush()` | Send everything queued now. |
| `setConsent(bool)` | Grant/withhold capture when `requireConsent` is on. |

## Configuration (`TrackerConfig`)

| Field | Default | Notes |
|---|---|---|
| `appId`, `writeKey`, `baseUrl` | — | required |
| `appVersion` | null | stamped into `context` |
| `flushInterval` | 15s | periodic flush |
| `maxBatchSize` | 50 | events per POST |
| `maxQueueSize` | 1000 | oldest dropped when exceeded |
| `sessionTimeout` | 30m | inactivity before a new session |
| `autoCaptureLifecycle` | true | app_open/foreground/background |
| `autoCaptureErrors` | true | client_error from error hooks |
| `requireConsent` | false | gate capture until `setConsent(true)` |
| `debug` | false | verbose logging |

## Event contract

Events serialise to exactly the backend's ingest envelope (`app_id` is supplied
by the write-key header, never in the body):

```json
{
  "event_id": "uuid-v4",
  "event_name": "order_placed",
  "event_type": "action",
  "anonymous_id": "uuid",
  "user_id": "u_8842",
  "session_id": "uuid",
  "ts_client": "2026-08-04T10:11:12.000Z",
  "properties": { "amount": 250 },
  "context": { "sdk": "vistar_event_tracker", "platform": "android", "app_version": "1.4.0" }
}
```

Event names live in `VistarEvents` and mirror the backend `catalog.js`; keep the
two in sync so strict-catalog mode never rejects a batch.

## Testing

```bash
flutter test
```

The queue, sessions, identity, and serialization are covered with injectable
fakes (no network, no platform plugins).
