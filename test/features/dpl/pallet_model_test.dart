import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_pallet.dart';

/// The pack point screen is glanced at, not read. These are the strings and
/// numbers it glances at — a counter that lies or a Close button that promises
/// the wrong pallet type is a physical mistake, not a cosmetic one.
void main() {
  _discardWarningTests();

  group('DplPallet parsing', () {
    test('parses an open pallet with its part and machine', () {
      final p = DplPallet.fromJson({
        'id': 12,
        'status': 'open',
        'part_id': 3,
        'qty': 37,
        'standard_qty': 96,
        'remaining': 59,
        'is_full': false,
        'part': {'customer_part_no': '18663', 'description': 'Al Wheel'},
        'machine': {'machine_name': 'Pack 1'},
        'serials': [
          {'serial_no': 'GA2600000147'},
          {'serial_no': 'GA2600000148'},
        ],
      });

      expect(p.isOpen, isTrue);
      expect(p.customerPartNo, '18663');
      expect(p.machineName, 'Pack 1');
      expect(p.qty, 37);
      expect(p.standardQty, 96);
      expect(p.serials, hasLength(2));
    });

    test('a missing standard quantity stays NULL, never zero', () {
      // The whole Maxion item master has no standard pallet quantity yet.
      // Collapsing that to 0 would render the counter as "37 / 0" and make
      // `isFull` true the moment anything is packed.
      final p = DplPallet.fromJson({'id': 1, 'qty': 37, 'standard_qty': null});
      expect(p.standardQty, isNull);
      expect(p.hasTarget, isFalse);
      expect(p.countLabel, '37');
      expect(p.progress, 0);
    });
  });

  group('the counter', () {
    test('reads "37 / 96" when there is a target', () {
      final p = DplPallet.fromJson({'qty': 37, 'standard_qty': 96});
      expect(p.countLabel, '37 / 96');
      expect(p.progress, closeTo(37 / 96, 0.0001));
    });

    test('progress never exceeds one, even if the count somehow does', () {
      // A progress bar that overflows its track looks like a rendering fault
      // and hides the real problem.
      final p = DplPallet.fromJson({'qty': 120, 'standard_qty': 96});
      expect(p.progress, 1);
    });
  });

  group('the Close button promise', () {
    test('says FULL only at or above the standard quantity', () {
      final full = DplPallet.fromJson({'qty': 96, 'standard_qty': 96});
      expect(full.closePreview, contains('FULL'));
      expect(full.closePreview, contains('96'));
    });

    test('says HALF one short of full — "half" means "not full"', () {
      // 95 of 96 is a half pallet. Naming it by proportion would let a pallet
      // one wheel short go out as a complete unit.
      final short = DplPallet.fromJson({'qty': 95, 'standard_qty': 96});
      expect(short.closePreview, contains('HALF'));
      expect(short.closePreview, contains('95 of 96'));
    });

    test('says HALF and explains itself when there is no target at all', () {
      // The operator must not be left wondering why a seemingly full pallet
      // is about to be called half.
      final none = DplPallet.fromJson({'qty': 40, 'standard_qty': null});
      expect(none.closePreview, contains('HALF'));
      expect(none.closePreview, contains('no standard pallet quantity'));
      // Names the remedy too — a message that only reports a gap the operator
      // cannot close teaches them to ignore it.
      expect(none.closePreview, contains('Packaging Qtys'));
    });
  });

  group('type labels', () {
    test('render in the operator\'s words, not the database\'s', () {
      expect(DplPallet.fromJson({'pallet_type': 'P'}).typeLabel, 'Full');
      expect(DplPallet.fromJson({'pallet_type': 'H'}).typeLabel, 'Half');
      expect(DplPallet.fromJson({'pallet_type': 'PM'}).typeLabel, 'Merged');
    });

    test('an open pallet has no type yet', () {
      // The type is decided by the system at close. Showing one before then
      // would be a guess the operator might act on.
      expect(DplPallet.fromJson({'pallet_type': ''}).typeLabel, 'Open');
    });
  });

  test('a stored half pallet carries its age', () {
    // SSR §4 names ageing half pallets as the problem the system exists to
    // solve, so the age has to survive parsing.
    final p = DplPallet.fromJson({
      'id': 5,
      'pallet_no': 'H26000001',
      'pallet_type': 'H',
      'status': 'closed',
      'qty': 48,
      'standard_qty': 96,
      'age_days': 11,
    });
    expect(p.ageDays, 11);
    expect(p.typeLabel, 'Half');
    expect(p.isOpen, isFalse);
  });
}

/// Discarding a pallet that was opened by bringing a half pallet back is NOT
/// simply undone — the half pallet is restored with exactly the wheels it gave
/// up. The screen has to say so, because promising "they all go back to
/// unpacked" would have the operator rebuilding a half pallet that already
/// exists.
void _discardWarningTests() {
  group('brought-back pallets', () {
    test('a pallet started empty reports nothing brought back', () {
      final p = DplPallet.fromJson(const {'id': 1, 'qty': 3});
      expect(p.broughtBackQty, 0);
    });

    test('a brought-back pallet carries the count it arrived with', () {
      final p = DplPallet.fromJson(const {
        'id': 1,
        'qty': 5,
        'built_from_pallet_id': 8,
        'brought_back_qty': 2,
      });
      expect(p.broughtBackQty, 2);
      // Two came from the half pallet, three were scanned on after — and only
      // the three go back to unpacked.
      expect(p.qty - p.broughtBackQty, 3);
    });
  });
}
