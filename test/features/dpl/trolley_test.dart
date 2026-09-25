import 'package:flutter_test/flutter_test.dart';

import 'package:productivity_tracker/features/dpl/core/dpl_constants.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_permissions_provider.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_pallet.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_spd.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_wheel_trolley.dart';
import 'package:productivity_tracker/features/dpl/qa/widgets/start_pallet_choice_sheet.dart';

void main() {
  group('the cart', () {
    test('a trolley decodes and names itself the way the floor does', () {
      final t = DplWheelTrolley.fromJson(const {
        'id': 5,
        'trolley_no': 'TR26000001',
        'name': 'Line 3 cart',
        'status': 'active',
        'wheel_qty': 14,
      });
      expect(t.id, 5);
      expect(t.wheelQty, 14);
      expect(t.isActive, isTrue);
      expect(t.isEmpty, isFalse);
      // The number is the identity; the nickname is what people say.
      expect(t.label, 'TR26000001 · Line 3 cart');
    });

    test('a cart with no nickname still has a name to show', () {
      const t = DplWheelTrolley(trolleyNo: 'TR26000002');
      expect(t.label, 'TR26000002');
    });

    test('a retired cart says so, so the picker can refuse it', () {
      final t = DplWheelTrolley.fromJson(const {
        'trolley_no': 'TR26000003',
        'status': 'retired',
      });
      expect(t.isActive, isFalse);
    });

    test('a missing field never throws — the screen must still render', () {
      final t = DplWheelTrolley.fromJson(const {});
      expect(t.trolleyNo, '');
      expect(t.wheelQty, 0);
      expect(t.isActive, isTrue, reason: 'active is the safe default');
    });
  });

  group('what is on it', () {
    test('an adopted wheel shows the RAW payload, not the stored hash', () {
      // The stored serial for an old label is a shortened hash that appears on
      // no physical sticker. A picker showing it gives the operator nothing to
      // match against what is in their hand, which is the entire job.
      const raw = '9042PBFP/std01//7/25Sep26/13:54:40/A/7';
      final w = DplTrolleyWheel.fromJson(const {
        'id': 12,
        'serial_no': raw,
        'source': 'external',
        'part_id': 3,
        'customer_part_no': '9042PBFP',
        'shift_code': 'A',
        'status': 'issued',
      });
      expect(w.serialNo, raw);
      expect(w.isExternal, isTrue);
      expect(w.isVoided, isFalse);
    });

    test('voided wheels are not offered for packing', () {
      final c = DplTrolleyContents.fromJson(const {
        'trolley': {'id': 5, 'trolley_no': 'TR26000001', 'wheel_qty': 2},
        'wheels': [
          {'id': 1, 'serial_no': 'GA2600000101', 'status': 'issued'},
          {'id': 2, 'serial_no': 'GA2600000102', 'status': 'voided'},
        ],
      });
      expect(c.wheels.length, 2);
      expect(c.packable.length, 1);
      expect(c.packable.single.id, 1);
      expect(c.trolley.trolleyNo, 'TR26000001');
    });
  });

  group('the plan', () {
    // Worked from the same case the service tests pin: 15 wheels of one item,
    // a standard of 48, and four half pallets waiting.
    final plan = DplTrolleyPlan.fromJson(const {
      'trolley': {'id': 5, 'trolley_no': 'TR26000001', 'wheel_qty': 15},
      'completes': 3,
      'leftover': 0,
      'items': [
        {
          'part_id': 3,
          'customer_part_no': 'W-1',
          'on_trolley': 15,
          'completes': 3,
          'age_days_retired': 33,
          'wheels_used': 15,
          'leftover': 0,
          'steps': [
            {
              'pallet_id': 89,
              'pallet_no': 'H26000012',
              'qty': 40,
              'standard_qty': 48,
              'need': 8,
              'age_days': 30,
              'take': 8,
            },
            {
              'pallet_id': 88,
              'pallet_no': 'H26000011',
              'qty': 45,
              'standard_qty': 48,
              'need': 3,
              'age_days': 2,
              'take': 3,
            },
          ],
          'ignored': [
            {
              'pallet_id': 90,
              'pallet_no': 'H26000013',
              'need': 28,
              'age_days': 45,
              'why': 'needs 28, more than the 15 of this item on the trolley',
            },
          ],
        },
      ],
    });

    test('it decodes the steps and how much each one takes', () {
      expect(plan.completes, 3);
      expect(plan.leftover, 0);
      expect(plan.hasWork, isTrue);

      final item = plan.items.single;
      expect(item.onTrolley, 15);
      expect(item.ageDaysRetired, 33);
      expect(item.steps.length, 2);
      expect(item.steps.first.palletNo, 'H26000012');
      expect(item.steps.first.take, 8);
      // take == need, always. A step that does not COMPLETE the pallet is not
      // suggested, because a half pallet only stops ageing when it fills.
      for (final s in item.steps) {
        expect(s.take, s.need);
      }
    });

    test('a pallet it cannot help is NAMED, with the reason', () {
      // Silence about the 45-day-old pallet would look like the system had not
      // noticed it. Naming it is an instruction to a supervisor.
      final skipped = plan.items.single.ignored.single;
      expect(skipped.palletNo, 'H26000013');
      expect(skipped.ageDays, 45);
      expect(skipped.isOld, isTrue);
      expect(skipped.why, contains('more than'));
    });

    test('old is old at a week, for the step and the skip alike', () {
      expect(
        const DplTrolleyPlanStep(ageDays: 7).isOld,
        isTrue,
      );
      expect(const DplTrolleyPlanStep(ageDays: 6).isOld, isFalse);
      expect(const DplTrolleyPlanSkipped(ageDays: 7).isOld, isTrue);
    });

    test('an empty cart is an empty plan, not a crash', () {
      final empty = DplTrolleyPlan.fromJson(const {});
      expect(empty.items, isEmpty);
      expect(empty.hasWork, isFalse);
      expect(empty.completes, 0);
    });
  });

  group('the merge result', () {
    test('it reports the rename, so the reprint is not a surprise', () {
      final r = DplTrolleyMergeResult.fromJson(const {
        'pallet': {'id': 88, 'pallet_no': 'PM26000012', 'qty': 48, 'standard_qty': 48},
        'trolley': {'id': 5, 'trolley_no': 'TR26000001', 'wheel_qty': 7},
        'moved': 8,
        'is_full': true,
        'renamed': {'from': 'H26000012', 'to': 'PM26000012'},
        'reprint': [88],
      });
      expect(r.moved, 8);
      expect(r.isFull, isTrue);
      expect(r.wasRenamed, isTrue);
      expect(r.renamedFrom, 'H26000012');
      expect(r.pallet.palletNo, 'PM26000012');
      expect(r.reprint, [88]);
      expect(r.trolley.wheelQty, 7, reason: 'the cart went down by what moved');
    });

    test('a pallet already on a merged series is not renamed', () {
      final r = DplTrolleyMergeResult.fromJson(const {
        'pallet': {'id': 88, 'pallet_no': 'M26000009'},
        'moved': 2,
        'renamed': null,
        'reprint': [88],
      });
      expect(r.wasRenamed, isFalse);
      expect(r.renamedFrom, '');
    });

    test('parking says whether the label was one of the old ones', () {
      // During the changeover the operator is holding two kinds of sticker,
      // and a silent acceptance looks identical either way.
      final r = DplTrolleyParkResult.fromJson(const {
        'trolley': {'id': 5, 'trolley_no': 'TR26000001', 'wheel_qty': 1},
        'serial_no': '9042PBFP/std01//1/25Sep26/13:54:40/A/1',
        'source': 'external',
      });
      expect(r.isExternal, isTrue);
      expect(r.trolley.wheelQty, 1);
    });
  });

  group('resolving a wheel that is already parked', () {
    test('it names the cart rather than staying silent', () {
      // pallet_id is NULL for a parked wheel, so without this the scan-to-start
      // screen would cheerfully offer to open a brand-new pallet for stock
      // somebody else is counting on a trolley.
      final r = DplWheelResolution.fromJson(const {
        'code': 'GA2600000147',
        'source': 'app',
        'part': {'id': 3, 'customer_part_no': 'W-1'},
        'trolley': {'id': 5, 'trolley_no': 'TR26000001', 'wheel_qty': 14},
      });
      expect(r.isOnTrolley, isTrue);
      expect(r.trolleyNo, 'TR26000001');
      expect(r.trolleyWheelQty, 14);
      expect(r.hasPart, isTrue, reason: 'it is still packable — just say so');
    });

    test('a free wheel says nothing about trolleys', () {
      final r = DplWheelResolution.fromJson(const {
        'code': 'GA2600000147',
        'part': {'id': 3, 'customer_part_no': 'W-1'},
      });
      expect(r.isOnTrolley, isFalse);
      expect(r.trolleyNo, '');
    });
  });

  group('the three-way start choice', () {
    test('production merge carries the half pallet it is filling', () {
      // Without it the caller has a choice and no idea what to act on, and
      // openPallet would open a fresh pallet instead of bringing one back.
      const half = DplPallet(id: 88, palletNo: 'H26000012', qty: 40);
      const d = DplStartDecision(DplStartKind.productionMerge, half: half);
      expect(d.kind, DplStartKind.productionMerge);
      expect(d.half?.palletNo, 'H26000012');
    });

    test('the other two carry nothing, because they need nothing', () {
      const a = DplStartDecision(DplStartKind.newPallet);
      const b = DplStartDecision(DplStartKind.trolley);
      expect(a.half, isNull);
      expect(b.half, isNull);
    });
  });

  group('access', () {
    test('the trolley is OFF until an administrator grants it', () {
      // The product rule: the existing DPL flow keeps working exactly as it
      // did, and every Maxion capability is a switch. A plant that has never
      // been given the trolley must never be offered a third choice when it
      // starts a pallet.
      final none = DplPermissions.of(const <String>[]);
      expect(none.can(DplPermission.palletTrolley), isFalse);

      const unknown = DplPermissions.unknown();
      expect(
        unknown.can(DplPermission.palletTrolley),
        isFalse,
        reason: '"could not read the permission list" is not a reason to show it',
      );

      final granted = DplPermissions.of(const ['pallet.trolley']);
      expect(granted.can(DplPermission.palletTrolley), isTrue);
    });

    test('it is its own key, separate from building and merging', () {
      // A plant that merges pallets has not thereby asked for a holding area,
      // and one that parks wheels is not thereby allowed to pack them.
      expect(DplPermission.palletTrolley, 'pallet.trolley');
      expect(DplPermission.palletTrolley, isNot(DplPermission.palletMerge));
      expect(DplPermission.palletTrolley, isNot(DplPermission.palletBuild));
    });
  });

  group('the endpoints', () {
    test('every trolley path is on the WAREHOUSE prefix', () {
      // NOT /qa. That router is role-locked to dpl_qa / dpl_supervisor /
      // dpl_manager before any permission is read, so a trolley endpoint there
      // could never be granted to a storeman however the grid is set — and
      // merging a cart into a rack pallet is a warehouse job at Maxion.
      for (final p in [
        DplPaths.warehouseTrolleys,
        DplPaths.warehouseTrolleyPark,
        DplPaths.warehouseTrolleyUnpark,
        DplPaths.warehouseTrolleyMerge,
        DplPaths.warehouseTrolleyById(5),
        DplPaths.warehouseTrolleyWheels(5),
        DplPaths.warehouseTrolleyPlan(5),
        DplPaths.warehouseTrolleyEmpty(5),
      ]) {
        expect(p, startsWith('/warehouse/'), reason: p);
      }
    });

    test('the literal paths cannot be swallowed by the :id routes', () {
      // Express 5 dropped ':id(\\d+)', so registration order is the only
      // defence on the server. These are the literals that must stay literal.
      expect(DplPaths.warehouseTrolleyPark, '/warehouse/trolleys/park');
      expect(DplPaths.warehouseTrolleyUnpark, '/warehouse/trolleys/unpark');
      expect(DplPaths.warehouseTrolleyMerge, '/warehouse/trolleys/merge');
      expect(DplPaths.warehouseTrolleyWheels(5), '/warehouse/trolleys/5/wheels');
      expect(DplPaths.warehouseTrolleyPlan(5), '/warehouse/trolleys/5/plan');
    });
  });

  group('the PM series', () {
    test('a production merge is labelled and QR-ed as itself', () {
      // PM is production wheels going into a stored half pallet; M is two
      // pallets consolidated in the warehouse. They shared the M series until
      // now, and a storeman could not tell which he was holding.
      final p = DplPallet.fromJson(const {
        'id': 88,
        'pallet_no': 'PM26000012',
        'pallet_type': 'PM',
        'qty': 48,
        'standard_qty': 48,
        'is_full': true,
      });
      expect(p.palletNo, 'PM26000012');
      expect(p.isFull, isTrue);

      // The label's QR carries the number and nothing else, so a two-letter
      // series has to survive it intact.
      final label = DplPalletSticker.fromJson(const {
        'pallet': {'id': 88, 'pallet_no': 'PM26000012', 'pallet_type': 'PM'},
      });
      expect(label.qrPayload, 'MWP|PM26000012');
    });
  });
}
