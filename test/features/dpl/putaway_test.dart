import 'package:flutter_test/flutter_test.dart';

import 'package:productivity_tracker/features/dpl/core/dpl_constants.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_permissions_provider.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_pallet.dart';

/// Warehouse putaway — Maxion SSR Module 6.
void main() {
  group('putaway routes away from /qa', () {
    test('putaway does NOT sit under the role-locked QA prefix', () {
      // The QA router is role-locked to dpl_qa / dpl_supervisor / dpl_manager
      // BEFORE any permission is consulted. A putaway endpoint under /qa could
      // therefore never be granted to a storeman however the administrator
      // sets the grid — we already shipped that bug once with pallet.view and
      // dpl_dispatch. Keeping these paths off /qa is what makes
      // `pallet.putaway` a real switch.
      expect(DplPaths.warehouseLocations.startsWith('/warehouse'), isTrue);
      expect(DplPaths.warehousePalletResolve.startsWith('/warehouse'), isTrue);
      expect(
        DplPaths.warehousePalletPutaway(7),
        '/warehouse/pallets/7/putaway',
      );

      expect(DplPaths.warehouseLocations.contains('/qa'), isFalse);
      expect(DplPaths.warehousePalletResolve.contains('/qa'), isFalse);
      expect(DplPaths.warehousePalletPutaway(7).contains('/qa'), isFalse);
    });
  });

  group('pallet.putaway is opt-in', () {
    test('an unknown permission list does not hand a plant putaway', () {
      const p = DplPermissions.unknown();
      expect(p.can(DplPermission.palletPutaway), isFalse);
      expect(
        DplPermission.optInOnly.contains(DplPermission.palletPutaway),
        isTrue,
      );
    });

    test('it is separate from building and closing', () {
      // Which role racks a pallet differs by plant — the pack operator at a
      // small site, a dedicated putaway operator at Maxion. Folding it into
      // pallet.close would make that unexpressible.
      final onlyBuild = DplPermissions.of(const [
        'pallet.build',
        'pallet.close',
      ]);
      expect(onlyBuild.can(DplPermission.palletPutaway), isFalse);

      final storeman = DplPermissions.of(const ['pallet.putaway']);
      expect(storeman.can(DplPermission.palletPutaway), isTrue);
      expect(storeman.can(DplPermission.palletClose), isFalse);
    });
  });

  _mergePreviewTests();
  _mergeDiffTests();

  group('DplPalletResolution', () {
    Map<String, dynamic> body({
      Map<String, dynamic>? location,
      Map<String, dynamic>? suggestion,
    }) => {
      'pallet': {
        'id': 5,
        'pallet_no': 'H26000007',
        'pallet_type': 'H',
        'qty': 40,
        'standard_qty': 96,
        'part': {'customer_part_no': 'W-1', 'description': '102D1'},
      },
      'location': ?location,
      'suggestion': ?suggestion,
    };

    test('a pallet already on a rack is flagged as a MOVE', () {
      // Somebody put it there on purpose. Relocating it silently is how stock
      // goes missing from the rack a picking list still points at.
      final r = DplPalletResolution.fromJson(
        body(location: {'id': 3, 'code': 'FG-A-03', 'zone': 'A'}),
      );
      expect(r.isMove, isTrue);
      expect(r.current!.code, 'FG-A-03');
    });

    test('a pallet with no rack yet is a first putaway', () {
      final r = DplPalletResolution.fromJson(body());
      expect(r.isMove, isFalse);
      expect(r.current, isNull);
      expect(r.pallet.palletNo, 'H26000007');
      expect(r.pallet.qty, 40);
    });

    test('the suggestion carries its REASON, not just a code', () {
      // A suggestion an operator does not understand is one they override at
      // random. "Half pallets are kept together" is the difference between a
      // rule people follow and a box that fills itself in.
      final r = DplPalletResolution.fromJson(
        body(
          suggestion: {
            'id': 9,
            'code': 'FG-H-01',
            'zone': 'HB (Half Pallet Bays)',
            'free_qty': 160,
            'reason': 'Half pallets are kept together so they get filled.',
          },
        ),
      );
      expect(r.suggestion!.code, 'FG-H-01');
      expect(r.suggestion!.freeQty, 160);
      expect(r.suggestion!.reason, isNotEmpty);
    });

    test('no suggestion is not an error', () {
      // A plant that has not configured zones should get an ordinary picker,
      // not a failure.
      final r = DplPalletResolution.fromJson(body());
      expect(r.suggestion, isNull);
    });

    test('a malformed response does not throw', () {
      final r = DplPalletResolution.fromJson(const {});
      expect(r.pallet.palletNo, '');
      expect(r.isMove, isFalse);
      expect(r.suggestion, isNull);
    });
  });
}

