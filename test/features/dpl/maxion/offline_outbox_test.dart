import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_api_service.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_permissions_provider.dart';
import 'package:productivity_tracker/features/dpl/maxion/sync/offline_outbox.dart';
import 'package:productivity_tracker/features/dpl/maxion/sync/offline_scan.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Offline outbox (backend API.md §12): the device must never reuse a seq,
/// never drop a floor action the server has not confirmed, and never queue a
/// business refusal as if it were a dead zone.

typedef _Handler = FutureOr<ResponseBody> Function(RequestOptions o);

/// Routes every request to [handler] and records it. Throwing a
/// [DioException] from the handler simulates a transport failure.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  _Handler handler;
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

_Handler _offline() => (o) => throw DioException(requestOptions: o, type: DioExceptionType.connectionError);

class _Perms extends DplPermissionsController {
  _Perms(this.keys);
  final List<String> keys;
  @override
  DplPermissions build() => DplPermissions.of(keys);
}

DplSyncTxn _txn(int seq) => DplSyncTxn(
      txnId: 'HHT-T-$seq',
      seq: seq,
      type: 'trip.scan',
      payload: {'trip_id': 1, 'code': 'GA26000000$seq'},
      userId: 9,
      occurredAt: DateTime.utc(2026, 9, 25),
    );

DplSyncPushResult _result({required int lastApplied, List<Map<String, dynamic>> applied = const [], String? blocked, int duplicates = 0}) =>
    DplSyncPushResult.fromJson({
      'accepted': applied.length,
      'duplicates': duplicates,
      'applied': applied,
      'last_applied_seq': lastApplied,
      'blocked': blocked == null ? null : {'txn_id': blocked},
    });

({ProviderContainer container, _FakeAdapter adapter}) _setup(_Handler handler, {List<String> perms = const [DplPermission.syncPush]}) {
  final adapter = _FakeAdapter(handler);
  final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api/v1/dpl'))..httpClientAdapter = adapter;
  final container = ProviderContainer(overrides: [
    dplApiServiceProvider.overrideWithValue(DplApiService(dio)),
    dplPermissionsProvider.overrideWith(() => _Perms(perms)),
  ]);
  return (container: container, adapter: adapter);
}

