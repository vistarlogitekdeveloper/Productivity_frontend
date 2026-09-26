import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_api_service.dart';
import 'package:productivity_tracker/features/dpl/maxion/manager/oem_dashboard_screen.dart';
import 'package:productivity_tracker/features/dpl/maxion/manager/stock_reports_screen.dart';

/// Manager screens for Maxion phases 1–4: the parsing they rely on, run
/// through the real [DplApiService] over a canned Dio adapter, plus a smoke
/// render of the OEM dashboard.

/// Answers every request with [status] and [body], and remembers the
/// requests it saw.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.body, {this.status = 200});

  final Map<String, dynamic> body;
  final int status;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

DplApiService _service(_CannedAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'))..httpClientAdapter = adapter;
  return DplApiService(dio);
}

DplApiService _serviceReturning(Map<String, dynamic> body, {int status = 200}) =>
    _service(_CannedAdapter(body, status: status));

Map<String, dynamic> _ok(Object data) => {'success': true, 'data': data};

/// Every field the backend puts on a row of each report
/// (`src/modules/dpl/services/reportSheets.js`). A column key outside this
/// set would render an empty column forever.
const Map<String, Set<String>> _serverRowFields = {
  'fg-stock': {
    'customer_part_no', 'description', 'uom', 'on_hand_qty', 'full_pallets', 'full_qty', 'half_pallets',
    'half_qty', 'merged_pallets', 'merged_qty', 'spd_qty', 'packing_qty', 'on_trolley_qty', 'loose_qty',
    'loaded_qty', 'return_hold_qty', 'unlabelled_qty', 'oldest_closed_at',
  },
  'stock-by-location': {
    'code', 'name', 'zone', 'capacity_qty', 'stored_qty', 'unlabelled_qty', 'free_qty', 'utilisation_pct',
    'pallets', 'half_pallets', 'loaded_pallets', 'over_capacity', 'oldest_closed_at',
  },
  'dispatch-register': {
    'dispatch_date', 'dispatched_at', 'trip_number', 'vehicle_no', 'driver_name', 'slip_no', 'invoice_no',
    'customer_part_no', 'description', 'hsn_code', 'qty', 'pallet_count', 'pallet_nos', 'dispatched_by_name',
    'plant_code',
  },
  'half-pallet-ageing': {
    'pallet_no', 'customer_part_no', 'description', 'qty', 'standard_qty', 'short_qty', 'location_code',
    'shift_code', 'age_days', 'closed_at',
  },
  'label-reconciliation': {
    'print_date', 'shift_code', 'source', 'printed', 'voided', 'packed', 'spd', 'on_trolley', 'loose', 'loaded',
    'dispatched', 'on_return_hold',
  },
  'returns-register': {
    'received_date', 'return_no', 'consignee', 'reference_no', 'reason', 'customer_part_no', 'description',
    'kind', 'serial_no', 'qty', 'original_pallet_no', 'original_trip_number', 'original_trip_date',
    'disposition', 'disposition_note',
  },
  'stock-movements': {
    'movement_date', 'movement_type', 'document_no', 'customer_part_no', 'description', 'lot_no', 'serial_no',
    'qty', 'user_name', 'note',
  },
};

const _rowsKeys = {
  'fg-stock': 'items',
  'stock-by-location': 'locations',
  'dispatch-register': 'lines',
  'half-pallet-ageing': 'pallets',
  'label-reconciliation': 'groups',
  'returns-register': 'lines',
  'stock-movements': 'lines',
};

const _dateRanged = {'dispatch-register', 'label-reconciliation', 'returns-register', 'stock-movements'};

Map<String, dynamic> _dashboardPayload({List<Map<String, dynamic>>? lanes}) => {
      'date': '2026-09-25',
      'lanes': lanes ??
          [
            {
              'plant_code': 'MXN_TATA_PV',
              'name': 'Tata Motors PV',
              'planned_today': 400,
              'dispatched_today': 300,
              'fulfilment_today_pct': 75,
              'dispatched_mtd': 9120,
              'pallets_mtd': 380,
              'open_trips': 2,
              'avg_minutes_at_dock': 41,
            },
            {
              'plant_code': 'MXN_MM',
              'name': 'Mahindra & Mahindra',
              'planned_today': 0,
              'dispatched_today': 0,
              'fulfilment_today_pct': null,
              'dispatched_mtd': 0,
              'pallets_mtd': 0,
              'open_trips': 0,
              'avg_minutes_at_dock': null,
            },
          ],
      'totals': {'planned_today': 400},
      'stock': {'on_hand_qty': 5230, 'unlabelled_qty': 1200, 'loaded_qty': 96, 'half_pallets': 7},
      'attention': {
        'half_pallets_over_7_days': 3,
        'pallets_not_put_away': 0,
        'wheels_in_quarantine': 4,
        'reversals_pending': 1,
        'adjustments_pending': 0,
        'counts_awaiting_approval': 0,
        'returns_open': 2,
      },
      'returns_mtd': [
        {'consignee': 'Tata Motors PV Pune', 'qty': 6},
      ],
    };

