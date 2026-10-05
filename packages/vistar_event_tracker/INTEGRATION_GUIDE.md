# Vistar EventTracker — Developer Integration Guide

**Audience:** app developers integrating analytics into a Vistar Flutter app (or website).
**Goal:** every app sends events to the shared EventTracker API so they appear in the analytics viewer.

---

## 1. How it fits together

```
  Your Flutter app  ──(batched HTTPS)──►  EventTracker API  ──►  Postgres (analytics)  ──►  Viewer
   vistar_event_tracker SDK                /api/v1/eventtracker         dashboards + live feed
```

- You add the **`vistar_event_tracker`** package and call a few methods.
- The SDK batches events, stores them offline, retries on flaky networks, and ships them to the API.
- You never talk to the database — only the SDK, using your app's **write key**.

---

## 2. Before you start — get two things from the backend team

1. **API base URL** — e.g. `https://api.vistar…` (the deployed EventTracker API).
2. **A per-app write key** — each app has its own. The backend team runs:
   ```bash
   npm run et:create-app -- <app_id> "Human Name"
   # e.g. npm run et:create-app -- vistar_driver_app "Vistar Driver App"
   ```
   This prints a `wk_…` key **once**. Treat it like a public client key: it can only
   *append* events, never read them. Use a **different app_id + key per app**.

> `app_id` convention: lowercase snake_case, e.g. `vistar_driver_app`, `vistar_ops_app`.

---

## 3. Add the SDK

In your app's `pubspec.yaml`:

```yaml
dependencies:
  vistar_event_tracker:
    git:
      url: https://github.com/vistarlogitekdeveloper/vistar_event_tracker.git
    # or during local dev:
    # path: ../vistar_event_tracker
```

Then `flutter pub get`.

---

## 4. Initialise once (in `main.dart`)

```dart
import 'package:vistar_event_tracker/vistar_event_tracker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await VistarEventTracker.instance.init(TrackerConfig(
    appId: 'vistar_driver_app',        // this app's id
    writeKey: 'wk_xxx',                // this app's write key
    baseUrl: 'https://api.vistar…',    // the EventTracker API origin
    appVersion: '1.4.0',               // optional, stamped on every event
    // debug: true,                    // verbose logs while integrating
  ));

  runApp(const MyApp());
}
```

**Don't hard-code the write key in source you publish publicly.** Inject it at build time
(`--dart-define`) or from your existing config mechanism:

```dart
writeKey: const String.fromEnvironment('VET_WRITE_KEY'),
baseUrl: const String.fromEnvironment('VET_BASE_URL'),
```
```bash
flutter run --dart-define=VET_WRITE_KEY=wk_xxx --dart-define=VET_BASE_URL=https://api.vistar…
```

---

## 5. Turn on auto-capture (recommended)

Add the navigator observer so **every screen view** is captured automatically:

```dart
MaterialApp(
  navigatorObservers: [VistarNavigatorObserver()],
  // ...
);
```

Automatically captured with **no extra code**:
- `screen_viewed` — on every named-route push/replace (uses `RouteSettings.name`).
- `app_open`, `app_foreground`, `app_background` — from app lifecycle.
- `session_start` — when a new session begins (rotates after ~30 min inactivity).
- `client_error` — Flutter framework errors + uncaught async errors.

> Give routes a `name` (named routes, or `RouteSettings(name: …)`) so screen views are labelled.

---

## 6. Track your own events

```dart
final t = VistarEventTracker.instance;

// A custom action. Prefer the VistarEvents constants over raw strings.
t.track(VistarEvents.orderPlaced, properties: {'amount': 250, 'currency': 'INR'});

// A screen/page view (if you aren't relying on the navigator observer)
t.screen('CheckoutScreen');

// Associate the anonymous user with a known user once they log in
await t.identify('u_8842', traits: {'plan': 'pro', 'role': 'driver'});

// On logout — clears the user and starts a fresh anonymous identity
await t.reset();

// Force-send immediately (rarely needed; batching handles this)
await t.flush();
```

### Event naming rules (important for clean analytics)
- **`object_action`, snake_case**: `order_placed`, `cart_item_added`, `payment_failed`.
- Use the **`VistarEvents`** constants where one exists (`VistarEvents.orderPlaced`, …).
- Put variable data in **`properties`**, not in the event name.
  - ✅ `track('product_viewed', properties: {'sku': 'ABC'})`
  - ❌ `track('product_viewed_ABC')`
- Keep the name list small and shared. New events should be agreed with the team and
  added to **both** the Dart catalog (`VistarEvents`) and the backend catalog
  (`catalog.js`) so strict mode never rejects them (see §9).

