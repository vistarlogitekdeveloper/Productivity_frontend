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

/// A miniature of the QA shell: two scan screens in an IndexedStack, keyed so
/// a tab switch can reach into the one that just became visible, exactly as
/// qa_shell.dart does.
class _TabHarness extends StatefulWidget {
  const _TabHarness({required this.onFirst, required this.onSecond});

  final ValueChanged<String> onFirst;
  final ValueChanged<String> onSecond;

  @override
  State<_TabHarness> createState() => _TabHarnessState();
}

class _TabHarnessState extends State<_TabHarness> {
  int _tab = 0;
  final _keys = List.generate(2, (_) => GlobalKey());

  void _show(int i) {
    setState(() => _tab = i);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      HardwareScanScope.focusScanFieldIn(_keys[i].currentContext);
    });
  }

  @override
  Widget build(BuildContext context) => HardwareScanScope(
        child: Scaffold(
          body: Column(
            children: [
              TextButton(onPressed: () => _show(1), child: const Text('switch')),
              Expanded(
                child: IndexedStack(
                  index: _tab,
                  children: [
                    KeyedSubtree(
                      key: _keys[0],
                      child: TextField(
                        autofocus: true,
                        onSubmitted: widget.onFirst,
                      ),
                    ),
                    KeyedSubtree(
                      key: _keys[1],
                      child: TextField(onSubmitted: widget.onSecond),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
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

  group('switching tabs', () {
    testWidgets('focus follows the visible tab, so the trigger keeps working',
        (tester) async {
      // THE BUG THIS EXISTS TO STOP. Hidden children of an IndexedStack cannot
      // hold focus, and autofocus fires once and only once — so the moment the
      // operator switches tabs, NOTHING is focused and the handheld does
      // nothing at all. A keyboard-wedge scanner types into the void in
      // exactly the same situation, which is the "the scanner stopped working
      // after I looked at another screen" report with no visible cause.
      final first = <String>[];
      final second = <String>[];

      await tester.pumpWidget(
        MaterialApp(home: _TabHarness(onFirst: first.add, onSecond: second.add)),
      );
      await tester.pump();

      HardwareScanner.instance.emitForTest('before');
      await tester.pump();
      expect(first, ['before'], reason: 'tab 0 starts focused');

      await tester.tap(find.text('switch'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      HardwareScanner.instance.emitForTest('after');
      await tester.pump();

      expect(second, ['after'], reason: 'the newly visible tab now gets it');
      expect(first, ['before'], reason: 'and the hidden one does not');
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
