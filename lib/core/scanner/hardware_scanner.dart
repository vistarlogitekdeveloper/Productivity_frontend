import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Decoded barcodes arriving from a rugged handheld's built-in scan engine.
///
/// Two completely different delivery paths exist on these devices, and which
/// one a unit uses is a setting on the device, not something the app can
/// choose:
///
///   * **Keyboard wedge.** The engine types the barcode as if it were a
///     keyboard and usually follows with Enter. CipherLab RS35 and most Zebras
///     ship this way. Nothing in the app is needed — the scan lands in
///     whichever field has focus and the existing `onSubmitted` fires.
///   * **Intent.** The engine broadcasts the decode and sends no keystrokes at
///     all. Point Mobile PM75 and family need this, because their wedge does
///     not deliver keys to Flutter without native IME focus — the trigger
///     beeps, the LED flashes, and the app sees nothing.
///
/// This class is the second path. [MainActivity] arms the engine through the
/// EmKit SDK, receives the broadcast and forwards the decoded string here.
///
/// The channel is opened lazily and only on Android. Everywhere else — web,
/// desktop, iOS, and every Android phone without a scan engine — the stream
/// simply stays silent, which is the correct behaviour rather than an error.
class HardwareScanner {
  HardwareScanner._();

  /// One instance, because the native side registers its BroadcastReceiver on
  /// the FIRST subscription and unregisters on the last. Several independent
  /// subscriptions would thrash that registration.
  static final HardwareScanner instance = HardwareScanner._();

  /// Must match CHANNEL_NAME in MainActivity.kt.
  static const _channel = EventChannel('vistar_productivity/scan_intents');

  StreamController<String>? _controller;
  StreamSubscription<dynamic>? _native;

  /// Every decode the handheld reports, trimmed and never empty.
  Stream<String> get scans {
    final existing = _controller;
    if (existing != null) return existing.stream;

    final controller = StreamController<String>.broadcast(
      onCancel: _stopIfIdle,
    );
    _controller = controller;
    _start();
    return controller.stream;
  }

  void _start() {
    if (_native != null) return;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    _native = _channel.receiveBroadcastStream().listen(
      (value) {
        if (value is! String) return;
        final code = value.trim();
        if (code.isEmpty) return;
        _controller?.add(code);
      },
      // A device with no scan engine never opens the channel. That is the
      // normal case on a phone, so it must not surface as an error banner.
      onError: (_) {},
      cancelOnError: false,
    );
  }

  void _stopIfIdle() {
    final controller = _controller;
    if (controller == null || controller.hasListener) return;
    _native?.cancel();
    _native = null;
  }

  /// Test seam. Pushes [code] as though the handheld had decoded it.
  @visibleForTesting
  void emitForTest(String code) => _controller?.add(code);

  @visibleForTesting
  void resetForTest() {
    _native?.cancel();
    _native = null;
    _controller?.close();
    _controller = null;
  }
}

/// Routes hardware scans to whichever text field currently has focus.
///
/// WHY FOCUS, AND NOT A SUBSCRIPTION PER SCREEN. The QA shell keeps its tabs in
/// an IndexedStack, so Pallet, Merge, Put away and SPD are all mounted and all
/// listening at the same time. A screen that subscribed directly would receive
/// every trigger pull no matter which tab the operator was looking at, and one
/// scan would become four API calls on four screens at once — a wheel packed,
/// a pallet resolved and an SPD lookup from a single press.
///
/// Routing by focus avoids that completely, and it does something better
/// besides: it makes the intent path behave EXACTLY like the keyboard-wedge
/// path. A wedge types into the focused field; this delivers to the focused
/// field. One code path, one set of handlers, nothing to keep in sync — and
/// every existing scan screen works unchanged, because they all already accept
/// a submitted string.
///
/// Mount it once, above the screens that scan.
class HardwareScanScope extends StatefulWidget {
  const HardwareScanScope({super.key, required this.child});

  final Widget child;

  /// Put focus on the first scannable field inside [context]'s subtree.
  ///
  /// Call this when a tab becomes visible. Hidden children of an IndexedStack
  /// cannot hold focus, and `autofocus` fires once and only once — so after
  /// the operator switches tabs, NOTHING has focus and the handheld's trigger
  /// does nothing at all. That is not specific to the intent path either: a
  /// keyboard-wedge scanner types into the void in exactly the same situation,
  /// which is the "the scanner stopped working after I checked the other
  /// screen" report that has no visible cause.
  ///
  /// Disabled fields are skipped — several screens disable their scan box
  /// while a request is in flight, and focusing one would silently do nothing.
  static void focusScanFieldIn(BuildContext? context) {
    if (context is! Element || !context.mounted) return;
    EditableText? first;
    void walk(Element element) {
      if (first != null) return;
      final widget = element.widget;
      if (widget is EditableText && widget.focusNode.canRequestFocus) {
        first = widget;
        return;
      }
      element.visitChildren(walk);
    }

    context.visitChildren(walk);
    final node = first?.focusNode;
    if (node != null && !node.hasFocus) node.requestFocus();
  }

  @override
  State<HardwareScanScope> createState() => _HardwareScanScopeState();
}

class _HardwareScanScopeState extends State<HardwareScanScope> {
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = HardwareScanner.instance.scans.listen(_deliver);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _deliver(String code) {
    final target = _focusedField();
    if (target == null) {
      // Nothing is waiting for a scan. Dropped deliberately and quietly: on a
      // screen with no scan field there is nothing sensible to do with a
      // barcode, and guessing would fire an action the operator did not ask
      // for. Every screen that scans keeps its field focused for exactly this.
      return;
    }
    // onSubmitted is called with the value directly rather than by writing to
    // the controller first, because every handler in this app takes the string
    // as its argument and clears the field itself. Writing the text as well
    // would show it for one frame and risk a second submit through onChanged.
    target.onSubmitted?.call(code);
  }

  /// The [EditableText] behind whatever currently holds focus.
  ///
  /// WALKS UP, and that is not a detail. The primary focus node's own context
  /// is the `Focus` widget that EditableText builds INSIDE itself, so
  /// `primaryFocus.context.widget` is a `Focus` and never an `EditableText` —
  /// an `is EditableText` test on it silently matches nothing, for ever, and
  /// the scan quietly goes nowhere. EditableText is an ancestor of that
  /// context, so the only way to reach it is upward.
  EditableText? _focusedField() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return null;
    EditableText? found;
    ctx.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is EditableText) {
        found = widget;
        return false;
      }
      return true;
    });
    return found;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
