import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_api_service.dart';
import 'package:productivity_tracker/features/dpl/maxion/stock/rack_count_screen.dart';
import 'package:productivity_tracker/features/dpl/maxion/stock/stock_providers.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_stock_control.dart';

/// Stock control (backend API.md §10.2, §10.3) through the real service over a
/// canned transport, so the request bodies and the parsing are what ship.

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  FutureOr<ResponseBody> Function(RequestOptions o) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

({DplApiService svc, _FakeAdapter adapter}) _service(Object data, {int status = 200}) {
  final adapter = _FakeAdapter((_) => _json(status == 200 ? {'success': true, 'data': data} : data, status));
  final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api/v1/dpl'))..httpClientAdapter = adapter;
  return (svc: DplApiService(dio), adapter: adapter);
}

Map<String, dynamic> _body(RequestOptions o) => o.data == null ? const {} : Map<String, dynamic>.from(o.data as Map);

const _blindCount = {
  'count_id': 7,
  'count_no': 'RC-0007',
  'status': 'open',
  'blind': true,
  'scanned': 1,
  'racks': [
    {'location_id': 5, 'code': 'A-01'},
    {'location_id': 6, 'code': 'A-02'},
  ],
  'lines': [
    {'pallet_id': 91, 'pallet_no': 'P26000091', 'customer_part_no': 'WHL-15', 'qty': 48, 'found_location': 'A-01', 'scanned_at': '2026-09-25T09:00:00Z'},
  ],
  'started_at': '2026-09-25T08:30:00Z',
};

const _submittedCount = {
  'count_id': 7,
  'count_no': 'RC-0007',
  'status': 'submitted',
  'blind': false,
  'scanned': 7,
  'racks': [
    {'location_id': 5, 'code': 'A-01'},
  ],
  'lines': [
    {'pallet_no': 'P26000091', 'customer_part_no': 'WHL-15', 'qty': 48, 'found_location': 'A-01', 'expected_location': 'A-01', 'result': 'matched'},
    {'pallet_no': 'P26000092', 'customer_part_no': 'WHL-15', 'qty': 48, 'found_location': 'A-01', 'expected_location': 'B-04', 'result': 'misplaced'},
    {'pallet_no': 'P26000093', 'customer_part_no': 'WHL-16', 'qty': 24, 'found_location': null, 'expected_location': 'A-01', 'result': 'missing'},
    {'pallet_no': 'H26000011', 'customer_part_no': 'WHL-17', 'qty': 12, 'found_location': 'A-01', 'expected_location': null, 'result': 'unexpected'},
  ],
  'summary': {'expected': 8, 'matched': 7, 'misplaced': 1, 'missing': 1, 'unexpected': 1},
  'accuracy_pct': 87.5,
};

