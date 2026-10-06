import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/qa/screens/dpl_qr_scan_sheet.dart';

/// What the camera accepts — the same functions the sheet runs.
void main() {
  const pallet = 'MWP|H26000020';
  const palletNo = 'H26000020';
  const wheel = 'GA|GA|19255|GA2600000147|261006|A|-';
  const serial = 'GA2600000147';
  const oldLabel = '19255/std1//13/06Oct26/12:54:33/A/13';

  String? check(String code, DplScanKind kind, {bool allowExternal = false}) =>
      DplScanCheck.rejectReason(code, kind: kind, allowExternal: allowExternal);

  group('Scan to find (any)', () {
    test('accepts a pallet sticker — the read the user was refused', () {
      expect(check(pallet, DplScanKind.any), isNull);
      expect(check(palletNo, DplScanKind.any), isNull);
    });

    test('accepts a wheel label and a bare serial', () {
      expect(check(wheel, DplScanKind.any), isNull);
      expect(check(serial, DplScanKind.any), isNull);
    });

    test('accepts an old Maxion label even with old labels switched off', () {
      // Looking one up moves nothing, so there is nothing to protect.
      expect(check(oldLabel, DplScanKind.any), isNull);
    });

    test('still refuses something that is no label at all', () {
      expect(check('https://example.com/x', DplScanKind.any), isNotNull);
      expect(check('hello', DplScanKind.any), isNotNull);
      expect(check('   ', DplScanKind.any), 'Nothing was read.');
    });
  });

  group('the existing kinds are unchanged', () {
    test('wheel still refuses a pallet sticker by name', () {
      expect(check(pallet, DplScanKind.wheel), 'That is a pallet label, not a wheel label.');
      expect(check(wheel, DplScanKind.wheel), isNull);
    });

    test('wheel takes an old label only when allowed', () {
      expect(check(oldLabel, DplScanKind.wheel), isNotNull);
      expect(check(oldLabel, DplScanKind.wheel, allowExternal: true), isNull);
    });

    test('pallet still refuses a wheel label by name', () {
      expect(check(wheel, DplScanKind.pallet), contains('wheel label'));
      expect(check(pallet, DplScanKind.pallet), isNull);
    });
  });
}