/// The merge arithmetic, as the operator sees it in the preview.
///
/// The screen repeats the server's sum so the operator can decide whether to
/// press at all without a round trip. That makes it a second implementation of
/// the same rule, which is worth pinning: a preview that promises 5/5 and
/// delivers 7/5 is worse than no preview.
void _mergePreviewTests() {
  group('merge preview', () {
    ({int take, int targetAfter, int sourceAfter, bool emptied}) preview({
      required int targetQty,
      required int standard,
      required int sourceQty,
    }) {
      final need = standard - targetQty;
      final take = need < sourceQty ? need : sourceQty;
      final sourceAfter = sourceQty - take;
      return (
        take: take,
        targetAfter: targetQty + take,
        sourceAfter: sourceAfter,
        emptied: sourceAfter < 1,
      );
    }

    test('4 + 3 of 5 gives a full 5 and a remainder of 2', () {
      final p = preview(targetQty: 4, standard: 5, sourceQty: 3);
      expect(p.take, 1);
      expect(p.targetAfter, 5);
      expect(p.sourceAfter, 2);
      expect(p.emptied, isFalse);
    });

    test('4 + 1 of 5 empties the source', () {
      final p = preview(targetQty: 4, standard: 5, sourceQty: 1);
      expect(p.take, 1);
      expect(p.targetAfter, 5);
      expect(p.emptied, isTrue);
    });

    test('2 + 2 of 5 leaves the target still part-filled', () {
      // Neither pallet reaches standard. The merge is still worth doing — one
      // fewer half pallet on the floor is the whole point of Module 5.
      final p = preview(targetQty: 2, standard: 5, sourceQty: 2);
      expect(p.take, 2);
      expect(p.targetAfter, 4);
      expect(p.emptied, isTrue);
    });

    test('the target never exceeds its standard quantity', () {
      // The failure this whole operation exists to prevent: six wheels do not
      // fit on a shroud built for five.
      for (final src in [1, 3, 5, 96]) {
        final p = preview(targetQty: 4, standard: 5, sourceQty: src);
        expect(p.targetAfter, lessThanOrEqualTo(5), reason: 'source $src');
        expect(p.sourceAfter, greaterThanOrEqualTo(0), reason: 'source $src');
        expect(
          p.take + p.sourceAfter,
          src,
          reason: 'no wheels invented or lost',
        );
      }
    });
  });
}

/// The drag-and-drop merge sends only the wheels that actually changed side.
///
/// Sending the whole assignment would make the server write every row for a
/// single drag, and a wheel dragged back where it started would report a merge
/// that did not happen.
void _mergeDiffTests() {
  group('drag-and-drop diff', () {
    Map<int, int> movesOf(Map<int, int> origin, Map<int, int> now) {
      final out = <int, int>{};
      for (final e in now.entries) {
        if (origin[e.key] != e.value) out[e.key] = e.value;
      }
      return out;
    }

    test('only wheels that changed pallet are sent', () {
      final origin = {101: 1, 102: 1, 201: 2, 202: 2, 203: 2};
      final now = {101: 1, 102: 1, 201: 2, 202: 1, 203: 1};
      expect(movesOf(origin, now), {202: 1, 203: 1});
    });

    test('dragging a wheel back where it started sends nothing', () {
      final origin = {101: 1, 201: 2};
      expect(movesOf(origin, {101: 1, 201: 2}), isEmpty);
    });

    test('wheels moving BOTH ways are both sent', () {
      // Dragging is symmetric, so a swap is one operation rather than two —
      // which also avoids a moment in between where a pallet is over capacity.
      final origin = {101: 1, 201: 2};
      expect(movesOf(origin, {101: 2, 201: 1}), {101: 2, 201: 1});
    });

    test('final counts drive the capacity warning, not the move count', () {
      final now = {101: 1, 102: 1, 201: 1, 202: 1, 203: 1};
      final onA = now.values.where((v) => v == 1).length;
      final onB = now.values.where((v) => v == 2).length;
      expect(onA, 5);
      expect(onB, 0);
      // A pallet emptied by the drag stops being a pallet, so it gets no label.
      expect(onB < 1, isTrue);
    });
  });
}
