import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_api_response.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_permissions_provider.dart';
import 'package:productivity_tracker/features/dpl/maxion/maxion_tools_screen.dart';
import 'package:productivity_tracker/features/dpl/maxion/sync/offline_outbox.dart';
import 'package:productivity_tracker/features/dpl/maxion/sync/offline_scan.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_trip_label_scan.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// This build must be safe against a backend WITHOUT the Maxion migrations
/// (159–164) — production until it is deployed there — while plants use DPL
/// live. Such a backend grants only the keys it knows, so a user there holds
/// some subset of [_prodCatalogue] and nothing else.
///
/// [_prodCatalogue] is the whole DPL permission catalogue on the `release`
/// branch of vistar_CRM (src/modules/dpl/config/permissions.js) as of
/// 2026-09-26, i.e. the most any role can hold on that backend.
const _prodCatalogue = <String>[
  'admin.users.view',
  'admin.users.manage',
  'admin.orgs.view',
  'admin.orgs.manage',
  'admin.permissions.manage',
  'admin.audit.view',
  'masters.view',
  'masters.edit',
  'masters.locations.edit',
  'plans.view',
  'plans.create',
  'plans.edit',
  'plans.delete',
  'plans.lock',
  'plans.execute',
  'labels.scan',
  'labels.print',
  'labels.print_batch',
  'labels.void',
  'labels.scan_external',
  'labels.assign_location',
  'pallet.view',
  'pallet.build',
  'pallet.close',
  'pallet.scan_camera',
  'pallet.spd',
  'pallet.putaway',
  'pallet.merge',
  'pallet.trolley',
  'trips.view',
  'trips.create',
  'trips.cancel',
  'trips.assign_driver',
  'trips.scan_labels',
  'slips.view',
  'slips.qa_inbox',
  'slips.create',
  'slips.deo',
  'slips.pdi',
  'slips.dispatch',
  'journey.gate',
  'journey.customer',
  'journey.drive',
  'summary.view',
  'reports.view',
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('against a backend without the Maxion migrations', () {
    test('no Maxion key is in the old catalogue (so "none granted" identifies it)', () {
      expect(_prodCatalogue.toSet().intersection(DplPermission.maxionKeys.toSet()), isEmpty);
    });

    test('even holding EVERY old key — masters.view included — shows no Tools entry', () {
      final all = DplPermissions.of(_prodCatalogue);
      expect(all.can(DplPermission.mastersView), isTrue, reason: 'the key the masters tile uses');
      expect(visibleMaxionTools(all), isEmpty);
      expect(hasAnyMaxionTool(all), isFalse);
    });

    test('unknown permissions (older backend, failed /auth/me) show no Tools entry', () {
      expect(hasAnyMaxionTool(const DplPermissions.unknown()), isFalse);
    });

    test('once a Maxion key is granted, the masters tile appears alongside it', () {
      final maxion = DplPermissions.of([..._prodCatalogue, DplPermission.reportsStock]);
      expect(
        visibleMaxionTools(maxion).map((t) => t.title),
        containsAll(['OEM dashboard', 'Transporters, consignees & lanes']),
      );
    });

    test('a dropped connection during a pallet scan is NOT queued: the operator sees the error, as before', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final outbox = container.read(dplOfflineOutboxProvider.notifier);
      var calls = 0;
      final res = await runOnlineOrQueue<Object>(
        outbox: outbox,
        canQueue: DplPermissions.of(_prodCatalogue).can(DplPermission.syncPush),
        type: 'pallet.scan',
        payload: {'pallet_id': 1, 'code': 'W1'},
        userId: 7,
        online: () async {
          calls++;
          return DplApiResponse<Object>.error('No connection', code: 'NETWORK');
        },
      );
      expect(calls, 1, reason: 'the live endpoint is still called exactly once');
      expect(res.isRefused, isTrue);
      expect(res.response!.code, 'NETWORK');
      await outbox.ready();
      expect(outbox.pending, 0, reason: 'nothing stranded in a queue that backend cannot accept');
    });

    test('a trip scan answer without "pallets" parses exactly as before', () {
      final p = DplTripScanProgress.fromJson({'trip_id': 4, 'plans': [], 'is_complete': true});
      expect(p.pallets, isEmpty);
      expect(p.isComplete, isTrue);
    });

    test('a refusal without message_local is shown word for word', () {
      final r = DplApiResponse<Object>.error('Already on trip #4', code: 'ALREADY_ON_TRIP');
      expect(r.errorLocal, isNull);
      expect(r.floorMessage, 'Already on trip #4');
    });
  });
}
