import 'package:flutter_test/flutter_test.dart';

import 'package:productivity_tracker/features/dpl/models/dpl_pallet.dart';

/// The master pallet label and the register's filters — Maxion SSR v3.0 §5.
///
/// What is worth pinning here is the stuff a person cannot check by looking at
/// a screen: what goes INTO the QR (a label already stuck to a shroud cannot be
/// corrected), and whether clearing a filter actually clears it.
void main() {
  group('DplPalletSticker', () {
    Map<String, dynamic> payload({
      String palletNo = 'PM26000012',
      String type = 'PM',
      int qty = 96,
      int? standardQty = 96,
      String? closedAt = '2026-09-22T10:00:00.000Z',
      String? oldestAt = '2026-09-05T06:00:00.000Z',
      String mergedFrom = 'H26000007',
    }) =>
        {
          'pallet': {
            'id': 5,
            'pallet_no': palletNo,
            'pallet_type': type,
            'qty': qty,
            'standard_qty': standardQty,
            'shift_code': 'A',
            'closed_at': closedAt,
            'oldest_wheel_at': oldestAt,
            'merged_from_pallet_no': mergedFrom,
          },
          'part': {
            'customer_part_no': 'W-1',
            'description': '102D1',
            'part_name': 'X0 HL ASSEMBLY',
          },
          'machine_name': 'Pack 1',
          'location_code': 'FG-A-03',
          'serial_from': 'GA2600000101',
          'serial_to': 'GA2600000196',
        };

    test('the QR carries the pallet number and NOTHING else', () {
      // SSR §5: "MWP|PM26000012 — Only the pallet number is in the code.
      // Scanning it shows the full wheel list from the system."
      //
      // This is the assertion to break loudly if someone "improves" the
      // payload. A pallet's contents change on a merge, and §5 has the label
      // reprinted when that happens — so an embedded quantity would be wrong
      // on a label already stuck to a shroud, with no way to tell from the
      // outside. A bare number always resolves to the truth.
      final s = DplPalletSticker.fromJson(payload());
      expect(s.qrPayload, 'MWP|PM26000012');
      expect(s.qrPayload.split('|').length, 2);
    });

    test('the type reads as a word, not as a letter', () {
      // An operator deciding whether a pallet ships or goes back for topping up
      // reads this from across a bay. 'H' does not carry at that distance.
      expect(
        DplPalletSticker.fromJson(payload(type: 'P')).typeWord,
        'FULL',
      );
      expect(DplPalletSticker.fromJson(payload(type: 'H')).typeWord, 'HALF');
      expect(DplPalletSticker.fromJson(payload(type: 'PM')).typeWord, 'MERGED');
    });

    test('an unknown type still prints something rather than a blank', () {
      // A blank where the type should be reads as a system that lost track of
      // the pallet. Falling back to the raw code at least tells whoever finds
      // it what to search for.
      expect(DplPalletSticker.fromJson(payload(type: 'X')).typeWord, 'X');
      expect(DplPalletSticker.fromJson(payload(type: '')).typeWord, 'PALLET');
    });

    test('the quantity line drops the target when no standard is set', () {
      // Every Maxion item lacks a standard pallet quantity until that master
      // data lands. "QTY: 37 / 0 NOS" printed on a physical label is worse
      // than no target at all.
      expect(
        DplPalletSticker.fromJson(payload(qty: 96)).qtyLine,
        'QTY: 96 / 96 NOS',
      );
      expect(
        DplPalletSticker.fromJson(payload(qty: 37, standardQty: null)).qtyLine,
        'QTY: 37 NOS',
      );
      expect(
        DplPalletSticker.fromJson(payload(qty: 37, standardQty: 0)).qtyLine,
        'QTY: 37 NOS',
      );
    });

    test('the OLDEST date is printed only when it differs from the pack date', () {
      // SSR §4: a merged pallet keeps the oldest production date of the wheels
      // on it. On an ordinary pallet the two dates are the same and a second
      // cell is noise; on a merged one the gap is the whole point.
      final merged = DplPalletSticker.fromJson(payload());
      final keys = merged.detailCells.map((e) => e.key).toList();
      expect(keys, contains('OLDEST'));

      final sameDay = DplPalletSticker.fromJson(
        payload(
          closedAt: '2026-09-22T10:00:00.000Z',
          oldestAt: '2026-09-22T02:00:00.000Z',
        ),
      );
      expect(sameDay.detailCells.map((e) => e.key), isNot(contains('OLDEST')));
    });

    test('empty facts are dropped, never printed as a dash', () {
      // An empty cell on a physical label reads as a system that lost
      // something. Leaving it out reads as "not applicable".
      final s = DplPalletSticker.fromJson(
        payload(mergedFrom: '')
          ..['location_code'] = null
          ..['machine_name'] = '',
      );
      final keys = s.detailCells.map((e) => e.key).toList();
      expect(keys, isNot(contains('MERGED FROM')));
      expect(keys, isNot(contains('LOC')));
      expect(keys, isNot(contains('LINE')));
      for (final c in s.detailCells) {
        expect(c.value.trim(), isNotEmpty);
      }
    });

    test('a merged pallet names the half pallet it came from', () {
      // SSR §5: "...and, for a merged pallet, the old half pallet number."
      final s = DplPalletSticker.fromJson(payload());
      final cell = s.detailCells.firstWhere((e) => e.key == 'MERGED FROM');
      expect(cell.value, 'H26000007');
    });

    test('a malformed response yields a blank sticker rather than throwing', () {
      // The print happens straight after a successful close. An exception here
      // would look to the operator like the close itself failed, and they
      // would close it again.
      final s = DplPalletSticker.fromJson(const {});
      expect(s.palletNo, '');
      expect(s.qty, 0);
      expect(s.detailCells, isEmpty);
    });
  });

  group('DplPalletFilter', () {
    test('changing any filter resets to the first page', () {
      // Keeping the offset lands the storeman on page 4 of a 2-page result,
      // which draws an empty list and reads as "the pallets are gone".
      const f = DplPalletFilter(offset: 150);
      expect(f.copyWith(status: 'closed').offset, 0);
      expect(f.copyWith(search: 'PM26').offset, 0);
      expect(f.copyWith(staleHalfOnly: true).offset, 0);
    });

    test('paging is the one change that keeps its offset', () {
      const f = DplPalletFilter(status: 'closed');
      final next = f.copyWith(offset: 50, limit: 50);
      expect(next.offset, 50);
      expect(next.status, 'closed');
    });

    test('a nullable filter needs an explicit clear to be cleared', () {
      // copyWith(partId: null) cannot mean "clear it" — null is also "leave it
      // alone". Without the flags, tapping "All items" silently does nothing.
      const f = DplPalletFilter(partId: 7, machineId: 3);
      expect(f.copyWith(partId: null).partId, 7);
      expect(f.copyWith(clearPartId: true).partId, isNull);
      expect(f.copyWith(clearPartId: true).machineId, 3);
      expect(f.copyWith(clearMachineId: true).machineId, isNull);
    });

    test('dates go out as plain YYYY-MM-DD, not as an instant', () {
      // The server treats `to` as inclusive of that whole local day. Sending
      // an ISO instant would hand it a timezone to reinterpret, and "packed on
      // the 22nd" would start dropping the 22nd's night shift.
      final f = DplPalletFilter(
        from: DateTime(2026, 9, 1),
        to: DateTime(2026, 9, 22),
      );
      expect(f.toQuery()['from'], '2026-09-01');
      expect(f.toQuery()['to'], '2026-09-22');
    });

    test('empty filters are omitted from the query, not sent as blanks', () {
      const f = DplPalletFilter(search: '   ');
      final q = f.toQuery();
      expect(q['status'], isNull);
      expect(q['pallet_type'], isNull);
      expect(q['search'], isNull);
      expect(q['stale_half'], isNull);
      // Paging always goes, so the server never has to guess a default the
      // client also guesses.
      expect(q['limit'], 50);
      expect(q['offset'], 0);
    });

    test('isFiltered tells "nothing matches" apart from "nothing packed"', () {
      // The two need completely different reactions from the reader, so the
      // empty state must be able to tell them apart.
      expect(const DplPalletFilter().isFiltered, isFalse);
      expect(const DplPalletFilter(offset: 50).isFiltered, isFalse);
      expect(const DplPalletFilter(search: 'PM').isFiltered, isTrue);
      expect(const DplPalletFilter(staleHalfOnly: true).isFiltered, isTrue);
      expect(const DplPalletFilter(status: 'closed').activeCount, 1);
      expect(
        const DplPalletFilter(status: 'closed', palletType: 'H', partId: 2)
            .activeCount,
        3,
      );
    });

    test('a date range counts as ONE active filter, not two', () {
      // The count drives a "Clear (n)" button. Saying 2 when the operator set
      // one range makes them hunt for a filter that does not exist.
      final f = DplPalletFilter(
        from: DateTime(2026, 9, 1),
        to: DateTime(2026, 9, 22),
      );
      expect(f.activeCount, 1);
    });
  });

  group('DplPalletPage', () {
    test('hasMore is driven by the total, not by a full page', () {
      // A page that happens to come back exactly full is not proof there is
      // more; the total is.
      final page = DplPalletPage.fromJson({
        'pallets': [
          {'id': 1, 'pallet_no': 'P26000001'},
        ],
        'total': 231,
        'limit': 1,
        'offset': 0,
      });
      expect(page.hasMore, isTrue);
      expect(page.pallets.single.palletNo, 'P26000001');

      final last = DplPalletPage.fromJson({
        'pallets': [
          {'id': 1, 'pallet_no': 'P26000001'},
        ],
        'total': 1,
        'limit': 50,
        'offset': 0,
      });
      expect(last.hasMore, isFalse);
    });

    test('a missing list is an empty page, not a crash', () {
      final page = DplPalletPage.fromJson(const {});
      expect(page.pallets, isEmpty);
      expect(page.total, 0);
      expect(page.limit, 50);
    });
  });
}
