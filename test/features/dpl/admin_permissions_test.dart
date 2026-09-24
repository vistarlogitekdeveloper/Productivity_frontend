import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_permissions_provider.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_admin.dart';

/// The Administration panel decides what to SHOW from these two types. The
/// server decides what to ALLOW, on every request — so the failure mode these
/// tests guard against is a screen that renders nothing, or a screen that
/// claims a save it never made.
void main() {
  _batchPrintingTests();
  group('DplPermissions', () {
    test('an unknown set permits everything so screens fall back to roles', () {
      // The bug this pins: treating "the server said nothing" as "the user may
      // do nothing" blanks out every screen the first time the app meets a
      // backend older than migration 148.
      const p = DplPermissions.unknown();
      expect(p.isKnown, isFalse);
      expect(p.can('labels.print'), isTrue);
      expect(p.can('anything.at.all'), isTrue);
      expect(p.canAny(const ['a', 'b']), isTrue);
      expect(p.canAll(const ['a', 'b']), isTrue);
    });

    test('an EMPTY set is a real denial, not an unknown', () {
      // The distinction the whole type exists for. An empty list came from the
      // server and must be obeyed; a null one did not.
      final p = DplPermissions.of(const []);
      expect(p.isKnown, isTrue);
      expect(p.can('labels.print'), isFalse);
      expect(p.canAny(const ['labels.print']), isFalse);
    });

    test('granted keys are honoured exactly', () {
      final p = DplPermissions.of(const ['labels.print', 'plans.view']);
      expect(p.can('labels.print'), isTrue);
      expect(p.can('labels.void'), isFalse);
      expect(p.canAny(const ['labels.void', 'plans.view']), isTrue);
      expect(p.canAll(const ['labels.void', 'plans.view']), isFalse);
      expect(p.canAll(const ['labels.print', 'plans.view']), isTrue);
    });

    test('the keys the app checks are spelled as the backend spells them', () {
      // Every constant must match a key in src/modules/dpl/config/permissions.js.
      // A typo here is silent: the key is simply never granted, and the control
      // it guards never appears.
      const keys = <String>[
        DplPermission.usersView,
        DplPermission.usersManage,
        DplPermission.orgsView,
        DplPermission.orgsManage,
        DplPermission.permissionsManage,
        DplPermission.auditView,
        DplPermission.labelsPrint,
        DplPermission.plansExecute,
      ];
      for (final k in keys) {
        expect(k, matches(RegExp(r'^[a-z]+(\.[a-z_]+)+$')), reason: k);
      }
      expect(DplPermission.usersManage, 'admin.users.manage');
      expect(DplPermission.labelsPrint, 'labels.print');
      expect(DplPermission.adminPanel, contains(DplPermission.usersView));
    });
  });

  group('DplPermissionMatrix', () {
    DplPermissionMatrix build() => DplPermissionMatrix.fromJson({
          'organization_id': 1,
          'roles': [
            {'key': 'dpl_qa', 'label': 'DPL QA', 'description': 'Scans and prints.'},
          ],
          'permission_groups': [
            {
              'key': 'labels',
              'label': 'Labels',
              'permissions': [
                {'key': 'labels.print', 'label': 'Print labels', 'description': 'x'},
                {'key': 'labels.void', 'label': 'Void labels', 'description': 'y'},
              ],
            },
          ],
          'grants': {
            'dpl_qa': {
              'labels.print': {
                'allowed': true,
                'is_default': true,
                'is_override': false,
                'locked': false,
              },
              // Denied by default and never overridden, so `allowed` and
              // `is_default` agree. They can only disagree where an
              // administrator has overridden the cell, and then `is_override`
              // is true — a row saying otherwise would be incoherent data.
              'labels.void': {
                'allowed': false,
                'is_default': false,
                'is_override': false,
                'locked': false,
              },
            },
          },
        });

    test('parses the grid', () {
      final m = build();
      expect(m.organizationId, 1);
      expect(m.roles.single.label, 'DPL QA');
      expect(m.groups.single.permissions.length, 2);
      expect(m.cell('dpl_qa', 'labels.print').allowed, isTrue);
      expect(m.cell('dpl_qa', 'labels.void').allowed, isFalse);
    });

    test('an unknown cell reads as denied rather than throwing', () {
      // A client newer than the server will ask about keys the grid has never
      // heard of. That must render as "off", not crash the tab.
      final m = build();
      expect(m.cell('dpl_qa', 'not.a.key').allowed, isFalse);
      expect(m.cell('no_such_role', 'labels.print').allowed, isFalse);
    });

    test('flipping a cell marks it as an override immediately', () {
      // An unsaved change that looks identical to an inherited default is how
      // somebody closes the screen believing they saved something.
      final m = build().withCell('dpl_qa', 'labels.void', true);
      final cell = m.cell('dpl_qa', 'labels.void');
      expect(cell.allowed, isTrue);
      expect(
        cell.isDefault,
        isFalse,
        reason: 'the built-in default is untouched by an edit',
      );
      expect(cell.isOverride, isTrue);
      expect(m.overrideCountFor('dpl_qa'), 1);
    });

    test('flipping a cell back to its default stops being an override', () {
      final m = build()
          .withCell('dpl_qa', 'labels.void', true)
          .withCell('dpl_qa', 'labels.void', false);
      expect(m.cell('dpl_qa', 'labels.void').isOverride, isFalse);
      expect(m.overrideCountFor('dpl_qa'), 0);
    });

    test('withCell does not mutate the matrix it was called on', () {
      // The screen holds the server's copy and an edit buffer. If withCell
      // mutated in place, "discard" would have nothing to go back to.
      final original = build();
      original.withCell('dpl_qa', 'labels.void', true);
      expect(original.cell('dpl_qa', 'labels.void').allowed, isFalse);
      expect(original.overrideCountFor('dpl_qa'), 0);
    });
  });

  group('DplManagedUser', () {
    test('parses an account and its organization', () {
      final u = DplManagedUser.fromJson({
        'id': 7,
        'organization_id': 2,
        'name': 'Ramesh Patel',
        'email': 'ramesh@vistarlogitek.com',
        'employee_code': 'DPL-Q-002',
        'role': 'dpl_qa',
        'is_active': true,
        'must_change_password': true,
        'organization': {'id': 2, 'code': 'SANAND_JIT', 'name': 'Sanand JIT'},
      });
      expect(u.organizationLabel, 'Sanand JIT');
      expect(u.mustChangePassword, isTrue);
      expect(u.hasNeverLoggedIn, isTrue);
    });

    test('a missing organization block still renders a label', () {
      final u = DplManagedUser.fromJson({'id': 1, 'organization_id': 4});
      expect(u.organizationLabel, 'Org #4');
    });

    test('the create body carries the password, the update body never does', () {
      // Passwords have their own endpoint on purpose: "rename this person" and
      // "change their password" must not be the same accidental save.
      const u = DplManagedUser(
        organizationId: 1,
        name: 'A B',
        email: 'a@b.com',
        role: 'dpl_qa',
      );
      expect(u.toCreateJson(password: 'secret123')['password'], 'secret123');
      expect(u.toUpdateJson().containsKey('password'), isFalse);
      expect(u.toUpdateJson().containsKey('is_active'), isFalse);
    });

    test('a blank employee code is sent as null, not as an empty string', () {
      // The backend's uniqueness index is partial (WHERE employee_code IS NOT
      // NULL). Sending '' would make every code-less user collide with every
      // other one.
      const u = DplManagedUser(
        organizationId: 1,
        name: 'A B',
        email: 'a@b.com',
        role: 'dpl_qa',
        employeeCode: '   ',
      );
      expect(u.toUpdateJson()['employee_code'], isNull);
    });
  });

  group('DplUserAuditEntry', () {
    test('summarises a field change in plain language', () {
      final e = DplUserAuditEntry.fromJson({
        'action': 'role_changed',
        'changes': {
          'role': {'from': 'dpl_qa', 'to': 'dpl_manager'},
        },
      });
      expect(e.actionLabel, 'Role changed');
      expect(e.changeSummary, 'role: dpl_qa to dpl_manager');
    });

    test('summarises a permission change by counts, not by listing 34 keys', () {
      final e = DplUserAuditEntry.fromJson({
        'action': 'permissions_changed',
        'changes': {
          'role': 'dpl_qa',
          'permissions': {
            'labels.void': {'from': true, 'to': false},
            'plans.view': {'from': false, 'to': true},
          },
        },
      });
      expect(e.changeSummary, contains('dpl_qa'));
      expect(e.changeSummary, contains('+1 granted'));
      expect(e.changeSummary, contains('-1 revoked'));
    });

    test('a password reset says nothing about the password', () {
      // There is nothing to record here that is not either obvious or secret.
      final e = DplUserAuditEntry.fromJson({
        'action': 'password_reset',
        'changes': null,
      });
      expect(e.actionLabel, 'Password reset');
      expect(e.changeSummary, isEmpty);
    });
  });
}