void main() {
  group('stock report tables', () {
    test('fg-stock parses items and totals', () async {
      final adapter = _CannedAdapter(_ok({
        'as_of': '2026-09-25T06:00:00Z',
        'items': [
          {'customer_part_no': 'W-1001', 'description': 'Wheel 15x6', 'on_hand_qty': 480, 'full_pallets': 10, 'loose_qty': 12},
          {'customer_part_no': 'W-1002', 'description': 'Wheel 16x6.5', 'on_hand_qty': '96', 'full_pallets': 2},
        ],
        'totals': {'on_hand_qty': 576, 'full_pallets': 12, 'half_pallets': 0, 'loose_qty': 12},
      }));
      final svc = _service(adapter);

      final res = await svc.getReportTable('fg-stock', 'items');
      expect(res.isError, isFalse);
      final t = res.data!;
      expect(t.rows, hasLength(2));
      expect(t.totals['on_hand_qty'], 576);
      expect(adapter.seen.single.path, endsWith('/reports/fg-stock'));

      final spec = dplStockReportSpecs['fg-stock']!;
      final onHand = spec.columns.firstWhere((c) => c.key == 'on_hand_qty');
      expect(t.cell(t.rows[1], onHand), '96');
      expect(t.cell(t.rows[1], spec.columns.firstWhere((c) => c.key == 'loose_qty')), '');

      final tiles = dplReportTotalsTiles(spec, t.totals);
      expect(tiles.first, (label: 'On hand', value: '576'));
      expect(tiles.map((e) => e.label), isNot(contains('Loaded'))); // absent from totals
    });

    test('dispatch-register parses lines, totals and the date window', () async {
      final adapter = _CannedAdapter(_ok({
        'from': '2026-09-01',
        'to': '2026-09-25',
        'lines': [
          {'dispatch_date': '2026-09-24', 'trip_number': 12, 'vehicle_no': 'MH14 GD 4521', 'slip_no': 'DS/1', 'qty': 240, 'pallet_count': 5},
        ],
        'by_part': [],
        'by_day': [],
        'totals': {'qty': 240, 'slips': 1, 'trips': 1, 'lines': 1},
      }));
      final svc = _service(adapter);

      final res = await svc.getReportTable('dispatch-register', 'lines', query: {'from': '2026-09-01', 'to': '2026-09-25'});
      expect(res.isError, isFalse);
      expect(res.data!.rows.single['vehicle_no'], 'MH14 GD 4521');
      expect(res.data!.from, '2026-09-01');
      expect(res.data!.to, '2026-09-25');
      expect(adapter.seen.single.queryParameters, {'from': '2026-09-01', 'to': '2026-09-25'});

      final tiles = dplReportTotalsTiles(dplStockReportSpecs['dispatch-register']!, res.data!.totals);
      expect(tiles.map((e) => e.label).toList(), ['Wheels', 'Slips', 'Trips', 'Lines']);
    });

    test('stock-movements totals with a nested map still produce scalar tiles', () async {
      final svc = _serviceReturning(_ok({
        'lines': [],
        'totals': {'lines': 0, 'net_qty': -4.5, 'by_type': {'opening': 0}},
      }));
      final res = await svc.getReportTable('stock-movements', 'lines');
      final tiles = dplReportTotalsTiles(dplStockReportSpecs['stock-movements']!, res.data!.totals);
      expect(tiles, [(label: 'Movements', value: '0'), (label: 'Net qty', value: '-4.5')]);
      expect(res.data!.rows, isEmpty);
    });

    test('column spec map covers all seven reports with real server fields', () {
      expect(dplStockReportSpecs.keys.toSet(), _serverRowFields.keys.toSet());
      for (final entry in dplStockReportSpecs.entries) {
        final spec = entry.value;
        expect(spec.key, entry.key);
        expect(spec.rowsKey, _rowsKeys[entry.key], reason: '${entry.key} rowsKey');
        expect(spec.dateRange, _dateRanged.contains(entry.key), reason: '${entry.key} dateRange');
        expect(spec.columns.length, inInclusiveRange(5, 8), reason: '${entry.key} column count');
        final keys = spec.columns.map((c) => c.key).toList();
        expect(keys.toSet().length, keys.length, reason: '${entry.key} has duplicate columns');
        for (final k in keys) {
          expect(_serverRowFields[entry.key], contains(k), reason: '${entry.key}.$k is not a server field');
        }
        for (final c in spec.columns) {
          expect(c.label.trim(), isNotEmpty);
        }
        expect(spec.totals, isNotEmpty, reason: '${entry.key} has no totals');
      }
    });
  });

  group('OEM dashboard', () {
    test('parses lanes, stock, attention and returns', () async {
      final svc = _serviceReturning(_ok(_dashboardPayload()));
      final res = await svc.getOemDashboard();
      expect(res.isError, isFalse);
      final d = res.data!;
      expect(d.lanes, hasLength(2));
      expect(d.lanes.first.name, 'Tata Motors PV');
      expect(d.lanes.first.fulfilmentTodayPct, 75);
      expect(d.lanes.first.avgMinutesAtDock, 41);
      expect(d.lanes.last.fulfilmentTodayPct, isNull);
      expect(d.lanes.last.avgMinutesAtDock, isNull);
      expect(d.onHandQty, 5230);
      expect(d.attention['wheels_in_quarantine'], 4);
      expect(d.attention.keys.every(dplAttentionLabels.containsKey), isTrue);
      expect(d.returnsMtd.single.consignee, 'Tata Motors PV Pune');
    });

    test('attention labels are human for known keys and readable for new ones', () {
      expect(dplAttentionLabel('half_pallets_over_7_days'), 'Half pallets older than 7 days');
      expect(dplAttentionLabel('something_new'), 'Something new');
    });
  });

  group('scheduled emails', () {
    test('lists configured and unconfigured subscriptions', () async {
      final svc = _serviceReturning(_ok([
        {
          'report_key': 'daily_dispatch',
          'label': 'Daily dispatch register',
          'configured': true,
          'recipients': ['plant@maxion.example', 'ops@maxion.example'],
          'cc': ['gm@maxion.example'],
          'send_at': '20:30',
          'weekdays': [1, 2, 3, 4, 5, 6],
          'is_active': true,
          'last_sent_on': '2026-09-24',
          'last_status': 'failed',
          'last_error': 'SMTP timeout',
        },
        {'report_key': 'returns', 'label': 'Customer returns', 'configured': false},
      ]));
      final res = await svc.listReportSubscriptions();
      expect(res.isError, isFalse);
      final subs = res.data!;
      expect(subs, hasLength(2));
      expect(subs[0].configured, isTrue);
      expect(subs[0].recipients, hasLength(2));
      expect(subs[0].sendAt, '20:30');
      expect(subs[0].weekdays, [1, 2, 3, 4, 5, 6]);
      expect(subs[0].lastError, 'SMTP timeout');
      expect(subs[1].configured, isFalse);
      expect(subs[1].isActive, isFalse);
      expect(subs[1].recipients, isEmpty);
      expect(subs[1].sendAt, '20:00');
    });
  });

  group('opening stock', () {
    test('preview parses totals, unmatched items and problem rows', () async {
      final adapter = _CannedAdapter(_ok({
        'committed': false,
        'rows': [
          {'row': 5, 'status': 'ok', 'item_code': 'W-1001'},
          {'row': 6, 'status': 'error', 'item_code': 'W-9999', 'message': 'Row 6: item W-9999 is not a DPL part.'},
          {'row': 7, 'status': 'skipped', 'message': 'Row 7: zero balance.'},
        ],
        'unmatched_items': ['W-9999'],
        'unmapped_locations': ['FG-OLD-3'],
        'totals': {'rows': 3, 'ok': 1, 'skipped': 1, 'errors': 1, 'lots': 1, 'qty': 120},
      }));
      final svc = _service(adapter);

      final res = await svc.importOpeningStock(bytes: Uint8List.fromList([1, 2, 3]), fileName: 'stock.xlsx');
      expect(res.isError, isFalse);
      final p = res.data!;
      expect(p.committed, isFalse);
      expect((p.rows, p.ok, p.skipped, p.errors, p.lots, p.qty), (3, 1, 1, 1, 1, 120));
      expect(p.unmatchedItems, ['W-9999']);
      expect(p.unmappedLocations, ['FG-OLD-3']);
      expect(p.problemRows.map((r) => r.row), [6, 7]);
      expect(p.problemRows.first.status, 'error');
      expect(p.problemRows.first.message, contains('W-9999'));
      expect(adapter.seen.single.queryParameters, isEmpty); // preview never commits
    });
  });

  group('error envelopes', () {
    test('message_local lands in errorLocal and floorMessage shows both', () async {
      final svc = _serviceReturning({
        'success': false,
        'error': 'Pallet P2600012 is already on trip 14.',
        'code': 'ALREADY_ON_TRIP',
        'message_local': 'पॅलेट P2600012 आधीच ट्रिप 14 वर आहे.',
        'lang': 'mr',
      });
      final res = await svc.getOemDashboard();
      expect(res.isError, isTrue);
      expect(res.code, 'ALREADY_ON_TRIP');
      expect(res.errorLocal, 'पॅलेट P2600012 आधीच ट्रिप 14 वर आहे.');
      expect(res.floorMessage, contains(res.errorLocal!));
      expect(res.floorMessage, contains('Pallet P2600012 is already on trip 14.'));
    });

    test('a 409 FIRST_OWN_LANE keeps its code so the lane dialog can ask', () async {
      final svc = _serviceReturning({
        'success': false,
        'error': 'This is the first lane of your own. Send confirm_own_lanes: true to go ahead.',
        'code': 'FIRST_OWN_LANE',
      }, status: 409);
      final res = await svc.saveLane({'code': 'MXN_X', 'name': 'X', 'machine_ids': [1]});
      expect(res.isError, isTrue);
      expect(res.statusCode, 409);
      expect(res.code, 'FIRST_OWN_LANE');
      expect(res.error, contains('first lane'));
    });

    test('a 409 IMPORT_EXISTS on commit keeps its code', () async {
      final svc = _serviceReturning({'success': false, 'error': 'An import exists.', 'code': 'IMPORT_EXISTS'}, status: 409);
      final res = await svc.importOpeningStock(bytes: Uint8List(1), fileName: 's.csv', commit: true);
      expect(res.code, 'IMPORT_EXISTS');
    });
  });

  group('DplOemDashboardScreen', () {
    Future<void> pump(WidgetTester tester, DplApiService svc) async {
      // Tall enough that the whole dashboard is built without scrolling.
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [dplApiServiceProvider.overrideWithValue(svc)],
          child: const MaterialApp(home: Scaffold(body: DplOemDashboardScreen(showAppBar: false))),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('renders each lane, stock and what needs attention', (tester) async {
      await pump(tester, _serviceReturning(_ok(_dashboardPayload())));

      expect(find.text('Tata Motors PV'), findsOneWidget);
      expect(find.text('Mahindra & Mahindra'), findsOneWidget);
      expect(find.text('Today: 300 of 400 wheels dispatched'), findsOneWidget);
      expect(find.text('75%'), findsOneWidget);
      // Stat tiles render their value as rich text.
      expect(find.text('5230', findRichText: true), findsOneWidget);
      expect(find.text('41 min', findRichText: true), findsOneWidget);
      expect(find.text('Half pallets older than 7 days'), findsOneWidget);
      // A zero counter is not something to attend to.
      expect(find.text('Pallets not put away'), findsNothing);
    });

    testWidgets('shows the empty state when there are no lanes', (tester) async {
      await pump(tester, _serviceReturning(_ok(_dashboardPayload(lanes: const []))));
      expect(find.text('No lanes yet'), findsOneWidget);
    });

    testWidgets('shows the server error with a retry', (tester) async {
      await pump(tester, _serviceReturning({'success': false, 'error': 'Not allowed.', 'code': 'FORBIDDEN_PERMISSION'}));
      expect(find.textContaining('Not allowed.'), findsOneWidget);
    });
  });

  testWidgets('DplStockReportsScreen renders totals and the first report table', (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final svc = _serviceReturning(_ok({
      'items': [
        {'customer_part_no': 'W-1001', 'description': 'Wheel 15x6', 'on_hand_qty': 480, 'full_pallets': 10},
      ],
      'totals': {'on_hand_qty': 480, 'full_pallets': 10},
    }));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dplApiServiceProvider.overrideWithValue(svc)],
        child: const MaterialApp(home: Scaffold(body: DplStockReportsScreen(showAppBar: false))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('FG stock'), findsOneWidget);
    expect(find.text('W-1001'), findsOneWidget);
    expect(find.text('480', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
