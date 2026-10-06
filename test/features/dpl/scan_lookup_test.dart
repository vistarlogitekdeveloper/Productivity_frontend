import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_spd.dart';

/// `GET /warehouse/lookup` — what "Scan to find" shows for a scanned label.
void main() {
  test('a pallet sticker: the pallet, its location and its wheels', () {
    final r = DplScanLookup.fromJson({
      'kind': 'pallet',
      'renamed_from': null,
      'wheel': null,
      'pallet': {
        'id': 10,
        'pallet_no': 'H26000021',
        'qty': 2,
        'standard_qty': 24,
        'location': {'id': 3, 'code': 'STAGING'},
      },
      'wheels': [
        {'id': 101, 'serial_no': 'GA2600000147', 'status': 'issued'},
        {'id': 102, 'serial_no': '19255/std1//13/06Oct26/12:54:33/A/13', 'status': 'issued'},
      ],
    });
    expect(r.isPallet, isTrue);
    expect(r.pallet!.palletNo, 'H26000021');
    expect(r.pallet!.locationCode, 'STAGING');
    expect(r.wheels.map((w) => w.id), [101, 102]);
    expect(r.wheel, isNull);
    expect(r.renamedFrom, '');
  });

  test('a wheel label: the pallet it is on, naming the scanned wheel', () {
    final r = DplScanLookup.fromJson({
      'kind': 'wheel',
      'wheel': {'id': 102, 'serial_no': '19255/std1//13/06Oct26/12:54:33/A/13'},
      'pallet': {'id': 10, 'pallet_no': 'H26000021'},
      'wheels': [
        {'id': 101, 'serial_no': 'GA2600000147'},
        {'id': 102, 'serial_no': '19255/std1//13/06Oct26/12:54:33/A/13'},
      ],
    });
    expect(r.isPallet, isFalse);
    expect(r.wheel!.id, 102);
    expect(r.pallet!.palletNo, 'H26000021');
  });

  test('a wheel on no pallet keeps the reason', () {
    final r = DplScanLookup.fromJson({
      'kind': 'wheel',
      'wheel': {'id': 103, 'serial_no': 'GA2600000150'},
      'pallet': null,
      'wheels': [],
      'note': 'This wheel is parked on a trolley, not on a pallet.',
    });
    expect(r.pallet, isNull);
    expect(r.note, contains('trolley'));
  });
}
