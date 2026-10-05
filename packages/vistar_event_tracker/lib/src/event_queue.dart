import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'api_client.dart';
import 'event.dart';
import 'logger.dart';
import 'storage.dart';
import 'tracker_config.dart';

/// Durable, batching event buffer.
///
/// - persists to [KeyValueStore] on every change so events survive restarts;
/// - flushes on a timer, when a full batch accumulates, and on demand;
/// - retries transient failures with exponential backoff, drops permanent ones;
/// - caps at [TrackerConfig.maxQueueSize], discarding the OLDEST events first.
///
/// Idempotency is inherent: each event carries a stable `event_id`, so a retried
/// batch is de-duplicated server-side (the backend's dedup ledger).
class EventQueue {
  EventQueue({
    required this.config,
    required this.store,
    required this.api,
    required this.logger,
  });

  final TrackerConfig config;
  final KeyValueStore store;
  final ApiClient api;
  final TrackerLogger logger;

  static const _key = 'vet_queue_v1';

  final List<String> _buf = []; // encoded events (JSON strings)
  Timer? _timer;
  bool _flushing = false;
  int _failures = 0;
  DateTime? _nextAllowed; // backoff gate

  /// Restore any events persisted from a previous run.
  Future<void> restore() async {
    final s = await store.getString(_key);
    if (s == null) return;
    try {
      final list = (jsonDecode(s) as List).cast<String>();
      _buf.addAll(list);
      logger.log('restored ${list.length} queued event(s)');
    } catch (_) {
      await store.remove(_key);
    }
  }

  Future<void> _persist() => store.setString(_key, jsonEncode(_buf));

  int get length => _buf.length;

  /// Add an event. Trims the oldest if over capacity, persists, and triggers a
  /// flush once a full batch is available.
  void enqueue(Event e) {
    _buf.add(e.encode());
    if (_buf.length > config.maxQueueSize) {
      final overflow = _buf.length - config.maxQueueSize;
      _buf.removeRange(0, overflow);
      logger.log('queue full — dropped $overflow oldest event(s)');
    }
    unawaited(_persist());
    if (_buf.length >= config.maxBatchSize) unawaited(flush());
  }

  /// Start the periodic flush timer.
  void start() {
    _timer ??= Timer.periodic(config.flushInterval, (_) => unawaited(flush()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Attempt to ship queued events. Respects the backoff gate and never runs
  /// two flushes concurrently.
  Future<void> flush({DateTime? now}) async {
    now ??= DateTime.now().toUtc();
    if (_flushing || _buf.isEmpty) return;
    if (_nextAllowed != null && now.isBefore(_nextAllowed!)) return;

    _flushing = true;
    try {
      while (_buf.isNotEmpty) {
        final take = _buf.take(config.maxBatchSize).toList();
        final events = take.map((s) => Event.decode(s)).toList();
        final result = await api.send(events);

        if (result == SendResult.success) {
          _buf.removeRange(0, take.length);
          await _persist();
          _failures = 0;
          _nextAllowed = null;
          logger.log('sent ${take.length} event(s)');
        } else if (result == SendResult.dropped) {
          _buf.removeRange(0, take.length);
          await _persist();
          logger.log('dropped ${take.length} event(s) (non-retryable)');
        } else {
          _failures++;
          _scheduleBackoff(now);
          logger.log('flush failed — retry #$_failures, backing off until $_nextAllowed');
          break;
        }
      }
    } finally {
      _flushing = false;
    }
  }

  void _scheduleBackoff(DateTime now) {
    final shift = min(_failures - 1, 16);
    final ms = min(config.maxBackoff.inMilliseconds,
        config.baseBackoff.inMilliseconds * (1 << shift));
    _nextAllowed = now.add(Duration(milliseconds: ms));
  }

  // Test/inspection hooks.
  DateTime? get nextAllowedAt => _nextAllowed;
  int get failureCount => _failures;
}
