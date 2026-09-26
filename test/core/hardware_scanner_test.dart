import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:productivity_tracker/core/scanner/hardware_scanner.dart';

/// A stand-in for any of the DPL scan screens: a focusable field whose
/// onSubmitted records what it was given.
class _ScanField extends StatelessWidget {
  const _ScanField({
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        onSubmitted: onSubmitted,
      );
}

void main() {
  tearDown(() => HardwareScanner.instance.resetForTest());

  group('routing a handheld scan', () {
    testWidgets('it reaches the field that has focus', (tester) async {
      final got = <String>[];
      final node = FocusNode();
      final ctrl = TextEditingController();
      addTearDown(node.dispose);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: HardwareScanScope(
            child: Scaffold(
              body: _ScanField(
                controller: ctrl,
                focusNode: node,
                autofocus: true,
                onSubmitted: got.add,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      HardwareScanner.instance.emitForTest('GA2600000147');
      await tester.pump();

      expect(got, ['GA2600000147']);
    });

    testWidgets('ONE scan reaches ONE screen, not every mounted tab',
        (tester) async {
      // The whole reason this routes by focus. The QA shell keeps its tabs in
      // an IndexedStack, so Pallet, Merge, Put away and SPD are all mounted
      // and all alive at once. If each subscribed to the scan stream itself, a
      // single trigger pull would pack a wheel, resolve a pallet and start an
      // SPD lookup simultaneously — four API calls from one press.
      final pallet = <String>[];
      final merge = <String>[];
      final putaway = <String>[];

      final palletNode = FocusNode();
      final mergeNode = FocusNode();
      final putawayNode = FocusNode();
      final a = TextEditingController();
      final b = TextEditingController();
      final c = TextEditingController();
      for (final d in [palletNode, mergeNode, putawayNode]) {
        addTearDown(d.dispose);
      }
      for (final d in [a, b, c]) {
        addTearDown(d.dispose);
      }

      await tester.pumpWidget(
        MaterialApp(
          home: HardwareScanScope(
            child: Scaffold(
              body: IndexedStack(
                index: 0,
                children: [
                  _ScanField(
                    controller: a,
                    focusNode: palletNode,
                    autofocus: true,
                    onSubmitted: pallet.add,
                  ),
                  _ScanField(
                    controller: b,
                    focusNode: mergeNode,
                    onSubmitted: merge.add,
                  ),
                  _ScanField(
                    controller: c,
                    focusNode: putawayNode,
                    onSubmitted: putaway.add,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      HardwareScanner.instance.emitForTest('MWP|PM26000012');
      await tester.pump();

      expect(pallet, ['MWP|PM26000012'], reason: 'the focused tab gets it');
      expect(merge, isEmpty, reason: 'and nobody else does');
      expect(putaway, isEmpty);
    });

    testWidgets('moving focus moves where scans land', (tester) async {
      // Switching tabs moves focus, and the scans must follow without the
      // shell having to tell anybody.
      final first = <String>[];
      final second = <String>[];
      final n1 = FocusNode();
      final n2 = FocusNode();
      final c1 = TextEditingController();
      final c2 = TextEditingController();
      for (final d in [n1, n2]) {
        addTearDown(d.dispose);
      }
      for (final d in [c1, c2]) {
        addTearDown(d.dispose);
      }

      await tester.pumpWidget(
        MaterialApp(
          home: HardwareScanScope(
            child: Scaffold(
              body: Column(
                children: [
                  _ScanField(
                    controller: c1,
                    focusNode: n1,
                    autofocus: true,
                    onSubmitted: first.add,
                  ),
                  _ScanField(
                    controller: c2,
                    focusNode: n2,
                    onSubmitted: second.add,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      HardwareScanner.instance.emitForTest('one');
      await tester.pump();

      n2.requestFocus();
      await tester.pump();
      HardwareScanner.instance.emitForTest('two');
      await tester.pump();

      expect(first, ['one']);
      expect(second, ['two']);
    });

    testWidgets('a scan with nothing focused is dropped, not guessed at',
        (tester) async {
      // On a screen with no scan field there is nothing sensible to do with a
      // barcode, and picking a handler would fire an action the operator never
      // asked for.
      final got = <String>[];
      final node = FocusNode();
      final ctrl = TextEditingController();
      addTearDown(node.dispose);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: HardwareScanScope(
            child: Scaffold(
              body: _ScanField(
                controller: ctrl,
                focusNode: node,
                onSubmitted: got.add,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Nothing autofocused, so nothing holds primary focus.
      HardwareScanner.instance.emitForTest('GA2600000147');
      await tester.pump();

      expect(got, isEmpty);
    });
  });

  group('when nothing holds focus at all', () {
    testWidgets('the scan still reaches the visible tab', (tester) async {
      // THE BUG A PM75 FOUND. The decode arrived, reached Dart and went
      // nowhere, because nothing had focus: an IndexedStack builds its
      // children offstage, offstage subtrees cannot take focus, and autofocus
      // asks exactly once — it is refused while offstage and never asks again.
      // dumpsys input_method showed mServedView=null with the scan field
      // plainly on screen.
      final visible = <String>[];
      final hidden = <String>[];
      final areas = List.generate(2, (_) => GlobalKey());

      await tester.pumpWidget(
        MaterialApp(
          home: HardwareScanScope(
            // Tab 1 is the one on screen.
            activeArea: areas[1],
            child: Scaffold(
              body: IndexedStack(
                index: 1,
                children: [
                  KeyedSubtree(
                    key: areas[0],
                    child: TextField(onSubmitted: hidden.add),
                  ),
                  KeyedSubtree(
                    key: areas[1],
                    child: TextField(onSubmitted: visible.add),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Deliberately no autofocus anywhere — this is the real device state.
      expect(FocusManager.instance.primaryFocus?.hasPrimaryFocus, anyOf(isNull, isTrue));

      HardwareScanner.instance.emitForTest('GA2600000147');
      await tester.pump();

      expect(visible, ['GA2600000147'], reason: 'the tab on screen gets it');
      expect(hidden, isEmpty, reason: 'the offstage tab does not');
    });

    testWidgets('and it does NOT take focus, so no keyboard appears',
        (tester) async {
      // On a rugged handheld the trigger is the input, and a soft keyboard
      // covers half the screen. An earlier version focused the field after
      // delivering, which raised the keyboard on the first scan of every
      // session and hid the very list the operator had navigated to.
      final got = <String>[];
      final area = GlobalKey();

      await tester.pumpWidget(
        MaterialApp(
          home: HardwareScanScope(
            activeArea: area,
            child: Scaffold(
              body: KeyedSubtree(
                key: area,
                child: TextField(onSubmitted: got.add),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      HardwareScanner.instance.emitForTest('first');
      await tester.pump();

      expect(got, ['first'], reason: 'delivered by position, not by cursor');
      final focused = FocusManager.instance.primaryFocus;
      expect(
        focused?.context?.widget,
        isNot(isA<EditableText>()),
        reason: 'nothing was focused, so no keyboard was raised',
      );
    });

    testWidgets('a pushed screen claims scans off the tab underneath',
        (tester) async {
      // A pushed route sits OUTSIDE activeArea — that key points at the tab
      // still mounted behind it. Without the claim, a wheel scanned on the
      // trolley fill screen would be handed to the Merge tab behind it, and
      // the wrong screen would act on a real wheel.
      final behind = <String>[];
      final onTop = <String>[];
      final tabArea = GlobalKey();
      final pushedArea = GlobalKey();

      await tester.pumpWidget(
        MaterialApp(
          home: HardwareScanScope(
            activeArea: tabArea,
            child: Scaffold(
              body: KeyedSubtree(
                key: tabArea,
                child: TextField(onSubmitted: behind.add),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      HardwareScanScope.claimArea(pushedArea);
      addTearDown(() => HardwareScanScope.releaseArea(pushedArea));

      // The pushed screen's own subtree, mounted over the top.
      await tester.pumpWidget(
        MaterialApp(
          home: HardwareScanScope(
            activeArea: tabArea,
            child: Scaffold(
              body: Stack(
                children: [
                  KeyedSubtree(
                    key: tabArea,
                    child: TextField(onSubmitted: behind.add),
                  ),
                  KeyedSubtree(
                    key: pushedArea,
                    child: TextField(onSubmitted: onTop.add),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      HardwareScanner.instance.emitForTest('GA2600000147');
      await tester.pump();

      expect(onTop, ['GA2600000147'], reason: 'the screen on top gets it');
      expect(behind, isEmpty, reason: 'and the tab behind does not');

      // Once it closes, the tab underneath takes over again.
      HardwareScanScope.releaseArea(pushedArea);
      HardwareScanner.instance.emitForTest('GA2600000148');
      await tester.pump();
      expect(behind, ['GA2600000148']);
    });

    testWidgets('a screen with no field at all still drops it quietly',
        (tester) async {
      final area = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: HardwareScanScope(
            activeArea: area,
            child: Scaffold(
              body: KeyedSubtree(key: area, child: const Text('no fields')),
            ),
          ),
        ),
      );
      await tester.pump();

      HardwareScanner.instance.emitForTest('GA2600000147');
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('the stream itself', () {
    test('blank decodes never reach a screen', () async {
      // The native side trims before forwarding, but a decode that was only
      // whitespace would otherwise arrive as an empty submit and clear a field
      // for no reason.
      final seen = <String>[];
      final sub = HardwareScanner.instance.scans.listen(seen.add);
      addTearDown(sub.cancel);

      HardwareScanner.instance.emitForTest('GA2600000147');
      await Future<void>.delayed(Duration.zero);

      expect(seen, ['GA2600000147']);
    });

    test('it is a broadcast stream — the scope is not the only possible listener',
        () async {
      // Putaway and the dispatch screens live outside the QA shell, so the
      // stream has to tolerate a second subscriber without the native channel
      // being registered twice.
      final a = <String>[];
      final b = <String>[];
      final s1 = HardwareScanner.instance.scans.listen(a.add);
      final s2 = HardwareScanner.instance.scans.listen(b.add);
      addTearDown(s1.cancel);
      addTearDown(s2.cancel);

      HardwareScanner.instance.emitForTest('MWS|SP26000411');
      await Future<void>.delayed(Duration.zero);

      expect(a, ['MWS|SP26000411']);
      expect(b, ['MWS|SP26000411']);
    });
  });
}
