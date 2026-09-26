import '../../../../core/constants/app_constants.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/dpl_api_service.dart';
import '../../models/dpl_sync.dart';

/// Offline outbox for handheld floor actions (backend API.md §12).
///
/// ## The contract this file keeps
///
/// The server applies a device's transactions exactly once and strictly in
/// `seq` order, keyed by `(device_id, txn_id)`. So the device must:
///   * keep ONE stable device id for as long as it holds a sequence counter,
///   * never hand out the same `seq` twice, and never go backwards,
///   * never drop a transaction until the server has confirmed it.
///
/// All three live together in [SharedPreferences] and are always written
/// together ([DplOfflineOutbox._persist]), so a store that loses one loses all
/// three — which the server reads as a brand-new device, never as a reused
/// sequence number.
///
/// A refusal on replay blocks the device on the server until a supervisor skips
/// or retries it. The outbox keeps pushing on its timer while blocked: a resend
/// is harmless (counted as a duplicate) and it is how the device learns that
/// the supervisor has cleared the block.

/// SharedPreferences keys. Public so tests and support tooling agree.
// Defined once in AppConstants so logout's clearAll() keeps them (they belong
// to the device, not the signed-in person).
const String kDplSyncOutboxKey = AppConstants.dplSyncOutboxKey;
const String kDplSyncNextSeqKey = AppConstants.dplSyncNextSeqKey;
const String kDplDeviceIdKey = AppConstants.dplDeviceIdKey;

/// The server takes at most this many transactions per push.
const int kDplSyncMaxBatch = 500;

/// Which of [queued] the device must still hold after the server answered [r].
///
/// Drops every transaction the server has confirmed: anything at or below
/// `last_applied_seq` (applied, skipped by a supervisor, or a resent duplicate
/// of either), plus anything listed in `applied[]` with status `applied`.
///
/// Keeps everything else — the refused transaction the device is blocked on,
/// everything queued behind it, and anything behind a `waiting_for_seq` gap —
/// because only an explicit confirmation may remove a floor action from the
/// device. The server holds its own copy of whatever it accepted, so keeping
/// one here too costs a duplicate count on the next push and nothing more.
///
/// The result is sorted by `seq`.
List<DplSyncTxn> remainingAfterPush(List<DplSyncTxn> queued, DplSyncPushResult r) {
  final appliedSeqs = <int>{
    for (final o in r.applied)
      if (o.status == 'applied') o.seq,
  };
  final kept = queued.where((t) => t.seq > r.lastAppliedSeq && !appliedSeqs.contains(t.seq)).toList()
    ..sort((a, b) => a.seq.compareTo(b.seq));
  return kept;
}

/// A new device id: `HHT-` plus 10 base-36 characters. Matches the server's
/// `^[A-Za-z0-9._:-]{3,64}$`.
String generateDplDeviceId([Random? random]) {
  final rnd = random ?? Random.secure();
  const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
  final b = StringBuffer('HHT-');
  for (var i = 0; i < 10; i++) {
    b.write(alphabet[rnd.nextInt(alphabet.length)]);
  }
  return b.toString().toUpperCase();
}

@immutable
class DplOutboxState {
  /// Null until the store has been read.
  final String? deviceId;

  /// Waiting to be confirmed by the server, in `seq` order.
  final List<DplSyncTxn> queue;

  final bool loaded;
  final bool flushing;

  /// The server refused a transaction and is holding this device's queue
  /// until a supervisor resolves it.
  final bool blocked;
  final String? blockedTxnId;

  /// Why the last push did not reach the server, or what it refused.
  final String? lastError;

  /// The error code of the last failed push (`NETWORK`, `TIMEOUT`, …).
  final String? lastErrorCode;

  final DplSyncPushResult? lastResult;
  final DateTime? lastSyncAt;

  const DplOutboxState({
    this.deviceId,
    this.queue = const [],
    this.loaded = false,
    this.flushing = false,
    this.blocked = false,
    this.blockedTxnId,
    this.lastError,
    this.lastErrorCode,
    this.lastResult,
    this.lastSyncAt,
  });

  int get pending => queue.length;
  bool get hasPending => queue.isNotEmpty;

  /// Last push failed for connectivity reasons.
  bool get offline => lastErrorCode == 'NETWORK' || lastErrorCode == 'TIMEOUT';

  /// Queued transactions of [type] whose payload matches [where].
  int pendingOf(String type, {Map<String, dynamic> where = const {}}) => queue
      .where((t) => t.type == type && where.entries.every((e) => t.payload[e.key] == e.value))
      .length;

  DplOutboxState copyWith({
    String? deviceId,
    List<DplSyncTxn>? queue,
    bool? loaded,
    bool? flushing,
    bool? blocked,
    String? blockedTxnId,
    String? lastError,
    String? lastErrorCode,
    DplSyncPushResult? lastResult,
    DateTime? lastSyncAt,
    bool clearError = false,
    bool clearBlockedTxn = false,
  }) {
    return DplOutboxState(
      deviceId: deviceId ?? this.deviceId,
      queue: queue ?? this.queue,
      loaded: loaded ?? this.loaded,
      flushing: flushing ?? this.flushing,
      blocked: blocked ?? this.blocked,
      blockedTxnId: clearBlockedTxn ? null : (blockedTxnId ?? this.blockedTxnId),
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastErrorCode: clearError ? null : (lastErrorCode ?? this.lastErrorCode),
      lastResult: lastResult ?? this.lastResult,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    );
  }
}

/// The persisted queue of offline floor actions and its push loop.
class DplOfflineOutbox extends Notifier<DplOutboxState> {
  /// Auto-flush cadence while anything is queued.
  static const Duration flushEvery = Duration(seconds: 30);