### Event types
Every event has a coarse `type`; `track()` defaults to `action`. Override when relevant:
```dart
t.track('config_synced', type: EventType.system);
```
Types: `action` · `screen_view` · `error` · `system`.

---

## 7. Identity & sessions (how it behaves)
- Before `identify()`, events carry a stable **`anonymous_id`** (persisted per device/browser).
- After `identify(userId)`, events carry both `anonymous_id` and `user_id`; the backend links them.
- `reset()` (logout) mints a **new** `anonymous_id` so the next anonymous session isn't tied to the previous user.
- A **`session_id`** rotates after ~30 min of inactivity; a `session_start` event is emitted automatically.

---

## 8. Offline, batching, retries (automatic — nothing to do)
- Events are **queued and batched** (default flush every 15s or at 50 events) and **persisted**, so they survive app restarts.
- Failed sends **retry with exponential backoff**; a full queue drops the **oldest** events (cap 1000).
- Every event has a client-generated UUID, so retries are **de-duplicated server-side** — no double counting.
- The queue **flushes when the app goes to background**.

Works on **mobile and Flutter web** (uses `package:http`, no `dart:io`).

---

## 9. Data quality: keep the catalog in sync
`lib/src/event_catalog.dart` (`VistarEvents`) is the client list; the backend has a matching
`catalog.js`. If the backend runs with `EVENTTRACKER_STRICT_CATALOG=true`, an event name **not**
in the backend catalog is **rejected** (HTTP 400). Workflow for a new event:
1. Add the constant to `VistarEvents` (SDK).
2. Ask the backend team to add the same name to `catalog.js`.
3. Ship both.

(During early rollout the backend usually runs lenient — unknown names are accepted and logged.)

---

## 10. Privacy / consent
- If your app needs consent before tracking, set `requireConsent: true` in `TrackerConfig`.
  Nothing is captured until you call `VistarEventTracker.instance.setConsent(true)`.
- Set `EVENTTRACKER_ANONYMIZE_IP=true` on the backend (ops decision) to store only a coarse IP.
- Don't put secrets/PII (passwords, tokens, full card numbers) in `properties`.

---

## 11. Config reference (`TrackerConfig`)

| Field | Default | Notes |
|---|---|---|
| `appId`, `writeKey`, `baseUrl` | — | required |
| `appVersion` | null | stamped into `context` |
| `flushInterval` | 15s | periodic flush |
| `maxBatchSize` | 50 | events per POST |
| `maxQueueSize` | 1000 | oldest dropped when exceeded |
| `sessionTimeout` | 30 min | inactivity before a new session |
| `autoCaptureLifecycle` | true | app_open/foreground/background |
| `autoCaptureErrors` | true | client_error from error hooks |
| `requireConsent` | false | gate capture until `setConsent(true)` |
| `debug` | false | verbose logging |

---

## 12. Per-app rollout checklist
- [ ] Backend team created **this app's** `app_id` + write key.
- [ ] `vistar_event_tracker` added to `pubspec.yaml`.
- [ ] `init(...)` called in `main.dart` with the correct `appId` / `writeKey` / `baseUrl`.
- [ ] `VistarNavigatorObserver()` added to `MaterialApp`.
- [ ] `identify()` called after login, `reset()` on logout.
- [ ] Key business events instrumented with `track()` (start with your funnel: e.g. `app_open → product_viewed → order_placed`).
- [ ] Verified events appear in the **viewer → Explorer** (filter by your `app_id`).

---

## 13. Verify it's working
1. Run the app and interact with it.
2. In the **viewer** (or ask an admin), open **Explorer**, and you should see your events within seconds.
3. Or test the endpoint directly:
   ```bash
   curl -X POST https://api.vistar…/api/v1/eventtracker/events \
     -H 'content-type: application/json' \
     -H 'x-app-id: vistar_driver_app' \
     -H 'x-write-key: wk_xxx' \
     -d '[{"event_id":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","event_name":"app_open","event_type":"system"}]'
   # -> {"success":true,"data":{"received":1,"inserted":1,"duplicates":0,"notified":1}}
   ```

---

## 14. Websites (non-Flutter)
Only the **Flutter** SDK exists today. A JavaScript web SDK is planned; until then, a website can
POST the same batch envelope to `/api/v1/eventtracker/events` with its own `x-app-id` + `x-write-key`
(same JSON shape as §13). Ask the backend team for a website write key.

---

## 15. Support / conventions summary
- One `app_id` + write key **per app**. Never share keys between apps.
- Names: `object_action`, snake_case, agreed & catalogued.
- Data in `properties`, not in names. No PII/secrets in properties.
- Don't block the UI on analytics — the SDK is fire-and-forget by design.
