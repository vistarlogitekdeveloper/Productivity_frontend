import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vistar_event_tracker/src/event_queue.dart';
import 'package:vistar_event_tracker/src/identity_manager.dart';
import 'package:vistar_event_tracker/src/logger.dart';
import 'package:vistar_event_tracker/src/session_manager.dart';
import 'package:vistar_event_tracker/src/uuid.dart';
import 'package:vistar_event_tracker/vistar_event_tracker.dart';

/// Records batches instead of sending them; scriptable per-batch result.
class FakeApiClient implements ApiClient {
  FakeApiClient({this.result = SendResult.success});
  SendResult result;
  final List<List<Map<String, dynamic>>> batches = [];
  int get eventCount => batches.fold(0, (n, b) => n + b.length);

  @override
  Future<SendResult> send(List<Map<String, dynamic>> events) async {
    batches.add(events);
    return result;
  }
}

const _queueKey = 'vet_queue_v1'; // must match EventQueue._key

TrackerConfig cfg({int maxBatch = 50, int maxQueue = 1000}) => TrackerConfig(
      appId: 'vistar_driver_app',
      writeKey: 'wk_test',
      baseUrl: 'https://api.example.test',
      maxBatchSize: maxBatch,
      maxQueueSize: maxQueue,
      captureAppOpen: false,
    );

Event ev(String name) => Event(eventId: uuidV4(), eventName: name, eventType: EventType.action);

void main() {
  final logger = TrackerLogger(false);

  group('uuid', () {
    test('is a valid v4 uuid and unique', () {
      final re = RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      for (var i = 0; i < 100; i++) {
        expect(re.hasMatch(uuidV4()), isTrue);
      }
      expect(uuidV4(), isNot(equals(uuidV4())));
    });
  });

  group('Event.toJson', () {
    test('matches the backend envelope and omits null optionals', () {
      final e = Event(
        eventId: 'id',
        eventName: 'order_placed',
        eventType: EventType.action,
        sessionId: 's',
        tsClient: '2026-08-04T00:00:00.000Z',
        properties: {'amount': 250},
      );
      final j = e.toJson();
      expect(j['event_name'], 'order_placed');
      expect(j['event_type'], 'action');
      expect(j['session_id'], 's');
      expect(j.containsKey('user_id'), isFalse); // null omitted
      expect(j.containsKey('anonymous_id'), isFalse);
      expect(j['properties'], {'amount': 250});
      expect(j['context'], {});
      expect(j.containsKey('app_id'), isFalse); // header-supplied, never in body
    });
  });

  group('SessionManager', () {
    test('rotates after inactivity and on reset', () {
      final s = SessionManager(const Duration(minutes: 30));
      final t0 = DateTime.utc(2026, 8, 4, 10);
      final a = s.touch(t0);
      expect(a.isNew, isTrue);
      final b = s.touch(t0.add(const Duration(minutes: 5)));
      expect(b.isNew, isFalse);
      expect(b.id, a.id);
      final c = s.touch(t0.add(const Duration(minutes: 40)));
      expect(c.isNew, isTrue); // idle > 30 min -> new session
      expect(c.id, isNot(a.id));
      s.rotate();
      final d = s.touch(t0.add(const Duration(minutes: 41)));
      expect(d.isNew, isTrue);
      expect(d.id, isNot(c.id));
    });
  });

  group('IdentityManager', () {
    test('persists anonymous_id and links/clears user_id', () async {
      final store = InMemoryStore();
      final id1 = IdentityManager(store);
      await id1.load();
      final anon = id1.anonymousId;
      expect(anon, isNotEmpty);

      final id2 = IdentityManager(store);
      await id2.load();
      expect(id2.anonymousId, anon); // stable across reload

      await id2.identify('u_42', {'plan': 'pro'});
      expect(id2.userId, 'u_42');
      expect(id2.traits['plan'], 'pro');

      await id2.reset();
      expect(id2.userId, isNull);
      expect(id2.anonymousId, isNot(anon)); // fresh anon on logout
    });
  });

  group('EventQueue', () {
    // Seed the store directly so flush() behaviour is deterministic (no reliance
    // on fire-and-forget auto-flush timing).
    Future<InMemoryStore> seeded(List<String> names) async {
      final store = InMemoryStore();
      await store.setString(_queueKey, jsonEncode(names.map((n) => ev(n).encode()).toList()));
      return store;
    }

    test('flush drains in maxBatchSize batches and clears on success', () async {
      final store = await seeded(['e0', 'e1', 'e2', 'e3', 'e4']);
      final api = FakeApiClient();
      final q = EventQueue(config: cfg(maxBatch: 2), store: store, api: api, logger: logger);
      await q.restore();
      expect(q.length, 5);
      await q.flush();
      expect(q.length, 0);
      expect(api.eventCount, 5);
      expect(api.batches.map((b) => b.length).toList(), [2, 2, 1]);
    });

    test('keeps events and backs off on retryable failure', () async {
      final api = FakeApiClient(result: SendResult.retry);
      final q = EventQueue(config: cfg(), store: InMemoryStore(), api: api, logger: logger);
      q.enqueue(ev('a'));
      final now = DateTime.utc(2026, 8, 4);
      await q.flush(now: now);
      expect(q.length, 1); // retained
      expect(q.failureCount, 1);
      expect(q.nextAllowedAt, isNotNull);

      await q.flush(now: now); // backoff gate blocks immediate retry
      expect(api.batches.length, 1);

      api.result = SendResult.success;
      await q.flush(now: q.nextAllowedAt!.add(const Duration(seconds: 1)));
      expect(q.length, 0);
    });

    test('drops non-retryable (4xx) batches so the queue never wedges', () async {
      final api = FakeApiClient(result: SendResult.dropped);
      final q = EventQueue(config: cfg(), store: InMemoryStore(), api: api, logger: logger);
      q.enqueue(ev('bad'));
      await q.flush();
      expect(q.length, 0);
    });

    test('caps at maxQueueSize, discarding oldest first', () {
      final api = FakeApiClient(result: SendResult.retry); // never drains
      final q = EventQueue(config: cfg(maxBatch: 3, maxQueue: 3), store: InMemoryStore(), api: api, logger: logger);
      for (var i = 0; i < 6; i++) {
        q.enqueue(Event(eventId: 'id$i', eventName: 'e$i', eventType: EventType.action));
      }
      expect(q.length, 3);
    });

    test('restores persisted events across a restart', () async {
      final store = await seeded(['persist_me']);
      final api = FakeApiClient();
      final q = EventQueue(config: cfg(), store: store, api: api, logger: logger);
      await q.restore();
      expect(q.length, 1);
      await q.flush();
      expect(api.eventCount, 1);
    });
  });

  group('config', () {
    test('builds a clean ingest url', () {
      expect(cfg().ingestUrl, 'https://api.example.test/api/v1/eventtracker/events');
      final trailing = TrackerConfig(appId: 'a', writeKey: 'w', baseUrl: 'https://x.test/');
      expect(trailing.ingestUrl, 'https://x.test/api/v1/eventtracker/events');
    });
  });

  group('encode/decode round-trip', () {
    test('event survives queue persistence', () {
      final e = Event(
        eventId: 'i',
        eventName: 'screen_viewed',
        eventType: EventType.screenView,
        properties: {'screen': 'Home'},
        context: {'platform': 'android'},
      );
      final decoded = Event.decode(e.encode());
      expect(decoded['event_name'], 'screen_viewed');
      expect((decoded['properties'] as Map)['screen'], 'Home');
      expect(jsonEncode(decoded), jsonEncode(e.toJson()));
    });
  });
}