Map<String, dynamic> _body(RequestOptions o) => Map<String, dynamic>.from(o.data as Map);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('remainingAfterPush', () {
    test('drops everything up to last_applied_seq', () {
      final left = remainingAfterPush([_txn(1), _txn(2), _txn(3)], _result(lastApplied: 3, applied: [
        {'seq': 1, 'type': 'trip.scan', 'status': 'applied'},
        {'seq': 2, 'type': 'trip.scan', 'status': 'applied'},
        {'seq': 3, 'type': 'trip.scan', 'status': 'applied'},
      ]));
      expect(left, isEmpty);
    });

    test('drops resent duplicates the server already applied (seq <= last_applied_seq)', () {
      // A resend after a lost response: nothing new applied, all counted as
      // duplicates, but last_applied_seq says the server has them.
      final left = remainingAfterPush([_txn(4), _txn(5), _txn(6)], _result(lastApplied: 5, duplicates: 3));
      expect(left.map((t) => t.seq), [6]);
    });

    test('keeps the refused txn and everything behind it while blocked', () {
      final left = remainingAfterPush(
        [_txn(3), _txn(1), _txn(2), _txn(4)],
        _result(lastApplied: 1, blocked: 'HHT-T-2', applied: [
          {'seq': 1, 'type': 'trip.scan', 'status': 'applied'},
          {'seq': 2, 'type': 'trip.scan', 'status': 'rejected', 'code': 'PLAN_ALREADY_FULL'},
        ]),
      );
      expect(left.map((t) => t.seq), [2, 3, 4], reason: 'sorted, refused one kept');
    });

    test('keeps everything behind a waiting_for_seq gap', () {
      final left = remainingAfterPush([_txn(7), _txn(8)], DplSyncPushResult.fromJson({
        'accepted': 2,
        'duplicates': 0,
        'applied': const [],
        'last_applied_seq': 5,
        'waiting_for_seq': 6,
        'blocked': null,
      }));
      expect(left.map((t) => t.seq), [7, 8]);
    });

    test('drops a txn listed as applied even if last_applied_seq lags', () {
      final left = remainingAfterPush([_txn(1), _txn(2)], _result(lastApplied: 0, applied: [
        {'seq': 2, 'type': 'trip.scan', 'status': 'applied'},
      ]));
      expect(left.map((t) => t.seq), [1]);
    });
  });

  group('DplOfflineOutbox', () {
    test('device id is generated once, matches the server pattern, and is stored', () async {
      final s = _setup(_offline());
      addTearDown(s.container.dispose);
      final outbox = s.container.read(dplOfflineOutboxProvider.notifier);
      await outbox.ready();
      expect(outbox.deviceId, matches(RegExp(r'^HHT-[A-Z0-9]{10}$')));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kDplDeviceIdKey), outbox.deviceId);
    });

    test('enqueue assigns strictly increasing seq and unique txn ids, and persists across instances', () async {
      final a = _setup(_offline());
      final outbox = a.container.read(dplOfflineOutboxProvider.notifier);
      final t1 = await outbox.enqueue('trip.scan', {'trip_id': 1, 'code': 'A'}, userId: 9);
      final t2 = await outbox.enqueue('trip.scan', {'trip_id': 1, 'code': 'B'}, userId: 9);
      // Concurrent enqueues must still get distinct seqs.
      final both = await Future.wait([
        outbox.enqueue('pallet.scan', {'pallet_id': 4, 'code': 'C'}, userId: 9),
        outbox.enqueue('pallet.scan', {'pallet_id': 4, 'code': 'D'}, userId: 9),
      ]);
      final all = [t1, t2, ...both];
      expect(all.map((t) => t.seq), [1, 2, 3, 4]);
      expect(all.map((t) => t.txnId).toSet().length, 4);
      expect(t1.txnId, '${outbox.deviceId}-1');
      expect(t1.userId, 9);
      expect(a.container.read(dplOfflineOutboxProvider).pending, 4);
      final deviceId = outbox.deviceId;
      a.container.dispose();

      final b = _setup(_offline());
      addTearDown(b.container.dispose);
      final again = b.container.read(dplOfflineOutboxProvider.notifier);
      await again.ready();
      expect(again.deviceId, deviceId);
      expect(again.queued.map((t) => t.seq), [1, 2, 3, 4]);
      expect(again.queued.first.payload, {'trip_id': 1, 'code': 'A'});
      expect(b.container.read(dplOfflineOutboxProvider).pending, 4);
      final t5 = await again.enqueue('trip.scan', {'trip_id': 1, 'code': 'E'}, userId: 9);
      expect(t5.seq, 5, reason: 'the counter survives a restart');
    });

    test('never reuses a seq below one still queued even if the counter was lost', () async {
      SharedPreferences.setMockInitialValues({
        kDplDeviceIdKey: 'HHT-FIXED00001',
        kDplSyncOutboxKey: jsonEncode([_txn(41).toJson(), _txn(42).toJson()]),
      });
      final s = _setup(_offline());
      addTearDown(s.container.dispose);
      final t = await s.container.read(dplOfflineOutboxProvider.notifier).enqueue('trip.scan', {'trip_id': 1, 'code': 'X'}, userId: 1);
      expect(t.seq, 43);
      expect(t.txnId, 'HHT-FIXED00001-43');
    });

    test('flush on a NETWORK error keeps everything queued', () async {
      final s = _setup(_offline());
      addTearDown(s.container.dispose);
      final outbox = s.container.read(dplOfflineOutboxProvider.notifier);
      await outbox.enqueue('trip.scan', {'trip_id': 1, 'code': 'A'}, userId: 9);
      await outbox.enqueue('trip.scan', {'trip_id': 1, 'code': 'B'}, userId: 9);

      final r = await outbox.flush();
      expect(r, isNull);
      final st = s.container.read(dplOfflineOutboxProvider);
      expect(st.pending, 2);
      expect(st.lastErrorCode, 'NETWORK');
      expect(st.offline, isTrue);
      expect(st.flushing, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect((jsonDecode(prefs.getString(kDplSyncOutboxKey)!) as List).length, 2, reason: 'still on disk');
    });

    test('flush with a success envelope clears what was applied and sends in seq order', () async {
      final s = _setup((o) => _json({
            'success': true,
            'data': {
              'device_id': 'x',
              'accepted': 2,
              'duplicates': 0,
              'seq_conflicts': const [],
              'applied': [
                {'seq': 1, 'type': 'trip.scan', 'status': 'applied', 'result': {}},
                {'seq': 2, 'type': 'trip.scan', 'status': 'applied', 'result': {}},
              ],
              'waiting_for_seq': null,
              'last_applied_seq': 2,
              'blocked': null,
            },
          }));
      addTearDown(s.container.dispose);
      final outbox = s.container.read(dplOfflineOutboxProvider.notifier);
      await outbox.enqueue('trip.scan', {'trip_id': 1, 'code': 'A'}, userId: 9);
      await outbox.enqueue('count.scan', {'count_id': 3, 'code': 'B', 'location_id': 5}, userId: 9);

      final r = await outbox.flush();
      expect(r, isNotNull);
      expect(r!.lastAppliedSeq, 2);
      final st = s.container.read(dplOfflineOutboxProvider);
      expect(st.pending, 0);
      expect(st.blocked, isFalse);
      expect(st.lastError, isNull);

      final req = s.adapter.requests.single;
      expect(req.path, endsWith('/sync/push'));
      final body = _body(req);
      expect(body['device_id'], outbox.deviceId);
      final txns = (body['transactions'] as List).cast<Map>();
      expect(txns.map((t) => t['seq']), [1, 2]);
      expect(txns[1]['type'], 'count.scan');
      expect(txns[1]['payload'], {'count_id': 3, 'code': 'B', 'location_id': 5});
      expect(txns[0]['user_id'], 9);
    });

    test('flush while blocked keeps the refused txn and flags the device', () async {
      final s = _setup((o) => _json({
            'success': true,
            'data': {
              'accepted': 3,
              'duplicates': 0,
              'applied': [
                {'seq': 1, 'type': 'trip.scan', 'status': 'applied'},
                {'seq': 2, 'type': 'trip.scan', 'status': 'rejected', 'code': 'ALREADY_ON_ANOTHER_TRIP', 'message': 'no'},
              ],
              'last_applied_seq': 1,
              'blocked': {'txn_id': 'whatever-2', 'since': '2026-09-25T10:00:00Z'},
            },
          }));
      addTearDown(s.container.dispose);
      final outbox = s.container.read(dplOfflineOutboxProvider.notifier);
      for (final c in ['A', 'B', 'C']) {
        await outbox.enqueue('trip.scan', {'trip_id': 1, 'code': c}, userId: 9);
      }
      await outbox.flush();
      final st = s.container.read(dplOfflineOutboxProvider);
      expect(st.queue.map((t) => t.seq), [2, 3]);
      expect(st.blocked, isTrue);
      expect(st.blockedTxnId, 'whatever-2');
    });
  });

  group('scan helpers', () {
    Future<WidgetRef> pumpRef(WidgetTester tester, ProviderContainer container) async {
      late WidgetRef captured;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          captured = ref;
          return const SizedBox();
        }),
      ));
      return captured;
    }

    testWidgets('queue a trip scan on NETWORK', (tester) async {
      final s = _setup(_offline());
      final ref = await pumpRef(tester, s.container);
      final r = (await tester.runAsync(() => scanToTripOrQueue(ref, tripId: 12, code: 'GA2600000001', userId: 9)))!;
      expect(r.isQueued, isTrue);
      expect(r.txn!.type, 'trip.scan');
      expect(r.txn!.payload, {'trip_id': 12, 'code': 'GA2600000001'});
      expect(r.response!.code, 'NETWORK');
      expect(s.container.read(dplOfflineOutboxProvider).pending, 1);
      await tester.pumpWidget(const SizedBox());
      s.container.dispose();
    });

    testWidgets('do NOT queue a 409 refusal', (tester) async {
      final s = _setup((o) => _json({'success': false, 'error': 'Already on trip T-9', 'code': 'ALREADY_ON_ANOTHER_TRIP'}, 409));
      final ref = await pumpRef(tester, s.container);
      final r = (await tester.runAsync(() => scanToTripOrQueue(ref, tripId: 12, code: 'GA2600000001', userId: 9)))!;
      expect(r.isRefused, isTrue);
      expect(r.response!.code, 'ALREADY_ON_ANOTHER_TRIP');
      expect(r.response!.statusCode, 409);
      expect(s.container.read(dplOfflineOutboxProvider).pending, 0);
      await tester.pumpWidget(const SizedBox());
      s.container.dispose();
    });

    testWidgets('count and pallet scans queue with their payloads; online success is not queued', (tester) async {
      var online = false;
      final s = _setup((o) => online
          ? _json({'success': true, 'data': {'pallet_no': 'P26000012', 'qty': 48, 'location_code': 'A-01', 'scanned': 3}})
          : throw DioException(requestOptions: o, type: DioExceptionType.receiveTimeout));
      final ref = await pumpRef(tester, s.container);

      final c = (await tester.runAsync(() => scanCountOrQueue(ref, countId: 3, locationId: 5, code: 'P26000012', userId: 9)))!;
      expect(c.isQueued, isTrue);
      expect(c.response!.code, 'TIMEOUT');
      expect(c.txn!.payload, {'count_id': 3, 'code': 'P26000012', 'location_id': 5});

      // With a backlog, a new scan goes behind it rather than live, so the
      // server sees this device's actions in order.
      final p = (await tester.runAsync(() => scanToPalletOrQueue(ref, palletId: 4, code: 'GA2600000002', userId: 9)))!;
      expect(p.isQueued, isTrue);
      expect(p.txn!.type, 'pallet.scan');
      expect(p.txn!.payload, {'pallet_id': 4, 'code': 'GA2600000002'});
      expect(p.txn!.seq, c.txn!.seq + 1);
      // Let the flush that queuing kicked off finish (it times out too).
      await tester.runAsync(() => s.container.read(dplOfflineOutboxProvider.notifier).flush());
      expect(s.container.read(dplOfflineOutboxProvider).pending, 2);

      // Empty the outbox, then a live success must not be queued.
      SharedPreferences.setMockInitialValues({});
      s.container.invalidate(dplOfflineOutboxProvider);
      online = true;
      final ok = (await tester.runAsync(() => scanCountOrQueue(ref, countId: 3, locationId: 5, code: 'P26000012', userId: 9)))!;
      expect(ok.isOnline, isTrue);
      expect(ok.data!['pallet_no'], 'P26000012');
      expect(s.adapter.requests.last.path, endsWith('/stock/counts/3/scan'));
      expect(_body(s.adapter.requests.last), {'code': 'P26000012', 'location_id': 5});
      expect(s.container.read(dplOfflineOutboxProvider).pending, 0);
      await tester.pumpWidget(const SizedBox());
      s.container.dispose();
    });

    testWidgets('without sync.push a NETWORK failure is returned, not queued', (tester) async {
      final s = _setup(_offline(), perms: const []);
      final ref = await pumpRef(tester, s.container);
      final r = (await tester.runAsync(() => scanToTripOrQueue(ref, tripId: 12, code: 'GA2600000001', userId: 9)))!;
      expect(r.isRefused, isTrue);
      expect(r.response!.code, 'NETWORK');
      expect(s.container.read(dplOfflineOutboxProvider).pending, 0);
      await tester.pumpWidget(const SizedBox());
      s.container.dispose();
    });
  });
}