void main() {
  group('rack counts', () {
    test('listRackCounts returns the rows and sends the status filter', () async {
      final s = _service([
        {'count_id': 7, 'count_no': 'RC-0007', 'status': 'open', 'racks': 2, 'started_at': '2026-09-25T08:30:00Z'},
        {'count_id': 6, 'count_no': 'RC-0006', 'status': 'approved', 'racks': 1},
      ]);
      final res = await s.svc.listRackCounts(status: 'open');
      expect(res.isOk, isTrue);
      expect(res.data!.length, 2);
      expect(res.data!.first['count_no'], 'RC-0007');
      final req = s.adapter.requests.single;
      expect(req.path, endsWith('/stock/counts'));
      expect(req.queryParameters['status'], 'open');
    });

    test('getRackCount while blind carries only what was found', () async {
      final s = _service(_blindCount);
      final res = await s.svc.getRackCount(7);
      final c = res.data!;
      expect(s.adapter.requests.single.path, endsWith('/stock/counts/7'));
      expect(c.blind, isTrue);
      expect(c.status, 'open');
      expect(c.scanned, 1);
      expect(c.racks.map((r) => r.code), ['A-01', 'A-02']);
      expect(c.racks.first.id, 5);
      expect(c.summary, isNull);
      expect(c.accuracyPct, isNull);
      expect(c.lines.single.palletNo, 'P26000091');
      expect(c.lines.single.foundLocation, 'A-01');
      expect(c.lines.single.expectedLocation, isNull);
      expect(c.lines.single.result, isNull);
    });

    test('getRackCount after submit carries results, summary and accuracy', () async {
      final c = (await _service(_submittedCount).svc.getRackCount(7)).data!;
      expect(c.blind, isFalse);
      expect(c.summary, {'expected': 8, 'matched': 7, 'misplaced': 1, 'missing': 1, 'unexpected': 1});
      expect(c.accuracyPct, 87.5);
      expect(c.lines.map((l) => l.result), ['matched', 'misplaced', 'missing', 'unexpected']);
      expect(c.lines[1].expectedLocation, 'B-04');
    });

    test('scanRackCount posts the code and the rack', () async {
      final s = _service({'pallet_no': 'P26000091', 'qty': 48, 'location_code': 'A-01', 'scanned': 2});
      final res = await s.svc.scanRackCount(7, code: 'GAP|P26000091', locationId: 5);
      expect(res.data!['pallet_no'], 'P26000091');
      final req = s.adapter.requests.single;
      expect(req.method, 'POST');
      expect(req.path, endsWith('/stock/counts/7/scan'));
      expect(_body(req), {'code': 'GAP|P26000091', 'location_id': 5});
    });

    test('startRackCount sends racks or a zone', () async {
      final s = _service(_blindCount);
      await s.svc.startRackCount(locationIds: [5, 6]);
      await s.svc.startRackCount(zone: 'A', note: 'monthly');
      expect(_body(s.adapter.requests[0]), {'location_ids': [5, 6]});
      expect(_body(s.adapter.requests[1]), {'zone': 'A', 'note': 'monthly'});
    });

    test('a same-person approval surfaces SAME_PERSON', () async {
      final s = _service({'success': false, 'error': 'The counter cannot approve their own count.', 'code': 'SAME_PERSON'}, status: 403);
      final res = await s.svc.rackCountAction(7, 'approve');
      expect(res.isError, isTrue);
      expect(res.code, 'SAME_PERSON');
      expect(res.floorMessage, contains('cannot approve'));
      expect(s.adapter.requests.single.path, endsWith('/stock/counts/7/approve'));
    });
  });

  group('adjustments and lots', () {
    const adj = {
      'id': 3,
      'adjustment_no': 'ADJ-0003',
      'kind': 'lot',
      'direction': 'decrease',
      'qty': 4,
      'customer_part_no': 'WHL-15',
      'reason_code': 'DAMAGED',
      'reason': 'Damaged',
      'note': 'Forklift hit the stack',
      'status': 'pending',
      'requested_by_user_id': 12,
      'requested_at': '2026-09-25T09:00:00Z',
    };

    test('lot adjustment body', () async {
      final s = _service(adj);
      final body = dplLotAdjustmentBody(lotId: 21, direction: 'decrease', qty: 4, reasonCode: 'DAMAGED', note: '  Forklift hit the stack ');
      final res = await s.svc.requestStockAdjustment(body);
      expect(res.data!.adjustmentNo, 'ADJ-0003');
      expect(res.data!.isPending, isTrue);
      final req = s.adapter.requests.single;
      expect(req.path, endsWith('/stock/adjustments'));
      expect(_body(req), {
        'kind': 'lot',
        'lot_id': 21,
        'direction': 'decrease',
        'qty': 4,
        'reason_code': 'DAMAGED',
        'note': 'Forklift hit the stack',
      });
    });

    test('wheel write-off body trims and de-duplicates codes', () async {
      final s = _service({...adj, 'kind': 'wheels', 'qty': 2});
      final body = dplWheelWriteOffBody(codes: [' GA2600000001', 'GA2600000002', 'GA2600000001', ''], reasonCode: 'SCRAP', note: 'Cracked rims');
      final res = await s.svc.requestStockAdjustment(body);
      expect(res.data!.kind, 'wheels');
      expect(_body(s.adapter.requests.single), {
        'kind': 'wheels',
        'codes': ['GA2600000001', 'GA2600000002'],
        'reason_code': 'SCRAP',
        'note': 'Cracked rims',
      });
    });

    test('decideStockAdjustment approve and reject hit their own paths', () async {
      final s = _service({...adj, 'status': 'approved'});
      final ok = await s.svc.decideStockAdjustment(3, approve: true);
      expect(ok.data!.status, 'approved');
      expect(s.adapter.requests.last.path, endsWith('/stock/adjustments/3/approve'));
      expect(_body(s.adapter.requests.last), isEmpty);

      s.adapter.handler = (_) => _json({'success': true, 'data': {...adj, 'status': 'rejected', 'decision_note': 'Recount first'}});
      final no = await s.svc.decideStockAdjustment(3, approve: false, note: 'Recount first');
      expect(no.data!.status, 'rejected');
      expect(no.data!.decisionNote, 'Recount first');
      expect(s.adapter.requests.last.path, endsWith('/stock/adjustments/3/reject'));
      expect(_body(s.adapter.requests.last), {'note': 'Recount first'});
    });

    test('decideStockAdjustment surfaces SAME_PERSON', () async {
      final s = _service({'success': false, 'error': 'You raised this adjustment; someone else must approve it.', 'code': 'SAME_PERSON'}, status: 403);
      final res = await s.svc.decideStockAdjustment(3, approve: true);
      expect(res.code, 'SAME_PERSON');
    });

    test('listStockAdjustments parses and filters', () async {
      final s = _service([adj]);
      final res = await s.svc.listStockAdjustments(status: 'pending');
      expect(res.data!.single.reason, 'Damaged');
      expect(res.data!.single.requestedByUserId, 12);
      expect(s.adapter.requests.single.queryParameters['status'], 'pending');
    });

    test('listStockLots parses opening against remaining', () async {
      final s = _service([
        {
          'lot_id': 21,
          'part_id': 4,
          'customer_part_no': 'WHL-15',
          'lot_no': 'B-778',
          'location_id': null,
          'source_location_code': 'FG-01',
          'fifo_date': '2026-08-01',
          'opening_qty': 120,
          'qty_remaining': 96,
        },
      ]);
      final lots = (await s.svc.listStockLots()).data!;
      expect(s.adapter.requests.single.path, endsWith('/stock/lots'));
      final l = lots.single;
      expect(l.lotId, 21);
      expect(l.customerPartNo, 'WHL-15');
      expect(l.openingQty, 120);
      expect(l.qtyRemaining, 96);
      expect(l.fifoDate, '2026-08-01');
      expect(l.sourceLocationCode, 'FG-01');
    });
  });

  testWidgets('DplRackCountSummary shows totals, accuracy and each line’s result', (tester) async {
    final count = DplRackCount.fromJson(Map<String, dynamic>.from(_submittedCount));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: DplRackCountSummary(count: count))),
    ));
    expect(find.text('Accuracy 87.5%'), findsOneWidget);
    expect(find.text('Matched  7'), findsOneWidget);
    expect(find.text('Misplaced  1'), findsOneWidget);
    expect(find.text('Missing  1'), findsOneWidget);
    expect(find.text('Unexpected  1'), findsOneWidget);
    expect(find.text('8 pallets expected on these racks'), findsOneWidget);
    expect(find.text('P26000092'), findsOneWidget);
    expect(find.textContaining('found A-01, belongs B-04'), findsOneWidget);
    expect(find.text('Submitted'), findsOneWidget);
    // One result pill per line.
    expect(find.text('Matched'), findsOneWidget);
    expect(find.text('Missing'), findsOneWidget);
  });
}
