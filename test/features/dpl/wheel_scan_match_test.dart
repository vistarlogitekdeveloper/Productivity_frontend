import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_spd.dart';
import 'package:productivity_tracker/features/dpl/qa/services/wheel_scan_match.dart';

/// The Merge and SPD screens move a wheel only when the scanned label is
/// matched to a wheel on the right pallet. A false match moves the wrong
/// wheel; a missed match refuses a wheel the operator is holding.
void main() {
  const ours = DplWheel(id: 1, serialNo: 'GA2600000147');
  const old = DplWheel(id: 2, serialNo: '19255/std1//13/06Oct26/12:54:33/A/13');
  const voided = DplWheel(id: 3, serialNo: 'GA2600000148', status: 'voided');
  const wheels = [ours, old, voided];

  test('our QR matches on its serial field', () {
    expect(
      matchScannedWheel('GA|GA|19255|GA2600000147|261006|A|-', wheels)?.id,
      1,
    );
  });

  test('a serial keyed in by hand matches, in any case', () {
    expect(matchScannedWheel('ga2600000147', wheels)?.id, 1);
  });

  test("an old Maxion label matches on its whole printed text", () {
    expect(
      matchScannedWheel('19255/std1//13/06Oct26/12:54:33/A/13', wheels)?.id,
      2,
    );
  });

  test('a label for a wheel that is not in the list does not match', () {
    expect(matchScannedWheel('GA|GA|19255|GA2600000999|261006|A|-', wheels), isNull);
    // A different old label, one digit apart, is a different wheel.
    expect(matchScannedWheel('19255/std1//14/06Oct26/12:54:33/A/14', wheels), isNull);
  });

  test('a voided wheel never matches', () {
    expect(matchScannedWheel('GA2600000148', wheels), isNull);
  });

  test('a blank scan matches nothing', () {
    expect(matchScannedWheel('   ', wheels), isNull);
  });
}
