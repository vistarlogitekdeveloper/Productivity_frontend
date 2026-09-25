import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_api_service.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_permissions_provider.dart';

/// What an administrator switches off must actually go away on the device.
///
/// This file pins the two things that broke that promise in UAT. Sanand JIT's
/// administrator turned "Print several labels at once" OFF for DPL QA, and the
/// operator's device carried on showing the Print labels tab, the quantity
/// field, and a button that failed with BATCH_PRINT_NOT_ALLOWED when pressed.
///
/// The cause was not the permission grid, which was correct throughout. It was
/// (1) `/auth/me` being parsed one level too shallow, so every refresh threw
/// the permission list away, and (2) an unknown list meaning "allow
/// everything", which turned that into a full grant of the Maxion feature set.

/// Returns a canned envelope for any request, so the real `me()` parsing runs
/// without a server. Cheaper and more honest than mocking DplApiService: the
/// bug lived in the `fromJson` closure, which a mocked service would skip.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.body);

  final Map<String, dynamic> body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

DplApiService _serviceReturning(Map<String, dynamic> body) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'))
    ..httpClientAdapter = _CannedAdapter(body);
  return DplApiService(dio);
}

void main() {
  group('/auth/me parsing', () {
    test('reads permissions out of the {user: ...} envelope', () async {
      // THE REGRESSION. `/auth/me` answers {success, data:{user:{...}}} and the
      // service is handed `data` — so parsing it directly as a user found no
      // `permissions` key, reported null, and the app fell back to permissive.
      final svc = _serviceReturning({
        'success': true,
        'data': {
          'user': {
            'id': 12,
            'name': 'QA Operator',
            'email': 'qa@example.com',
            'role': 'dpl_qa',
            'organization_id': 3,
            'permissions': ['labels.scan', 'labels.print'],
          },
        },
      });

      final res = await svc.me();
      expect(res.isError, isFalse);
      expect(res.data!.id, 12);
      expect(res.data!.role, 'dpl_qa');
      expect(res.data!.permissions, ['labels.scan', 'labels.print']);
    });

    test('an EMPTY permission list survives as empty, never as null', () async {
      // The difference decides whether the app hides everything (a real
      // denial) or shows everything (an unknown answer). Collapsing one into
      // the other is the whole bug.
      final svc = _serviceReturning({
        'success': true,
        'data': {
          'user': {'id': 1, 'role': 'dpl_qa', 'permissions': <String>[]},
        },
      });
      final res = await svc.me();
      expect(res.data!.permissions, isNotNull);
      expect(res.data!.permissions, isEmpty);
    });

    test('a genuinely old backend still reports null, not empty', () async {
      // No `permissions` key at all. That must stay null so the app falls back
      // to its role checks rather than blanking every screen.
      final svc = _serviceReturning({
        'success': true,
        'data': {
          'user': {'id': 1, 'role': 'dpl_qa'},
        },
      });
      final res = await svc.me();
      expect(res.data!.permissions, isNull);
    });

    test('an unwrapped user body is still understood', () async {
      // Tolerated on purpose: /login answers {token, user} and a future
      // endpoint may answer the user directly. Guessing wrong is expensive and
      // costs one type check to avoid.
      final svc = _serviceReturning({
        'success': true,
        'data': {
          'id': 9,
          'role': 'dpl_manager',
          'permissions': ['plans.view'],
        },
      });
      final res = await svc.me();
      expect(res.data!.id, 9);
      expect(res.data!.permissions, ['plans.view']);
    });
  });

  group('DplPermissions.can', () {
    test('a real grant is obeyed exactly', () {
      final p = DplPermissions.of(['labels.print', 'pallet.build']);
      expect(p.can(DplPermission.labelsPrint), isTrue);
      expect(p.can(DplPermission.palletBuild), isTrue);
      expect(p.can(DplPermission.labelsPrintBatch), isFalse);
      expect(p.can(DplPermission.palletMerge), isFalse);
    });

    test('an EMPTY grant denies everything, including the old capabilities', () {
      // An empty list is a real answer — "this person may do nothing" — and
      // must be obeyed, not mistaken for "no answer".
      final p = DplPermissions.of(const <String>[]);
      expect(p.can(DplPermission.labelsPrint), isFalse);
      expect(p.can(DplPermission.labelsPrintBatch), isFalse);
      expect(p.isKnown, isTrue);
    });

    test('UNKNOWN allows a pre-existing capability', () {
      // "Unknown" means "behave as this app did before permissions existed".
      // For something that was always there behind a role guard, that is
      // allow: an app that renders nothing the first time it meets an older
      // backend is the worse failure.
      const p = DplPermissions.unknown();
      expect(p.isKnown, isFalse);
      expect(p.can(DplPermission.labelsPrint), isTrue);
      expect(p.can(DplPermission.labelsScan), isTrue);
      expect(p.can(DplPermission.plansView), isTrue);
    });

    test('UNKNOWN DENIES every Maxion capability', () {
      // The heart of the product rule: the existing DPL flow keeps working
      // exactly as it did, and every Maxion capability is something an
      // administrator switches on per organization. A plant that was never
      // given one must never see it — and "the app could not read the
      // permission list" is not a reason to show it.
      //
      // Before this split, any moment the list went unknown — an older
      // backend, a failed /auth/me, a session cached from an earlier build —
      // handed the plant the entire Maxion feature set.
      const p = DplPermissions.unknown();
      for (final key in DplPermission.optInOnly) {
        expect(p.can(key), isFalse, reason: '$key must be denied when unknown');
      }
      expect(p.can(DplPermission.labelsPrintBatch), isFalse);
      expect(p.can(DplPermission.palletBuild), isFalse);
      expect(p.can(DplPermission.palletView), isFalse);
    });

    test('canAny and canAll follow the same split', () {
      const p = DplPermissions.unknown();
      // Mixed: the old key carries it.
      expect(
        p.canAny([DplPermission.labelsPrintBatch, DplPermission.labelsPrint]),
        isTrue,
      );
      // All-Maxion: nothing carries it.
      expect(
        p.canAny([DplPermission.palletBuild, DplPermission.palletMerge]),
        isFalse,
      );
      expect(
        p.canAll([DplPermission.labelsPrint, DplPermission.palletBuild]),
        isFalse,
      );
      expect(p.canAll([DplPermission.labelsPrint]), isTrue);
    });
  });

  group('the opt-in list itself', () {
    test('every opt-in key is a key the app actually checks', () {
      // A typo here is invisible at runtime: the key would simply never match
      // a granted permission, so the capability would be permanently denied
      // with nothing to point at.
      const known = <String>{
        DplPermission.labelsPrintBatch,
        DplPermission.palletView,
        DplPermission.palletBuild,
        DplPermission.palletClose,
        DplPermission.palletMerge,
        DplPermission.palletScanCamera,
        DplPermission.palletPutaway,
        DplPermission.palletSpd,
        DplPermission.labelsScanExternal,
        DplPermission.palletTrolley,
      };
      expect(DplPermission.optInOnly, known);
      for (final k in DplPermission.optInOnly) {
        expect(k.trim(), isNotEmpty);
        expect(k, contains('.'));
      }
    });

    test('the QA Slips tab stays visible when the list is unknown', () {
      // The tab predates every bit of the Maxion work, so it follows the
      // PRE-EXISTING rule, not the opt-in one: if /auth/me hiccups, an
      // operator must still have the screen they use every day. Putting
      // slips.qa_inbox into optInOnly would blank it out on a bad network.
      expect(
        DplPermission.optInOnly.contains(DplPermission.slipsQaInbox),
        isFalse,
        reason: 'it is a switch OFF, so unknown must mean visible',
      );
      const unknown = DplPermissions.unknown();
      expect(unknown.can(DplPermission.slipsQaInbox), isTrue);

      // But an explicit answer is obeyed in both directions — that is what
      // makes it a real switch rather than decoration.
      final off = DplPermissions.of(const <String>[]);
      expect(off.can(DplPermission.slipsQaInbox), isFalse);
      final on = DplPermissions.of(const ['slips.qa_inbox']);
      expect(on.can(DplPermission.slipsQaInbox), isTrue);
    });

    test('showing the Slips tab is a different question from seeing slips', () {
      // slips.view is dispatch-side data access and QA has never held it.
      // Collapsing the two would either hide a working screen or hand QA
      // access nobody asked for.
      expect(DplPermission.slipsQaInbox, 'slips.qa_inbox');
      expect(DplPermission.slipsQaInbox, isNot(DplPermission.slipsView));
    });

    test('no PRE-EXISTING DPL capability was swept into the opt-in list', () {
      // These shipped before the Maxion work and are guarded by role checks
      // that already existed. Denying them on an unknown list would blank out
      // screens people use today the first time /auth/me hiccups.
      for (final k in [
        DplPermission.plansView,
        DplPermission.labelsScan,
        DplPermission.labelsPrint,
        DplPermission.labelsVoid,
        DplPermission.labelsAssignLocation,
        DplPermission.tripsView,
      ]) {
        expect(
          DplPermission.optInOnly.contains(k),
          isFalse,
          reason: '$k predates the Maxion work and must stay permissive',
        );
      }
    });
  });
}
