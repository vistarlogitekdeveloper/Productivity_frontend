import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/core/scanner/hardware_scanner.dart';
import 'package:productivity_tracker/features/dpl/core/scan_code.dart';
import 'package:productivity_tracker/features/dpl/core/widgets/dpl_scan_panel.dart';

/// RF-gun scans of PALLET stickers. Wheel labels worked; pallet stickers did
/// not, for two reasons pinned here:
///   * an intent-mode gun hands the decode to onSubmitted without typing it,
///     and the scan panel (every pallet-sticker screen) read its own empty
///     field instead of the value;
///   * a keyboard-wedge gun on the wrong layout loses the `|`, and only the
///     pallet sticker has one.
void main() {
  group('repairStickerPayload', () {
    test('puts back a lost or swapped pipe on a pallet sticker', () {
      expect(repairStickerPayload('MWPPM26000012'), 'MWP|PM26000012');
      expect(repairStickerPayload(r'MWP\PM26000012'), 'MWP|PM26000012');
      expect(repairStickerPayload(' mwp h26000007 '), 'MWP|H26000007');
      expect(repairStickerPayload('MWPP26000010'), 'MWP|P26000010');
      expect(repairStickerPayload('MWSSP26000013'), 'MWS|SP26000013');
    });

    test('leaves everything else exactly as scanned', () {
      expect(repairStickerPayload('MWP|PM26000012'), 'MWP|PM26000012');
      expect(repairStickerPayload('PM26000012'), 'PM26000012');
      // A plant wheel label is mixed case and matched exactly.
      expect(repairStickerPayload('9313BM/std 2//53/26Sep2~b0511732'),
          '9313BM/std 2//53/26Sep2~b0511732');
      expect(repairStickerPayload('GA|NEXON|1|GA2600000147'), 'GA|NEXON|1|GA2600000147');
      expect(repairStickerPayload('MWPXYZ'), 'MWPXYZ');
    });
  });

  testWidgets('an intent-mode RF scan reaches a scan panel', (tester) async {
    addTearDown(HardwareScanner.instance.resetForTest);
    final area = GlobalKey();
    final got = <String>[];
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HardwareScanScope(
          activeArea: area,
          child: KeyedSubtree(
            key: area,
            child: DplScanPanel(
              title: 'Scan the pallet',
              controller: ctrl,
              onSubmitted: got.add,
            ),
          ),
        ),
      ),
    ));

    // Nothing focused, nothing typed: exactly how the trigger delivers.
    HardwareScanner.instance.emitForTest('MWP|PM26000012');
    await tester.pump();
    HardwareScanner.instance.emitForTest('MWPPM26000013');
    await tester.pump();

    expect(got, ['MWP|PM26000012', 'MWP|PM26000013']);
  });

  testWidgets('typed and Go still submit what is in the box', (tester) async {
    final got = <String>[];
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DplScanPanel(title: 'Scan', controller: ctrl, onSubmitted: got.add),
      ),
    ));
    await tester.enterText(find.byType(TextField), 'PM26000012');
    await tester.tap(find.byTooltip('Go'));
    await tester.pump();
    expect(got, ['PM26000012']);
  });
}