// ---------------------------------------------------------------------------
// Per-organization batch label printing
// ---------------------------------------------------------------------------

void _batchPrintingTests() {
  group('batch label printing', () {
    test('the key matches what the backend catalogue calls it', () {
      // A mismatch here is silent: the key is simply never granted, the
      // quantity field never appears, and nothing in the UI says why.
      expect(DplPermission.labelsPrintBatch, 'labels.print_batch');
      expect(DplPermission.labelsPrint, 'labels.print');
      expect(
        DplPermission.labelsPrintBatch,
        isNot(DplPermission.labelsPrint),
        reason: 'printing and batch-printing must be grantable separately',
      );
    });

    test('an organization without the grant does NOT get the quantity field', () {
      // Batch printing is granted by DEFAULT now (SSR v3.0 §5.2 — "one at a
      // time, or a full pallet worth in one go"), so reaching this state takes
      // a deliberate administrator action: unticking the box for a plant that
      // wants strict print-one-stick-one. This pins that the restriction still
      // works when someone does that.
      final qa = DplPermissions.of(const [
        'labels.scan',
        'labels.print',
        'labels.assign_location',
      ]);
      expect(qa.can(DplPermission.labelsPrint), isTrue);
      expect(qa.can(DplPermission.labelsPrintBatch), isFalse);
    });

    test('an organization WITH the grant gets it', () {
      final maxion = DplPermissions.of(const [
        'labels.scan',
        'labels.print',
        'labels.print_batch',
      ]);
      expect(maxion.can(DplPermission.labelsPrintBatch), isTrue);
    });

    test('granting batch without plain print is still coherent', () {
      // The grid allows any combination, so the screen must not assume one
      // implies the other. The server gates the issue endpoint on the count,
      // so this reads as "may print batches" and nothing more.
      final odd = DplPermissions.of(const ['labels.print_batch']);
      expect(odd.can(DplPermission.labelsPrint), isFalse);
      expect(odd.can(DplPermission.labelsPrintBatch), isTrue);
    });

    test('an unknown permission set does not silently enable batching', () {
      // This test once asserted the opposite, on the reasoning that `can` is
      // permissive when unknown so older backends still render, and that the
      // server would refuse the batch anyway with BATCH_PRINT_NOT_ALLOWED.
      //
      // That reasoning was wrong in practice and Sanand JIT proved it. Their
      // administrator turned batch printing OFF; the operator's device kept
      // showing the Print labels tab and the quantity field, and pressing the
      // button produced a refusal the operator could do nothing about. "The
      // server will refuse it" is not a design — it is an error message where
      // a hidden control should have been.
      //
      // `unknown` still means "behave as this app did before permissions
      // existed". For batch printing, which did not exist then, behaving as
      // before means NOT offering it. See DplPermission.optInOnly.
      const unknown = DplPermissions.unknown();
      expect(unknown.isKnown, isFalse);
      expect(unknown.can(DplPermission.labelsPrintBatch), isFalse);
      // The pre-existing capabilities are untouched by that change: an older
      // backend must still render the screens people use today.
      expect(unknown.can(DplPermission.labelsPrint), isTrue);
      expect(unknown.can(DplPermission.labelsScan), isTrue);
    });
  });
}