  Future<void>? _loading;
  Future<DplSyncPushResult?>? _inFlight;
  Timer? _timer;

  String _deviceId = '';
  int _nextSeq = 1;
  List<DplSyncTxn> _queue = [];

  @override
  DplOutboxState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    _loading = _load();
    return const DplOutboxState();
  }

  /// The stable id this handheld pushes under. Empty until [ready] completes.
  String get deviceId => _deviceId;

  /// Transactions not yet confirmed by the server.
  int get pending => _queue.length;

  /// A snapshot of the queue, in `seq` order.
  List<DplSyncTxn> get queued => List.unmodifiable(_queue);

  /// Completes once the stored queue, counter and device id have been read.
  Future<void> ready() => _loading ??= _load();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(kDplDeviceIdKey);
    final fresh = id == null || id.isEmpty;
    if (fresh) {
      id = generateDplDeviceId();
      await prefs.setString(kDplDeviceIdKey, id);
    }
    final raw = prefs.getString(kDplSyncOutboxKey);
    final queue = <DplSyncTxn>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded.whereType<Map>()) {
            queue.add(DplSyncTxn.fromJson(Map<String, dynamic>.from(e)));
          }
        }
      } catch (e) {
        // A corrupt store must not wipe itself: leave the raw value in place
        // for support to recover, and start this session with an empty queue.
        debugPrint('DplOfflineOutbox: could not read the outbox: $e');
      }
    }
    queue.sort((a, b) => a.seq.compareTo(b.seq));
    final storedNext = prefs.getInt(kDplSyncNextSeqKey) ?? 1;
    final maxQueued = queue.isEmpty ? 0 : queue.last.seq;
    // Never hand out a seq at or below one already queued, even if the
    // counter was lost on its own.
    _nextSeq = max(storedNext, maxQueued + 1);
    _deviceId = id;
    _queue = queue;
    if (!ref.mounted) return;
    state = state.copyWith(deviceId: _deviceId, queue: List.unmodifiable(_queue), loaded: true);
    _syncTimer();
  }

  /// Records one floor action for replay. Assigns the next `seq` and a
  /// `txn_id` of `<deviceId>-<seq>`, and persists before returning, so a
  /// crash right after an operator's scan cannot lose it.
  Future<DplSyncTxn> enqueue(String type, Map<String, dynamic> payload, {required int userId}) async {
    await ready();
    // Everything from here to the list add is synchronous, so two concurrent
    // enqueues can never draw the same seq.
    final seq = _nextSeq++;
    final txn = DplSyncTxn(
      txnId: '$_deviceId-$seq',
      seq: seq,
      type: type,
      payload: Map<String, dynamic>.unmodifiable(payload),
      userId: userId,
      occurredAt: DateTime.now(),
    );
    _queue = [..._queue, txn];
    _publish();
    await _persist();
    _syncTimer();
    return txn;
  }

  /// Pushes everything queued, in `seq` order.
  ///
  /// Returns the server's answer to the last push, or null when nothing was
  /// sent or it did not reach the server. Never removes a transaction the
  /// server has not confirmed; see [remainingAfterPush]. Concurrent calls
  /// share the push already in flight.
  Future<DplSyncPushResult?> flush() {
    return _inFlight ??= _flush().whenComplete(() => _inFlight = null);
  }

  Future<DplSyncPushResult?> _flush() async {
    await ready();
    if (_queue.isEmpty) {
      _syncTimer();
      return null;
    }
    if (ref.mounted) state = state.copyWith(flushing: true);
    DplSyncPushResult? last;
    try {
      final api = ref.read(dplApiServiceProvider);
      while (_queue.isNotEmpty) {
        final batch = _queue.take(kDplSyncMaxBatch).toList();
        final res = await api.pushSync(_deviceId, batch);
        if (!ref.mounted) return res.data;
        if (res.isError || res.data == null) {
          state = state.copyWith(
            lastError: res.error ?? 'Could not sync.',
            lastErrorCode: res.code ?? 'ERROR',
          );
          break;
        }
        final r = res.data!;
        last = r;
        final before = _queue.length;
        // Applied to the CURRENT queue, not the batch: anything enqueued while
        // the push was in flight has a higher seq and is kept.
        _queue = remainingAfterPush(_queue, r);
        await _persist();
        if (!ref.mounted) return r;
        state = state.copyWith(
          queue: List.unmodifiable(_queue),
          lastResult: r,
          lastSyncAt: DateTime.now(),
          blocked: r.isBlocked,
          blockedTxnId: r.blockedTxnId,
          clearBlockedTxn: !r.isBlocked,
          clearError: true,
        );
        // Only go round again for a second full batch that made progress.
        final progressed = _queue.length < before;
        if (r.isBlocked || r.waitingForSeq != null || !progressed || batch.length < kDplSyncMaxBatch) break;
      }
    } finally {
      if (ref.mounted) {
        state = state.copyWith(flushing: false);
        _syncTimer();
      }
    }
    return last;
  }

  void _publish() {
    if (!ref.mounted) return;
    state = state.copyWith(deviceId: _deviceId, queue: List.unmodifiable(_queue));
  }

  /// Writes id, counter and queue together — see the class notes.
  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kDplDeviceIdKey, _deviceId);
    await prefs.setInt(kDplSyncNextSeqKey, _nextSeq);
    await prefs.setString(kDplSyncOutboxKey, jsonEncode(_queue.map((t) => t.toJson()).toList()));
  }

  void _syncTimer() {
    if (_queue.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(flushEvery, (_) => flush());
  }
}

final dplOfflineOutboxProvider = NotifierProvider<DplOfflineOutbox, DplOutboxState>(DplOfflineOutbox.new);
