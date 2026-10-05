import 'uuid.dart';

/// Result of [SessionManager.touch]: the current session id and whether this
/// touch started a NEW session (so the tracker can emit `session_start`).
typedef SessionTouch = ({String id, bool isNew});

/// Session id with inactivity-based rotation (default ~30 min). Kept in memory:
/// a fresh app launch is a fresh session by design.
class SessionManager {
  SessionManager(this.timeout);
  final Duration timeout;

  String? _id;
  DateTime? _lastActivity;

  /// Register activity at [now]; rotates the session if it had been idle longer
  /// than [timeout] (or if none exists yet).
  SessionTouch touch(DateTime now) {
    final expired = _lastActivity == null || now.difference(_lastActivity!) > timeout;
    if (_id == null || expired) {
      _id = uuidV4();
    }
    _lastActivity = now;
    return (id: _id!, isNew: expired);
  }

  String? get currentId => _id;

  /// Forget the session (e.g. on reset()/logout) so the next event starts fresh.
  void rotate() {
    _id = null;
    _lastActivity = null;
  }
}
