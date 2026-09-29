import 'package:flutter_test/flutter_test.dart';

import 'package:productivity_tracker/core/constants/app_constants.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_constants.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_permissions_provider.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_pallet_audit.dart';

/// Pallet audit — backend migration 167.
///
/// The auditor scans a pallet label, then every wheel on it. What this file
/// pins is the arithmetic the screen does locally, because the screen is what
/// decides whether the Approve button is even offered — and an Approve button
/// on a pallet with two wheels missing is how a bad pallet gets signed off.
void main() {
  DplAuditWheel wheel(String serial, {String source = 'app'}) => DplAuditWheel(
        stickerId: serial.hashCode.abs() % 10000,
        serialNo: serial,
        source: source,
      );

  DplPalletAuditLine line(String serial, String outcome, {int? foundOn}) =>
      DplPalletAuditLine(
        id: serial.hashCode.abs() % 10000,
        serialNo: serial,
        outcome: outcome,
        foundOnPalletId: foundOn,
      );

  DplPalletAuditSession session({
    required List<DplAuditWheel> wheels,
    required List<DplPalletAuditLine> lines,
    String status = 'in_progress',
  }) =>
      DplPalletAuditSession(
        audit: DplPalletAudit(
          id: 55,
          palletId: 1,
          status: status,
          expectedQty: wheels.length,
        ),
        wheels: wheels,
        lines: lines,
      );

  group('the set comparison', () {
    test('everything scanned leaves nothing outstanding', () {
      final s = session(
        wheels: [wheel('GA2600000001'), wheel('GA2600000002')],
        lines: [
          line('GA2600000001', 'matched'),
          line('GA2600000002', 'matched'),
        ],
      );

      expect(s.notYetScanned, isEmpty);
      expect(s.foreign, isEmpty);
      expect(s.matchedCount, 2);
    });

    test('THE HEADLINE CASE: 10 expected, 8 right, 2 missing, 2 foreign', () {
      // Ten scans against an expected ten. A COUNT passes this pallet; the set
      // comparison shows four wheels in the wrong place, which is the entire
      // reason the audit exists.
      final wheels = List.generate(10, (i) => wheel('GA26000000$i'));
      final lines = [
        for (var i = 0; i < 8; i++) line('GA26000000$i', 'matched'),
        line('GA2600000088', 'foreign', foundOn: 140),
        line('GA2600000091', 'foreign', foundOn: 140),
      ];

      final s = session(wheels: wheels, lines: lines);

      expect(s.lines.length, 10, reason: 'ten scans — a counter would be satisfied');
      expect(s.matchedCount, 8);
      expect(s.foreign.length, 2);
      expect(
        s.notYetScanned.map((w) => w.serialNo).toList(),
        ['GA260000008', 'GA260000009'],
      );
    });

    test('a foreign wheel does not tick off a missing one', () {
      // The trap a count falls into: one scanned, one expected, zero matched.
      final s = session(
        wheels: [wheel('GA2600000001')],
        lines: [line('GA2600000099', 'foreign', foundOn: 7)],
      );

      expect(s.lines.length, 1);
      expect(s.matchedCount, 0);
      expect(s.notYetScanned.length, 1, reason: 'the real wheel is still outstanding');
      expect(s.foreign.length, 1);
    });

    test('matching ignores case and stray whitespace', () {
      // A wedge scanner can deliver a trailing return or a lower-case payload.
      // The server compares case-insensitively; the screen must agree, or a
      // wheel reads as outstanding on screen and matched on the server.
      final s = session(
        wheels: [wheel('GA2600000001')],
        lines: [line(' ga2600000001 ', 'matched')],
      );

      expect(s.notYetScanned, isEmpty);
    });

    test('an adopted wheel is tracked by the code printed on it', () {
      // Our serial for an adopted wheel is a hash that is on no physical
      // sticker. The list shows the supplier's code, and that is what gets
      // scanned.
      final s = session(
        wheels: [wheel('MW-OEM-55512', source: 'external')],
        lines: [line('MW-OEM-55512', 'matched')],
      );

      expect(s.wheels.single.isExternal, isTrue);
      expect(s.notYetScanned, isEmpty);
    });

    test('an empty pallet has nothing outstanding', () {
      final s = session(wheels: const [], lines: const []);
      expect(s.notYetScanned, isEmpty);
      expect(s.foreign, isEmpty);
    });
  });

  group('the verdict', () {
    test('clean means nothing missing AND nothing foreign', () {
      const clean = DplPalletAudit(
        id: 1, palletId: 1, expectedQty: 10, matchedQty: 10,
        missingQty: 0, foreignQty: 0,
      );
      expect(clean.isClean, isTrue);

      const missing = DplPalletAudit(
        id: 1, palletId: 1, expectedQty: 10, matchedQty: 8, missingQty: 2,
      );
      expect(missing.isClean, isFalse);

      // The one a count would miss: every wheel accounted for, two strangers.
      const strangers = DplPalletAudit(
        id: 1, palletId: 1, expectedQty: 10, matchedQty: 10, foreignQty: 2,
      );
      expect(strangers.isClean, isFalse);
    });

    test('status helpers read the server value, not a local guess', () {
      const a = DplPalletAudit(id: 1, palletId: 1, status: 'approved');
      const r = DplPalletAudit(id: 1, palletId: 1, status: 'rejected');
      const o = DplPalletAudit(id: 1, palletId: 1, status: 'in_progress');

      expect(a.isApproved, isTrue);
      expect(r.isRejected, isTrue);
      expect(o.isOpen, isTrue);
      expect(o.isApproved, isFalse);
    });
  });

  group('parsing what the server sends', () {
    test('a whole session round-trips', () {
      final s = DplPalletAuditSession.fromJson({
        'audit': {
          'id': 55,
          'pallet_id': 1,
          'status': 'in_progress',
          'expected_qty': 2,
          'matched_qty': 1,
          'missing_qty': 0,
          'foreign_qty': 1,
        },
        'pallet': {
          'id': 1,
          'pallet_no': 'P26000141',
          'pallet_type': 'P',
          'status': 'closed',
          'qty': 2,
          'customer_part_no': '18663',
        },
        'wheels': [
          {'sticker_id': 9, 'serial_no': 'GA2600000001', 'source': 'app'},
          {'sticker_id': 10, 'serial_no': 'GA2600000002', 'source': 'app'},
        ],
        'lines': [
          {'id': 1, 'serial_no': 'GA2600000001', 'outcome': 'matched'},
          {
            'id': 2,
            'serial_no': 'GA2600000088',
            'outcome': 'foreign',
            'found_on_pallet_id': 140,
          },
        ],
      });

      expect(s.audit.id, 55);
      expect(s.pallet!.palletNo, 'P26000141');
      expect(s.wheels.length, 2);
      expect(s.lines.length, 2);
      expect(s.foreign.single.foundOnPalletId, 140);
      expect(s.notYetScanned.single.serialNo, 'GA2600000002');
    });

    test('a malformed body does not throw', () {
      // A screen that crashes on a bad response is worse than one that shows
      // an empty audit and lets the auditor retry.
      final s = DplPalletAuditSession.fromJson(const {});
      expect(s.wheels, isEmpty);
      expect(s.lines, isEmpty);
      expect(s.pallet, isNull);
    });

    test('a foreign wheel with no home parses as null, not zero', () {
      // 0 would read as "pallet zero" in the UI. Null means "not a label this
      // system printed", which is a different and more alarming finding.
      final l = DplPalletAuditLine.fromJson(const {
        'id': 3,
        'serial_no': 'SOMEBODY-ELSES',
        'outcome': 'foreign',
        'found_on_pallet_id': null,
      });
      expect(l.foundOnPalletId, isNull);
      expect(l.isForeign, isTrue);
    });
  });

  group('the auditor role and its permissions', () {
    test('the role exists and is named', () {
      expect(AppConstants.roleDplAuditor, 'DPL_AUDITOR');
      expect(AppConstants.isDplAuditorRole('DPL_AUDITOR'), isTrue);
      expect(AppConstants.isDplAuditorRole('dpl_auditor'), isTrue,
          reason: 'the backend enum is lower case');
      expect(AppConstants.roleLabel('DPL_AUDITOR'), 'DPL Auditor');
      expect(AppConstants.isDplAuditorRole('DPL_QA'), isFalse);
    });

    test('auditing is OPT-IN, like every other Maxion capability', () {
      // The product rule: the existing DPL flow keeps working exactly as it
      // did, and an administrator turns each Maxion capability on per
      // organization. An auditor arriving with these already granted would
      // hand the pallet register to every plant that never asked for it.
      const unknown = DplPermissions.unknown();
      expect(unknown.can(DplPermission.palletAuditView), isFalse);
      expect(unknown.can(DplPermission.palletAuditPerform), isFalse);

      expect(
        DplPermission.optInOnly.contains(DplPermission.palletAuditView),
        isTrue,
      );
      expect(
        DplPermission.optInOnly.contains(DplPermission.palletAuditPerform),
        isTrue,
      );
    });

    test('the two keys are separate jobs', () {
      // A supervisor can be given the register without being able to pass or
      // fail a pallet. Collapsing them would mean anyone who could look could
      // also sign off.
      final viewer = DplPermissions.of(const ['audit.view']);
      expect(viewer.can(DplPermission.palletAuditView), isTrue);
      expect(viewer.can(DplPermission.palletAuditPerform), isFalse);
    });

    test('the keys match the backend exactly', () {
      // A typo here is invisible at runtime: the key would never match a
      // granted permission, so the capability would be permanently denied with
      // nothing to point at.
      expect(DplPermission.palletAuditView, 'audit.view');
      expect(DplPermission.palletAuditPerform, 'audit.perform');
      // NOT the administrator's own audit log, which is a different screen.
      expect(DplPermission.palletAuditView, isNot(DplPermission.auditView));
      expect(DplPermission.auditView, 'admin.audit.view');
    });
  });

  group('the endpoints are reachable by a non-QA role', () {
    test('every audit path is on /warehouse, never /qa', () {
      // THE TRAP THIS AVOIDS: qaRoutes applies requireRole('dpl_qa',
      // 'dpl_supervisor', 'dpl_manager') to its WHOLE router BEFORE any
      // permission is consulted. An audit endpoint under /qa could never be
      // reached by dpl_auditor however the administrator sets the grid — the
      // permission would read as granted and every screen would still 403.
      final paths = <String>[
        DplPaths.warehouseAudits,
        DplPaths.warehouseAudit(7),
        DplPaths.warehouseAuditScan(7),
        DplPaths.warehouseAuditScanLine(7, 9),
        DplPaths.warehouseAuditDecide(7),
        DplPaths.warehouseAuditAbandon(7),
        DplPaths.warehousePallets,
        DplPaths.warehousePalletWheels(7),
      ];

      for (final p in paths) {
        expect(p.startsWith('/warehouse'), isTrue, reason: '$p must be on /warehouse');
        expect(p.contains('/qa'), isFalse, reason: '$p must not touch /qa');
      }
    });

    test('the paths are built the way the routes expect', () {
      expect(DplPaths.warehouseAudit(7), '/warehouse/audits/7');
      expect(DplPaths.warehouseAuditScan(7), '/warehouse/audits/7/scan');
      expect(DplPaths.warehouseAuditScanLine(7, 9), '/warehouse/audits/7/scan/9');
      expect(DplPaths.warehouseAuditDecide(7), '/warehouse/audits/7/decide');
      expect(DplPaths.warehousePalletWheels(7), '/warehouse/pallets/7/wheels');
    });
  });
}
