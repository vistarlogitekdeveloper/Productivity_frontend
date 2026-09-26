import '_json_helpers.dart';

/// One floor action recorded while offline (backend migration 164).
class DplSyncTxn {
  final String txnId;
  final int seq;
  final String type;
  final Map<String, dynamic> payload;
  final int userId;
  final DateTime occurredAt;

  const DplSyncTxn({
    required this.txnId,
    required this.seq,
    required this.type,
    required this.payload,
    required this.userId,
    required this.occurredAt,
  });

  Map<String, dynamic> toJson() => {
        'txn_id': txnId,
        'seq': seq,
        'type': type,
        'payload': payload,
        'user_id': userId,
        'occurred_at': occurredAt.toUtc().toIso8601String(),
      };

  factory DplSyncTxn.fromJson(Map<String, dynamic> j) => DplSyncTxn(
        txnId: parseStringOr(j['txn_id']),
        seq: parseIntOr(j['seq']),
        type: parseStringOr(j['type']),
        payload: j['payload'] is Map ? Map<String, dynamic>.from(j['payload']) : <String, dynamic>{},
        userId: parseIntOr(j['user_id']),
        occurredAt: parseDateTimeOrNull(j['occurred_at']) ?? DateTime.now(),
      );
}

class DplSyncOutcome {
  final int seq;
  final String type;
  final String status; // applied | rejected
  final String? code;
  final String? message;
  final Map<String, dynamic> result;

  const DplSyncOutcome({required this.seq, required this.type, required this.status, this.code, this.message, this.result = const {}});

  factory DplSyncOutcome.fromJson(Map<String, dynamic> j) => DplSyncOutcome(
        seq: parseIntOr(j['seq']),
        type: parseStringOr(j['type']),
        status: parseStringOr(j['status']),
        code: j['code'] as String?,
        message: j['message'] as String?,
        result: j['result'] is Map ? Map<String, dynamic>.from(j['result']) : const {},
      );
}

/// The server's answer to a push.
class DplSyncPushResult {
  final int accepted;
  final int duplicates;
  final List<DplSyncOutcome> applied;
  final int lastAppliedSeq;
  final int? waitingForSeq;
  final String? blockedTxnId;

  /// Sequence numbers this device reused with a different txn id; the server
  /// kept the first and ignored these. Worth surfacing: it means the device's
  /// counter went backwards (e.g. an app reinstall).
  final List<({String txnId, int seq})> seqConflicts;

  const DplSyncPushResult({
    required this.accepted,
    required this.duplicates,
    required this.applied,
    required this.lastAppliedSeq,
    this.waitingForSeq,
    this.blockedTxnId,
    this.seqConflicts = const [],
  });

  bool get isBlocked => blockedTxnId != null;

  factory DplSyncPushResult.fromJson(Map<String, dynamic> j) {
    final b = j['blocked'];
    return DplSyncPushResult(
      accepted: parseIntOr(j['accepted']),
      duplicates: parseIntOr(j['duplicates']),
      applied: (j['applied'] is List)
          ? (j['applied'] as List).whereType<Map>().map((e) => DplSyncOutcome.fromJson(Map<String, dynamic>.from(e))).toList()
          : const [],
      lastAppliedSeq: parseIntOr(j['last_applied_seq']),
      waitingForSeq: parseIntOrNull(j['waiting_for_seq']),
      blockedTxnId: b is Map ? b['txn_id']?.toString() : null,
      seqConflicts: (j['seq_conflicts'] is List)
          ? (j['seq_conflicts'] as List).whereType<Map>().map((c) => (txnId: parseStringOr(c['txn_id']), seq: parseIntOr(c['seq']))).toList()
          : const [],
    );
  }
}

/// A transaction the rules refused, waiting on a supervisor.
class DplSyncConflict {
  final int id;
  final String deviceId;
  final int seq;
  final String type;
  final String? operator;
  final String? code;
  final String? message;
  final DateTime? occurredAt;

  const DplSyncConflict({required this.id, required this.deviceId, required this.seq, required this.type, this.operator, this.code, this.message, this.occurredAt});

  factory DplSyncConflict.fromJson(Map<String, dynamic> j) => DplSyncConflict(
        id: parseIntOr(j['id']),
        deviceId: parseStringOr(j['device_id']),
        seq: parseIntOr(j['seq']),
        type: parseStringOr(j['type']),
        operator: j['operator'] as String?,
        code: j['code'] as String?,
        message: j['message'] as String?,
        occurredAt: parseDateTimeOrNull(j['occurred_at']),
      );
}
