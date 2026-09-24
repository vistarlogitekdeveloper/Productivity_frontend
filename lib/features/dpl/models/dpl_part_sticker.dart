import '_json_helpers.dart';
import 'dpl_part.dart';

/// One finished-goods sticker issued by QA (backend migration 144).
///
/// Every field here is a SNAPSHOT taken by the server at print time, not a
/// live join. A sticker is a physical object stuck to a part; if the part
/// master is edited afterwards the label still says what it says, and the
/// app must show what is printed rather than what the master now holds.
class DplPartSticker {
  final int id;
  final int planId;
  final int planItemId;
  final int partId;

  /// Human-readable serial, e.g. `GA2600000147`. Printed under the symbol so
  /// a scuffed thermal label can still be keyed in by hand.
  final String serialNo;

  /// What the 2D symbol encodes. Pipe-delimited and positionally identical to
  /// the Maxion wheel payload — `GA|plant|customerPartNo|serial|YYMMDD|shift|line`
  /// against Maxion's `MW|P1|item|serial|YYMMDD|shift|line` — so the same
  /// index-based parsing works for both.
  final String qrPayload;

  final String substratePartNo;
  final String customerPartNo;
  final String shiftCode;
  final String machineName;

  /// Groups one print run, so a reprint of a spoiled batch is identifiable.
  final String batchId;
  final int seqInBatch;

  /// `issued` or `voided`. Voided stickers free the quantity back up for a
  /// reprint but their serials are retired for good.
  final String status;

  final DateTime? printedAt;

  const DplPartSticker({
    required this.id,
    required this.planId,
    required this.planItemId,
    required this.partId,
    required this.serialNo,
    required this.qrPayload,
    this.substratePartNo = '',
    this.customerPartNo = '',
    this.shiftCode = '',
    this.machineName = '',
    this.batchId = '',
    this.seqInBatch = 0,
    this.status = 'issued',
    this.printedAt,
  });

  factory DplPartSticker.fromJson(Map<String, dynamic> json) {
    return DplPartSticker(
      id: parseIntOr(json['id']),
      planId: parseIntOr(json['plan_id'] ?? json['planId']),
      planItemId: parseIntOr(json['plan_item_id'] ?? json['planItemId']),
      partId: parseIntOr(json['part_id'] ?? json['partId']),
      serialNo: parseStringOr(json['serial_no'] ?? json['serialNo']),
      qrPayload: parseStringOr(json['qr_payload'] ?? json['qrPayload']),
      substratePartNo: parseStringOr(
        json['substrate_part_no'] ?? json['substratePartNo'],
      ),
      customerPartNo: parseStringOr(
        json['customer_part_no'] ?? json['customerPartNo'],
      ),
      shiftCode: parseStringOr(json['shift_code'] ?? json['shiftCode']),
      machineName: parseStringOr(json['machine_name'] ?? json['machineName']),
      batchId: parseStringOr(json['batch_id'] ?? json['batchId']),
      seqInBatch: parseIntOr(json['seq_in_batch'] ?? json['seqInBatch']),
      status: parseStringOr(json['status'], 'issued'),
      printedAt: parseDateTimeOrNull(json['printed_at'] ?? json['printedAt']),
    );
  }

  bool get isVoided => status.toLowerCase() == 'voided';

  /// Payload fields, read positionally. Falls back to the stored column when
  /// the payload is malformed, so the label never shows a blank where the
  /// database has a value.
  List<String> get _payloadParts => qrPayload.split('|');

  String get payloadSerial =>
      _payloadParts.length > 3 && _payloadParts[3].trim().isNotEmpty
          ? _payloadParts[3].trim()
          : serialNo;

  String get payloadShift =>
      _payloadParts.length > 5 && _payloadParts[5].trim().isNotEmpty
          ? _payloadParts[5].trim()
          : (shiftCode.isEmpty ? '-' : shiftCode);

  String get payloadLine =>
      _payloadParts.length > 6 && _payloadParts[6].trim().isNotEmpty
          ? _payloadParts[6].trim()
          : (machineName.isEmpty ? '-' : machineName);
}

/// Where a plan item stands against its printing allowance.
///
/// `actualQty` is the produced quantity the supervisor recorded. `printedQty`
/// counts only `issued` stickers. `remainingQty` is what the server will still
/// allow — the app mirrors it to disable the print button, but the server is
/// the authority and re-checks under a row lock.
class DplStickerSummary {
  final int planItemId;
  final int planId;
  final int planNo;
  final int partId;
  final String status;
  final int planQty;
  final int actualQty;
  final int printedQty;
  final int remainingQty;

