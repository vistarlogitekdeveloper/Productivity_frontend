# Changelog

## 0.1.0

- Initial release.
- Core API: `init / track / screen / identify / reset / flush / setConsent`.
- Durable offline queue (shared_preferences) with batching and exponential
  backoff; idempotent via client-generated event UUIDs.
- Auto-capture: screen views (`VistarNavigatorObserver`), app lifecycle, and
  Flutter/async errors.
- Inactivity-based session rotation with automatic `session_start`.
- Cross-platform (mobile + Flutter web) via `package:http`.
- Event envelope matches the backend `POST /api/v1/eventtracker/events` contract.
