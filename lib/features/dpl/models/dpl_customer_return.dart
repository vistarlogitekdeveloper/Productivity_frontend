import '_json_helpers.dart';

/// One line on a customer return: a scanned wheel, or a counted manual lot.
class DplReturnLine {
  final int lineId;
  final String kind; // wheel | manual
  final String? serialNo;
  final int partId;
  final String? customerPartNo;
  final String? description;
  final int qty;
  final String? originalPalletNo;
  final String? note;
  final String disposition; // pending | restocked | scrapped
  final String? dispositionNote;

  const DplReturnLine({
    required this.lineId,
    required this.kind,
    required this.partId,
    required this.qty,
    required this.disposition,
    this.serialNo,
    this.customerPartNo,
    this.description,
    this.originalPalletNo,
    this.note,
    this.dispositionNote,
  });

  bool get isPending => disposition == 'pending';

  factory DplReturnLine.fromJson(Map<String, dynamic> j) => DplReturnLine(
        lineId: parseIntOr(j['line_id']),
        kind: parseStringOr(j['kind'], 'wheel'),
        serialNo: j['serial_no'] as String?,
        partId: parseIntOr(j['part_id']),
        customerPartNo: j['customer_part_no'] as String?,
        description: j['description'] as String?,
        qty: parseIntOr(j['qty'], 1),
        originalPalletNo: j['original_pallet_no'] as String?,
        note: j['note'] as String?,
        disposition: parseStringOr(j['disposition'], 'pending'),
        dispositionNote: j['disposition_note'] as String?,
      );
}

/// A return note (RN…) with its lines.
class DplCustomerReturn {
  final int returnId;
  final String returnNo;
  final String status; // open | closed
  final String reason;
  final String? referenceNo;
  final String? consigneeName;
  final DateTime? receivedAt;
  final List<DplReturnLine> lines;
  final int totalQty;
  final int pending;
  final int restocked;
  final int scrapped;

  const DplCustomerReturn({
    required this.returnId,
    required this.returnNo,
    required this.status,
    required this.reason,
    this.referenceNo,
    this.consigneeName,
    this.receivedAt,
    this.lines = const [],
    this.totalQty = 0,
    this.pending = 0,
    this.restocked = 0,
    this.scrapped = 0,
  });

  bool get isOpen => status == 'open';

  factory DplCustomerReturn.fromJson(Map<String, dynamic> j) {
    final totals = j['totals'] is Map ? Map<String, dynamic>.from(j['totals']) : <String, dynamic>{};
    final consignee = j['consignee'];
    return DplCustomerReturn(
      returnId: parseIntOr(j['return_id']),
      returnNo: parseStringOr(j['return_no']),
      status: parseStringOr(j['status'], 'open'),
      reason: parseStringOr(j['reason']),
      referenceNo: j['reference_no'] as String?,
      consigneeName: consignee is Map ? consignee['name']?.toString() : null,
      receivedAt: parseDateTimeOrNull(j['received_at']),
      lines: (j['lines'] is List)
          ? (j['lines'] as List).whereType<Map>().map((e) => DplReturnLine.fromJson(Map<String, dynamic>.from(e))).toList()
          : const [],
      totalQty: parseIntOr(totals['qty']),
      pending: parseIntOr(totals['pending']),
      restocked: parseIntOr(totals['restocked']),
      scrapped: parseIntOr(totals['scrapped']),
    );
  }
}
