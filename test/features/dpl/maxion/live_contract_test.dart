// Contract test: the APP's DplApiService against a REAL DPL backend.
//
// Every other Maxion test here feeds canned JSON, which proves the app parses
// what we THINK the server sends. This one proves it parses what the server
// actually sends: the backend's end-to-end run seeds a full Maxion day (labels
// → pallets → trips → gate pass → dispatch → reversal → returns → counts →
// opening stock), then keeps the server up and writes its tokens and ids to a
// file, and each call below goes through the real app service with the real
// role's login.
//
// Skipped unless DPL_LIVE_STATE names that file:
//   (backend)  DPL_IT_DATABASE_URL=postgres://localhost/vx_parity DB_SSL=false \
//              DPL_E2E_KEEP=/tmp/dpl-live.json node scripts/dpl-maxion-e2e.js
//   (app)      DPL_LIVE_STATE=/tmp/dpl-live.json flutter test test/features/dpl/maxion/live_contract_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_api_service.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_sync.dart';

void main() {
  final path = Platform.environment['DPL_LIVE_STATE'];
  final skip = path == null || !File(path).existsSync() ? 'set DPL_LIVE_STATE to a live backend state file' : null;
  late Map<String, dynamic> state;

  DplApiService as(String role, {String? lang}) {
    final token = (state['tokens'] as Map)[role] as String;
    final dio = Dio(BaseOptions(baseUrl: state['base'] as String, headers: {
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      'X-App-Language': ?lang,
    }));
    return DplApiService(dio);
  }

  setUpAll(() {
    if (skip != null) return;
    state = jsonDecode(File(path!).readAsStringSync()) as Map<String, dynamic>;
  });

  group('live backend contract', () {
    test('OEM dashboard parses, with the seeded lane', () async {
      final res = await as('dpl_manager').getOemDashboard();
      expect(res.isOk, isTrue, reason: res.error);
      expect(res.data!.lanes.map((l) => l.plantCode), contains(state['lane']));
      expect(res.data!.attention.containsKey('returns_open'), isTrue);
    }, skip: skip);

    test('every tabular report parses rows and totals, and Excel downloads', () async {
      final api = as('dpl_manager');
      const reports = {
        'fg-stock': 'items',
        'stock-by-location': 'locations',
        'dispatch-register': 'lines',
        'half-pallet-ageing': 'pallets',
        'label-reconciliation': 'groups',
        'returns-register': 'lines',
        'stock-movements': 'lines',
      };
      for (final e in reports.entries) {
        final res = await api.getReportTable(e.key, e.value);
        expect(res.isOk, isTrue, reason: '${e.key}: ${res.error}');
        expect(res.data!.totals, isNotEmpty, reason: e.key);
      }
      final fg = await api.getReportTable('fg-stock', 'items');
      expect(fg.data!.rows.first['part_id'], state['part']);
      final xlsx = await api.getReportXlsx('dispatch-register');
      expect(xlsx.isOk, isTrue, reason: xlsx.error);
      expect(String.fromCharCodes(xlsx.data!.take(2)), 'PK');
    }, skip: skip);

    test('masters and lanes parse; a QA user is refused lane edits', () async {
      final mgr = as('dpl_manager');
      final t = await mgr.listTransporters(includeInactive: true);
      expect(t.isOk, isTrue, reason: t.error);
      expect(t.data!.map((x) => x.code), contains('TCI'));
      final c = await mgr.listConsignees();
      expect(c.data!.first.gstin, '24AAACT2727Q1Z2');
      final lanes = await mgr.listLanes();
      expect(lanes.data!.single.code, state['lane']);
      expect(lanes.data!.single.machines.single.id, state['machine']);
      final refused = await as('dpl_qa').saveLane({'code': 'X_LANE', 'name': 'x', 'machine_ids': [state['machine']]});
      expect(refused.statusCode ?? 403, 403);
      expect(refused.isError, isTrue);
    }, skip: skip);

    test('shipment details and the gate pass parse; the gate verifies the pass', () async {
      final tripId = state['dispatchedTripId'] as int;
      final disp = as('dpl_dispatch');
      final upd = await disp.updateTripShipment(tripId, {'seal_no': 'live-seal-1', 'transport_driver_mobile': '9890011111'});
      expect(upd.isOk, isTrue, reason: upd.error);
      expect(upd.data!.sealNo, 'LIVE-SEAL-1');
      expect(upd.data!.driverMobile, '9890011111');
      final gp = await disp.getGatePass(tripId);
      expect(gp.isOk, isTrue, reason: gp.error);
      expect(gp.data!.totalQty, 48);
      expect(gp.data!.lines.single.palletCount, 1);
      final pdf = await disp.getGatePassPdf(tripId);
      expect(String.fromCharCodes(pdf.data!.take(5)), '%PDF-');
      final check = await as('dpl_security').verifyGatePass(gp.data!.qrToken);
      expect(check.isOk, isTrue, reason: check.error);
      expect(check.data!.gatePassNo, gp.data!.gatePassNo);
      final forged = await as('dpl_security').verifyGatePass('${gp.data!.qrToken}x');
      expect(forged.code, 'INVALID_TOKEN');
    }, skip: skip);

    test('a refusal carries the Marathi line when the app asks for it', () async {
      final res = await as('dpl_security', lang: 'mr').verifyGatePass('not-a-token-at-all');
      expect(res.isError, isTrue);
      expect(res.errorLocal, isNotNull);
      expect(res.floorMessage, contains(res.errorLocal!));
    }, skip: skip);

    test('customer return, stock control and subscriptions parse', () async {
      final mgr = as('dpl_manager');
      final ret = await mgr.getReturn(state['returnId'] as int);
      expect(ret.isOk, isTrue, reason: ret.error);
      expect(ret.data!.status, 'closed');
      expect(ret.data!.scrapped, 1);
      final parts = await as('dpl_dispatch').searchReturnParts();
      expect(parts.isOk, isTrue, reason: parts.error);
      expect(parts.data!.map((p) => p.id), contains(state['part']));
      final count = await mgr.getRackCount(state['countId'] as int);
      expect(count.data!.status, 'approved');
      expect(count.data!.blind, isFalse);
      final lots = await mgr.listStockLots();
      expect(lots.data!.first.qtyRemaining, 25);
      final adj = await mgr.listStockAdjustments(status: 'approved');
      expect(adj.data!.single.reasonCode, 'COUNT_VARIANCE');
      final racks = await as('dpl_qa').listCountLocations();
      expect(racks.data!.map((r) => r.id).toSet(), (state['racks'] as List).cast<int>().toSet());
      final subs = await mgr.listReportSubscriptions();
      expect(subs.data!.firstWhere((s) => s.reportKey == 'daily_dispatch').lastStatus, 'sent');
    }, skip: skip);

    test('offline sync: the app’s transaction format is accepted and applied', () async {
      final qa = as('dpl_qa');
      // A fresh device per run: a device's transactions are stored exactly
      // once, so re-sending the same txn on a rerun is (correctly) a duplicate.
      final device = 'HHT-LIVE-${DateTime.now().millisecondsSinceEpoch}';
      final block = await qa.reserveSyncNumbers(device, size: 1);
      expect(block.isOk, isTrue, reason: block.error);
      final push = await qa.pushSync(device, [
        DplSyncTxn(
          txnId: '$device-1',
          seq: 1,
          type: 'count.scan',
          payload: {'count_id': state['countId'], 'code': 'NOPE', 'location_id': (state['racks'] as List).first},
          userId: 0,
          occurredAt: DateTime.now(),
        ),
      ]);
      // user_id 0 means "no stored id" in the app, and the server then treats
      // the person pushing (QA here) as the operator. The count in the seeded
      // day is already approved, so the real service refuses the scan by name
      // and the device blocks: proof the app's transaction went through the
      // replay path as the right person, with the rules applied.
      expect(push.isOk, isTrue, reason: push.error);
      expect(push.data!.applied.single.status, 'rejected');
      expect(push.data!.applied.single.code, 'COUNT_CLOSED');
      expect(push.data!.isBlocked, isTrue);
      final conflicts = await as('dpl_manager').listSyncConflicts();
      expect(conflicts.data!.map((c) => c.deviceId), contains(device));
    }, skip: skip);
  });
}
