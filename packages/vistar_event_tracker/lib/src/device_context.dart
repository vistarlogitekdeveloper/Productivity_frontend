import 'package:flutter/foundation.dart';

import 'tracker_config.dart';

const String kSdkName = 'vistar_event_tracker';
const String kSdkVersion = '0.1.0';

/// Server-independent context stamped into every event. Built once at init;
/// [snapshot] returns a fresh copy per event so callers can't mutate the base.
/// Dependency-free (foundation only) so it's web-safe — the backend adds
/// ip/geo/ua under `context.server`.
class DeviceContext {
  DeviceContext._(this._base);
  final Map<String, dynamic> _base;

  static DeviceContext build(TrackerConfig config) {
    final base = <String, dynamic>{
      'sdk': kSdkName,
      'sdk_version': kSdkVersion,
      'platform': _platformName(),
      'is_web': kIsWeb,
      if (config.appVersion != null) 'app_version': config.appVersion,
      'locale': _locale(),
    };
    return DeviceContext._(base);
  }

  Map<String, dynamic> snapshot() => Map<String, dynamic>.from(_base);

  static String _platformName() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  static String? _locale() {
    try {
      return PlatformDispatcher.instance.locale.toLanguageTag();
    } catch (_) {
      return null;
    }
  }
}
