import 'package:flutter/foundation.dart';

/// Tiny gated logger — silent unless [TrackerConfig.debug] is on.
class TrackerLogger {
  TrackerLogger(this.enabled);
  final bool enabled;

  void log(String message) {
    if (enabled) debugPrint('[vistar_event_tracker] $message');
  }
}
