import 'package:flutter/widgets.dart';

import 'vistar_palette.dart';

/// Keeps [VistarTokens.active] in step with the app's brightness, and
/// repaints the whole tree when it flips.
///
/// Screens read colours through static getters (`DplColors.cardBg`,
/// `VistarPalette.txt`), which Flutter can't track the way it tracks
/// `Theme.of(context)`. So on a flip this widget marks every descendant
/// element for rebuild — a one-off full rebuild that keeps all state (open
/// forms, scroll positions, the navigation stack) intact.
///
/// Mount it *above* `MaterialApp` so the tokens are switched before any
/// route builds.
class VistarThemeSync extends StatefulWidget {
  final Brightness brightness;
  final Widget child;

  const VistarThemeSync({
    super.key,
    required this.brightness,
    required this.child,
  });

  @override
  State<VistarThemeSync> createState() => _VistarThemeSyncState();
}

class _VistarThemeSyncState extends State<VistarThemeSync> {
  @override
  void initState() {
    super.initState();
    VistarTokens.activate(widget.brightness);
  }

  @override
  void didUpdateWidget(covariant VistarThemeSync oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.brightness == widget.brightness) return;
    VistarTokens.activate(widget.brightness);
    // Runs inside the ancestor's rebuild, so marking descendants dirty is
    // legal and they are rebuilt in this same frame — no flash of the old
    // palette.
    void rebuild(Element element) {
      element.markNeedsBuild();
      element.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
