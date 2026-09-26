import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_api_service.dart';
import 'package:productivity_tracker/features/dpl/maxion/logistics/gate_pass_screen.dart';
import 'package:productivity_tracker/features/dpl/maxion/logistics/gate_pass_verify_screen.dart';
import 'package:productivity_tracker/features/dpl/maxion/logistics/trip_shipment_screen.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_logistics.dart';

/// Maxion logistics (backend API.md §8.1–8.5) through the REAL DplApiService
/// over a fake Dio adapter, so the envelope unwrapping, error mapping and the
/// models' fromJson all run exactly as they do against the server.

class _Canned {
  _Canned(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
}

/// Answers by "METHOD path" and remembers every request it saw.
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.routes);

  final Map<String, _Canned> routes;
  final List<RequestOptions> seen = [];

  RequestOptions last(String method, String path) =>
      seen.lastWhere((o) => o.method == method && o.path == path);

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    seen.add(options);
    final hit = routes['${options.method} ${options.path}'] ??
        _Canned(404, {'success': false, 'error': 'No route for ${options.method} ${options.path}', 'code': 'NOT_FOUND'});
    return ResponseBody.fromString(
      jsonEncode(hit.body),
      hit.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

({DplApiService svc, _RoutingAdapter adapter}) _service(Map<String, _Canned> routes) {
  final adapter = _RoutingAdapter(routes);
  final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'))..httpClientAdapter = adapter;
  return (svc: DplApiService(dio), adapter: adapter);
}

_Canned _ok(Map<String, dynamic> data) => _Canned(200, {'success': true, 'data': data});

Map<String, dynamic> _shipmentJson({String? seal = 'S-7781'}) => {
      'trip_id': 42,
      'trip_number': 7,
      'trip_date': '2026-09-25',
      'plant_code': 'PL2',
      'status': 'fulfilled',
      'vehicle_no': 'MH14 GD 4521',
      'transporter': {'id': 3, 'code': 'VRL', 'name': 'VRL Logistics'},
      'consignee': {'id': 1, 'code': 'TML', 'name': 'Tata Motors Pimpri', 'city': 'Pune'},
      'transport_driver_name': 'Suresh Kale',
      'transport_driver_mobile': '9890012345',
      'driver_licence_no': 'MH1420110012345',
      'seal_no': seal,
      'lr_no': 'LR-20931',
      'lr_date': '2026-09-25',
      'vehicle_in_at': '2026-09-25T03:30:00.000Z',
      'dock_in_at': '2026-09-25T04:00:00.000Z',
      'dock_out_at': null,
      'vehicle_out_at': null,
      'tat_reason': null,
      'tat_remark': null,
      'minutes_at_dock': 35,
      'minutes_in_plant': 85,
    };

const _line = {
  'customer_part_no': '5401-AB',
  'description': '102D1',
  'hsn_code': '87087000',
  'qty': 16,
  'pallet_count': 2,
  'pallet_nos': 'P2600000011, P2600000012',
  'invoice_nos': 'INV-9001',
};

Map<String, dynamic> _returnJson() => {
      'return_id': 5,
      'return_no': 'RN26000005',
      'status': 'open',
      'reason': 'Rim damage at customer',
      'reference_no': 'RTV-11',
      'consignee': {'id': 1, 'code': 'TML', 'name': 'Tata Motors Pimpri'},
      'received_at': '2026-09-25T06:00:00.000Z',
      'lines': [
        {
          'line_id': 11,
          'kind': 'wheel',
          'serial_no': 'GA2600000147',
          'part_id': 9,
          'customer_part_no': '5401-AB',
          'description': '102D1',
          'qty': 1,
          'original_pallet_no': 'P2600000011',
          'disposition': 'pending',
        },
        {
          'line_id': 12,
          'kind': 'manual',
          'serial_no': null,
          'part_id': 9,
          'qty': 4,
          'note': 'Ekatm era',
          'disposition': 'restocked',
          'disposition_note': 'OK after inspection',
        },
      ],
      'totals': {'qty': 5, 'pending': 1, 'restocked': 4, 'scrapped': 0},
    };

void main() {
  group('shipment details (§8.2)', () {
    test('PATCH sends only the keys that changed, in the server formats', () async {
      final s = _service({
        'GET /dispatch/trips/42/shipment': _ok(_shipmentJson()),
        'PATCH /dispatch/trips/42/shipment': _ok(_shipmentJson(seal: 'S-9000')),
      });

      final got = await s.svc.getTripShipment(42);
      expect(got.isError, isFalse);
      final shipment = got.data!;
      expect(shipment.transporter!.name, 'VRL Logistics');
      expect(shipment.minutesAtDock, 35);

      final original = DplShipmentDraft.fromShipment(shipment);
      final draft = DplShipmentDraft.fromShipment(shipment)
        ..sealNo = 's-9000' // upper-cased on the way out
        ..driverName = '  Suresh Kale  ' // whitespace only: NOT a change
        ..dockOutAt = DateTime.utc(2026, 9, 25, 4, 45)
        ..lrDate = DateTime(2026, 9, 24)
        ..tatRemark = ''; // was null, still blank: NOT a change

      final changes = draft.changesFrom(original);
      expect(changes.keys.toSet(), {'seal_no', 'dock_out_at', 'lr_date'});

      final saved = await s.svc.updateTripShipment(42, changes);
      expect(saved.isError, isFalse);
      expect(saved.data!.sealNo, 'S-9000');

      final body = s.adapter.last('PATCH', '/dispatch/trips/42/shipment').data as Map;
      expect(body, {
        'seal_no': 'S-9000',
        'dock_out_at': '2026-09-25T04:45:00.000Z',
        'lr_date': '2026-09-24',
      });
    });

    test('blanking a field sends null; an untouched draft sends nothing', () {
      final shipment = DplTripShipment.fromJson(_shipmentJson());
      final original = DplShipmentDraft.fromShipment(shipment);
      expect(DplShipmentDraft.fromShipment(shipment).changesFrom(original), isEmpty);

      final draft = DplShipmentDraft.fromShipment(shipment)
        ..transporterId = null
        ..vehicleInAt = null;
      expect(draft.changesFrom(original), {'transporter_id': null, 'vehicle_in_at': null});
    });

    test('formatMinutes', () {
      expect(formatMinutes(null), '—');
      expect(formatMinutes(40), '40 min');
      expect(formatMinutes(120), '2 h');
      expect(formatMinutes(85), '1 h 25 min');
    });
  });

  group('gate pass (§8.3)', () {
    test('parses lines, totals, missing and ready_for_gate', () async {
      final s = _service({
        'GET /dispatch/trips/42/gate-pass': _ok({
          'gate_pass_no': 'GP/PL2/260925/1',
          'shipment': _shipmentJson(seal: null),
          'lines': [_line],
          'totals': {'qty': 16, 'pallets': 2},
          'ready_for_gate': false,
          'missing': ['seal'],
          'qr_token': 'tok.abc.def',
        }),
      });
      final res = await s.svc.getGatePass(42);
      expect(res.isError, isFalse);
      final gp = res.data!;
      expect(gp.gatePassNo, 'GP/PL2/260925/1');
      expect(gp.readyForGate, isFalse);
      expect(gp.missing, ['seal']);
      expect(gp.lines.single.hsnCode, '87087000');
      expect(gp.lines.single.palletCount, 2);
      expect(gp.totalQty, 16);
      expect(gp.totalPallets, 2);
      expect(gp.qrToken, 'tok.abc.def');
      expect(gatePassFileName(gp.gatePassNo, 42), 'GP-PL2-260925-1.pdf');
    });

    test('a 409 NOTHING_TO_SHIP maps to res.code', () async {
      final s = _service({
        'GET /dispatch/trips/42/gate-pass': _Canned(409, {
          'success': false,
          'error': 'Nothing on this trip is approved yet.',
          'code': 'NOTHING_TO_SHIP',
        }),
      });
      final res = await s.svc.getGatePass(42);
      expect(res.isError, isTrue);
      expect(res.code, 'NOTHING_TO_SHIP');
      expect(res.statusCode, 409);
    });

    test('verify: valid, problem, and already gated out', () async {
      final valid = _service({
        'POST /logistics/gate-pass/verify': _ok({
          'valid': true,
          'problem': null,
          'already_gated_out': null,
          'gate_pass_no': 'GP/PL2/260925/1',
          'trip_status': 'fulfilled',
          'shipment': _shipmentJson(),
          'lines': [_line],
          'totals': {'qty': 16, 'pallets': 2},
        }),
      });
      final ok = await valid.svc.verifyGatePass('tok.abc.def');
      expect(ok.data!.valid, isTrue);
      expect(ok.data!.alreadyGatedOut, isFalse);
      expect(ok.data!.lines, hasLength(1));
      expect(ok.data!.totalQty, 16);
      expect(valid.adapter.last('POST', '/logistics/gate-pass/verify').data, {'token': 'tok.abc.def'});

      final bad = _service({
        'POST /logistics/gate-pass/verify': _ok({
          'valid': false,
          'problem': 'The trip was cancelled.',
          'already_gated_out': null,
          'gate_pass_no': 'GP/PL2/260925/1',
          'trip_status': 'cancelled',
        }),
      });
      final problem = await bad.svc.verifyGatePass('t');
      expect(problem.data!.valid, isFalse);
      expect(problem.data!.problem, 'The trip was cancelled.');
      expect(problem.data!.alreadyGatedOut, isFalse);

      final out = _service({
        'POST /logistics/gate-pass/verify': _ok({
          'valid': false,
          'problem': 'Already gated out.',
          'already_gated_out': {'at': '2026-09-25T07:10:00.000Z', 'by': 'Gate Guard'},
          'gate_pass_no': 'GP/PL2/260925/1',
          'trip_status': 'fulfilled',
        }),
      });
      final gone = await out.svc.verifyGatePass('t');
      expect(gone.data!.alreadyGatedOut, isTrue);
      expect(gone.data!.gatedOutBy, 'Gate Guard');
      expect(gone.data!.gatedOutAt, DateTime.utc(2026, 9, 25, 7, 10));
    });
  });

  group('reversal (§8.4)', () {
    test('requestReversal sends the reason', () async {
      final s = _service({
        'POST /logistics/slips/77/reversal': _ok({
          'slip_id': 77,
          'slip_no': 'DS-77',
          'status': 'dispatched',
          'reversal_status': 'requested',
          'reversal_reason': 'Customer cancelled',
        }),
      });
      final res = await s.svc.requestReversal(77, 'Customer cancelled');
      expect(res.data!.reversalStatus, 'requested');
      expect(s.adapter.last('POST', '/logistics/slips/77/reversal').data, {'reason': 'Customer cancelled'});
    });

    test('a 409 with message_local gives a two-line floor message', () async {
      final s = _service({
        'POST /logistics/slips/77/reversal': _Canned(409, {
          'success': false,
          'error': 'The truck has left the plant. Record a customer return instead.',
          'code': 'SHIPMENT_LEFT_PLANT',
          'message_local': 'ट्रक प्लांटमधून निघाला आहे.',
        }),
      });
      final res = await s.svc.requestReversal(77, 'Customer cancelled');
      expect(res.isError, isTrue);
      expect(res.code, 'SHIPMENT_LEFT_PLANT');
      expect(res.floorMessage,
          'ट्रक प्लांटमधून निघाला आहे.\nThe truck has left the plant. Record a customer return instead.');
    });
  });

  group('customer returns (§8.5)', () {
    test('createReturn and getReturn parse lines and totals', () async {
      final s = _service({
        'POST /returns': _ok(_returnJson()),
        'GET /returns/5': _ok(_returnJson()),
      });
      final created = await s.svc.createReturn(reason: 'Rim damage at customer', consigneeId: 1, referenceNo: 'RTV-11');
      expect(created.data!.returnNo, 'RN26000005');
      expect(s.adapter.last('POST', '/returns').data,
          {'reason': 'Rim damage at customer', 'consignee_id': 1, 'reference_no': 'RTV-11'});

      final got = await s.svc.getReturn(5);
      final r = got.data!;
      expect(r.isOpen, isTrue);
      expect(r.consigneeName, 'Tata Motors Pimpri');
      expect(r.lines, hasLength(2));
      expect(r.lines.first.kind, 'wheel');
      expect(r.lines.first.serialNo, 'GA2600000147');
      expect(r.lines.first.originalPalletNo, 'P2600000011');
      expect(r.lines.first.isPending, isTrue);
      expect(r.lines.last.kind, 'manual');
      expect(r.lines.last.qty, 4);
      expect(r.lines.last.disposition, 'restocked');
      expect((r.totalQty, r.pending, r.restocked, r.scrapped), (5, 1, 4, 0));
    });

    test('decideReturn sends line_ids and disposition; labels_to_print comes back', () async {
      final s = _service({
        'POST /returns/5/disposition': _ok({'decided': 2, 'wheels': 1, 'disposition': 'restock', 'labels_to_print': 4}),
      });
      final res = await s.svc.decideReturn(5, disposition: 'restock', lineIds: [11, 12]);
      expect(res.data!['labels_to_print'], 4);
      expect(s.adapter.last('POST', '/returns/5/disposition').data, {'disposition': 'restock', 'line_ids': [11, 12]});

      await s.svc.decideReturn(5, disposition: 'scrap', lineIds: [11], note: 'Cracked rim');
      expect(s.adapter.last('POST', '/returns/5/disposition').data,
          {'disposition': 'scrap', 'line_ids': [11], 'note': 'Cracked rim'});
    });

    test('closing with pending lines surfaces LINES_PENDING', () async {
      final s = _service({
        'POST /returns/5/close': _Canned(409, {
          'success': false,
          'error': '1 line(s) still wait for QA to restock or scrap.',
          'code': 'LINES_PENDING',
        }),
      });
      final res = await s.svc.closeReturn(5);
      expect(res.code, 'LINES_PENDING');
      expect(res.floorMessage, contains('still wait for QA'));
    });
  });

  group('widgets', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

    testWidgets('GatePassResultPanel: clear, refused, already let out', (tester) async {
      final shipment = DplTripShipment.fromJson(_shipmentJson());
      await tester.pumpWidget(wrap(GatePassResultPanel(
        check: DplGatePassCheck(valid: true, gatePassNo: 'GP/PL2/260925/1', tripStatus: 'fulfilled', shipment: shipment),
      )));
      expect(find.text('CLEAR TO GO'), findsOneWidget);
      expect(find.text('GP/PL2/260925/1'), findsOneWidget);

      await tester.pumpWidget(wrap(const GatePassResultPanel(
        check: DplGatePassCheck(valid: false, problem: 'The trip was cancelled.', gatePassNo: 'GP/1', tripStatus: 'cancelled'),
      )));
      expect(find.text('DO NOT LET OUT'), findsOneWidget);
      expect(find.text('The trip was cancelled.'), findsOneWidget);

      await tester.pumpWidget(wrap(GatePassResultPanel(
        check: DplGatePassCheck(
          valid: false,
          problem: 'Already gated out.',
          gatePassNo: 'GP/1',
          tripStatus: 'fulfilled',
          gatedOutAt: DateTime(2026, 9, 25, 12, 40),
          gatedOutBy: 'Gate Guard',
        ),
      )));
      expect(find.text('ALREADY LET OUT at 25 Sep, 12:40 by Gate Guard'), findsOneWidget);
      expect(find.text('CLEAR TO GO'), findsNothing);

      await tester.pumpWidget(wrap(const GatePassResultPanel(error: 'This gate pass belongs to another plant.')));
      expect(find.text('DO NOT LET OUT'), findsOneWidget);
      expect(find.text('This gate pass belongs to another plant.'), findsOneWidget);
    });

    testWidgets('DplGatePassScreen: NOTHING_TO_SHIP is a friendly empty state', (tester) async {
      final s = _service({
        'GET /dispatch/trips/42/gate-pass': _Canned(409, {
          'success': false,
          'error': 'Nothing on this trip is approved yet.',
          'code': 'NOTHING_TO_SHIP',
        }),
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [dplApiServiceProvider.overrideWithValue(s.svc)],
        child: const MaterialApp(home: Scaffold(body: DplGatePassScreen(tripId: 42, showAppBar: false))),
      ));
      await tester.pumpAndSettle();
      expect(find.text('No approved slip on this trip yet'), findsOneWidget);
    });

    testWidgets('DplGatePassScreen: incomplete pass shows the red banner and the lines', (tester) async {
      final s = _service({
        'GET /dispatch/trips/42/gate-pass': _ok({
          'gate_pass_no': 'GP/PL2/260925/1',
          'shipment': _shipmentJson(seal: null),
          'lines': [_line],
          'totals': {'qty': 16, 'pallets': 2},
          'ready_for_gate': false,
          'missing': ['seal', 'driver'],
          'qr_token': 'tok.abc.def',
        }),
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [dplApiServiceProvider.overrideWithValue(s.svc)],
        child: const MaterialApp(home: Scaffold(body: DplGatePassScreen(tripId: 42, showAppBar: false))),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('Incomplete: seal no, driver'), findsOneWidget);
      expect(find.text('5401-AB'), findsOneWidget);
      expect(find.text('GP/PL2/260925/1'), findsOneWidget);
    });
  });
}
