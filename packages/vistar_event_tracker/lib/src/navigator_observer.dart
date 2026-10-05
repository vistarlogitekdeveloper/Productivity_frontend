import 'package:flutter/widgets.dart';

import 'vistar_event_tracker_base.dart';

/// Drop this into `MaterialApp(navigatorObservers: [VistarNavigatorObserver()])`
/// to auto-emit a `screen_viewed` event on every push/replace, using the
/// route's `settings.name`. Routes without a name are skipped (set
/// `RouteSettings(name: ...)` or use named routes to capture them).
class VistarNavigatorObserver extends NavigatorObserver {
  VistarNavigatorObserver({VistarEventTracker? tracker}) : _tracker = tracker;

  final VistarEventTracker? _tracker;
  VistarEventTracker get _t => _tracker ?? VistarEventTracker.instance;

  void _emit(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name == null || name.isEmpty) return;
    _t.screen(name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _emit(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _emit(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // On back-navigation, the revealed screen is the previous route.
    _emit(previousRoute);
  }
}