  const DplStickerSummary({
    required this.planItemId,
    this.planId = 0,
    this.planNo = 0,
    this.partId = 0,
    this.status = '',
    this.planQty = 0,
    this.actualQty = 0,
    this.printedQty = 0,
    this.remainingQty = 0,
  });

  factory DplStickerSummary.fromJson(Map<String, dynamic> json) {
    return DplStickerSummary(
      planItemId: parseIntOr(json['plan_item_id'] ?? json['planItemId']),
      planId: parseIntOr(json['plan_id'] ?? json['planId']),
      planNo: parseIntOr(json['plan_no'] ?? json['planNo']),
      partId: parseIntOr(json['part_id'] ?? json['partId']),
      status: parseStringOr(json['status']),
      planQty: parseIntOr(json['plan_qty'] ?? json['planQty']),
      actualQty: parseIntOr(json['actual_qty'] ?? json['actualQty']),
      printedQty: parseIntOr(json['printed_qty'] ?? json['printedQty']),
      remainingQty: parseIntOr(json['remaining_qty'] ?? json['remainingQty']),
    );
  }

  bool get canPrint => remainingQty > 0;

  /// True when production has not been recorded yet — a different message to
  /// the operator than "you have printed them all".
  bool get noProductionYet => actualQty <= 0 && printedQty <= 0;

  /// The plan was reopened after labels had already been printed.
  ///
  /// `changePlanStatus` on the backend bulk-resets `actual_qty` to 0 for every
  /// completed item when a plan goes back to draft/published/in_progress, and
  /// deliberately leaves the stickers alone — those labels are physically on
  /// parts. Telling the operator "no production recorded" in that state would
  /// contradict the labels in their hand, so it gets its own message.
  bool get wasReset => actualQty <= 0 && printedQty > 0;
}

/// Result of resolving a scanned raw-material label.
///
/// [parts] is every ACTIVE part mapped to the scanned substrate. More than one
/// is normal and is exactly why QA gets a picker: the seed data alone has
/// `195872440-083` mapping to both `542469500120D1` and `546769500133D1`.
class DplScanResolution {
  final String substratePartNo;
  final String matchedOn;

  /// Tokens the decoder pulled out of the payload. Shown to the operator when
  /// nothing matched, so a failed scan says what was actually read instead of
  /// just "not found" — and tells us the real label format.
  final List<String> candidates;

  final List<DplPart> parts;

  const DplScanResolution({
    this.substratePartNo = '',
    this.matchedOn = '',
    this.candidates = const [],
    this.parts = const [],
  });

  factory DplScanResolution.fromJson(Map<String, dynamic> json) {
    final rawParts = json['parts'];
    final rawCandidates = json['candidates'];
    return DplScanResolution(
      substratePartNo: parseStringOr(
        json['substrate_part_no'] ?? json['substratePartNo'],
      ),
      matchedOn: parseStringOr(json['matched_on'] ?? json['matchedOn']),
      candidates: rawCandidates is List
          ? rawCandidates.map((e) => parseStringOr(e)).where((e) => e.isNotEmpty).toList()
          : const [],
      parts: rawParts is List
          ? rawParts
              .whereType<Map>()
              .map((e) => DplPart.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
    );
  }

  bool get hasSingleMatch => parts.length == 1;
  bool get needsPick => parts.length > 1;
}

/// What the server returns after issuing a batch of stickers.
class DplStickerIssueResult {
  final String batchId;
  final List<DplPartSticker> stickers;
  final DplStickerSummary summary;
  final DplPart? part;

  const DplStickerIssueResult({
    required this.batchId,
    required this.stickers,
    required this.summary,
    this.part,
  });

  factory DplStickerIssueResult.fromJson(Map<String, dynamic> json) {
    final rawStickers = json['stickers'];
    final rawSummary = json['summary'];
    final rawPart = json['part'];
    return DplStickerIssueResult(
      batchId: parseStringOr(json['batch_id'] ?? json['batchId']),
      stickers: rawStickers is List
          ? rawStickers
              .whereType<Map>()
              .map((e) => DplPartSticker.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      summary: rawSummary is Map
          ? DplStickerSummary.fromJson(Map<String, dynamic>.from(rawSummary))
          : const DplStickerSummary(planItemId: 0),
      part: rawPart is Map
          ? DplPart.fromJson(Map<String, dynamic>.from(rawPart))
          : null,
    );
  }
}
