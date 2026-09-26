import '_json_helpers.dart';

/// Unlabelled lot stock, e.g. the opening balance from Ekatm (migration 162).
class DplStockLot {
  final int lotId;
  final int partId;
  final String? customerPartNo;
  final String? lotNo;
  final String? sourceLocationCode;
  final String? fifoDate;
  final int openingQty;
  final int qtyRemaining;

  const DplStockLot({
    required this.lotId,
    required this.partId,
    required this.openingQty,
    required this.qtyRemaining,
    this.customerPartNo,
    this.lotNo,
    this.sourceLocationCode,
    this.fifoDate,
  });

  factory DplStockLot.fromJson(Map<String, dynamic> j) => DplStockLot(
        lotId: parseIntOr(j['lot_id']),
        partId: parseIntOr(j['part_id']),
        customerPartNo: j['customer_part_no'] as String?,
        lotNo: j['lot_no'] as String?,
        sourceLocationCode: j['source_location_code'] as String?,
        fifoDate: j['fifo_date']?.toString(),
        openingQty: parseIntOr(j['opening_qty']),
        qtyRemaining: parseIntOr(j['qty_remaining']),
      );
}

/// A stock adjustment awaiting, or past, a second person's decision.
class DplStockAdjustment {
  final int id;
  final String adjustmentNo;
  final String kind; // lot | wheels
  final String direction; // increase | decrease
  final int qty;
  final String? customerPartNo;
  final String reasonCode;
  final String? reason;
  final String note;
  final String status; // pending | approved | rejected
  final int requestedByUserId;
  final DateTime? requestedAt;
  final String? decisionNote;

  const DplStockAdjustment({
    required this.id,
    required this.adjustmentNo,
    required this.kind,
    required this.direction,
    required this.qty,
    required this.reasonCode,
    required this.note,
    required this.status,
    required this.requestedByUserId,
    this.customerPartNo,
    this.reason,
    this.requestedAt,
    this.decisionNote,
  });

  bool get isPending => status == 'pending';

  factory DplStockAdjustment.fromJson(Map<String, dynamic> j) => DplStockAdjustment(
        id: parseIntOr(j['id']),
        adjustmentNo: parseStringOr(j['adjustment_no']),
        kind: parseStringOr(j['kind']),
        direction: parseStringOr(j['direction']),
        qty: parseIntOr(j['qty']),
        customerPartNo: j['customer_part_no'] as String?,
        reasonCode: parseStringOr(j['reason_code']),
        reason: j['reason'] as String?,
        note: parseStringOr(j['note']),
        status: parseStringOr(j['status'], 'pending'),
        requestedByUserId: parseIntOr(j['requested_by_user_id']),
        requestedAt: parseDateTimeOrNull(j['requested_at']),
        decisionNote: j['decision_note'] as String?,
      );
}

class DplRackCountLine {
  final String? palletNo;
  final String? customerPartNo;
  final int? qty;
  final String? foundLocation;
  final String? expectedLocation; // only after submit
  final String? result; // matched | misplaced | missing | unexpected (after submit)

  const DplRackCountLine({
    this.palletNo,
    this.customerPartNo,
    this.qty,
    this.foundLocation,
    this.expectedLocation,
    this.result,
  });

  factory DplRackCountLine.fromJson(Map<String, dynamic> j) => DplRackCountLine(
        palletNo: j['pallet_no'] as String?,
        customerPartNo: j['customer_part_no'] as String?,
        qty: parseIntOrNull(j['qty']),
        foundLocation: j['found_location'] as String?,
        expectedLocation: j['expected_location'] as String?,
        result: j['result'] as String?,
      );
}

/// A blind rack count. While `blind`, no expected information is present.
class DplRackCount {
  final int countId;
  final String countNo;
  final String status; // open | submitted | approved | rejected | cancelled
  final bool blind;
  final int scanned;
  final List<({int id, String code})> racks;
  final List<DplRackCountLine> lines;
  final Map<String, int>? summary;
  final double? accuracyPct;

  const DplRackCount({
    required this.countId,
    required this.countNo,
    required this.status,
    required this.blind,
    required this.scanned,
    this.racks = const [],
    this.lines = const [],
    this.summary,
    this.accuracyPct,
  });

  factory DplRackCount.fromJson(Map<String, dynamic> j) {
    final s = j['summary'];
    return DplRackCount(
      countId: parseIntOr(j['count_id']),
      countNo: parseStringOr(j['count_no']),
      status: parseStringOr(j['status']),
      blind: j['blind'] == true,
      scanned: parseIntOr(j['scanned']),
      racks: (j['racks'] is List)
          ? (j['racks'] as List).whereType<Map>().map((r) => (id: parseIntOr(r['location_id']), code: parseStringOr(r['code']))).toList()
          : const [],
      lines: (j['lines'] is List)
          ? (j['lines'] as List).whereType<Map>().map((e) => DplRackCountLine.fromJson(Map<String, dynamic>.from(e))).toList()
          : const [],
      summary: s is Map ? s.map((k, v) => MapEntry(k.toString(), parseIntOr(v))) : null,
      accuracyPct: j['accuracy_pct'] == null ? null : parseDoubleOr(j['accuracy_pct']),
    );
  }
}

/// The preview or result of an opening-stock import.
class DplOpeningImport {
  final bool committed;
  final String? importNo;
  final int rows;
  final int ok;
  final int skipped;
  final int errors;
  final int lots;
  final int qty;
  final List<String> unmatchedItems;
  final List<String> unmappedLocations;
  final List<({int row, String status, String? message, String? itemCode})> problemRows;

  const DplOpeningImport({
    required this.committed,
    required this.rows,
    required this.ok,
    required this.skipped,
    required this.errors,
    required this.lots,
    required this.qty,
    this.importNo,
    this.unmatchedItems = const [],
    this.unmappedLocations = const [],
    this.problemRows = const [],
  });

  factory DplOpeningImport.fromJson(Map<String, dynamic> j) {
    final t = j['totals'] is Map ? Map<String, dynamic>.from(j['totals']) : <String, dynamic>{};
    List<String> strings(dynamic v) => v is List ? v.map((e) => e.toString()).toList() : const [];
    final rows = (j['rows'] is List) ? (j['rows'] as List).whereType<Map>() : const <Map>[];
    return DplOpeningImport(
      committed: j['committed'] == true,
      importNo: j['import_no'] as String?,
      rows: parseIntOr(t['rows']),
      ok: parseIntOr(t['ok']),
      skipped: parseIntOr(t['skipped']),
      errors: parseIntOr(t['errors']),
      lots: parseIntOr(t['lots']),
      qty: parseIntOr(t['qty']),
      unmatchedItems: strings(j['unmatched_items']),
      unmappedLocations: strings(j['unmapped_locations']),
      problemRows: rows
          .where((r) => r['status'] != 'ok')
          .map((r) => (
                row: parseIntOr(r['row']),
                status: parseStringOr(r['status']),
                message: r['message']?.toString(),
                itemCode: r['item_code']?.toString(),
              ))
          .toList(),
    );
  }
}
