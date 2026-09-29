import '_json_helpers.dart';

/// One check of one pallet by an auditor (backend migration 167).
///
/// The auditor scans the pallet label, then every wheel on it. The verdict is
/// a comparison of two SETS, not a count — ten scans of which two are foreign
/// and two are missing still comes to ten, and a counter would pass a pallet
/// with four wheels in the wrong place.
///
/// AN AUDIT RECORDS, IT DOES NOT BLOCK. A rejected pallet is still
/// dispatchable and an unaudited pallet ships exactly as it does today.
class DplPalletAudit {
  final int id;
  final int palletId;

  /// `in_progress` | `approved` | `rejected` | `abandoned`
  final String status;

  /// What the pallet said it held WHEN THE AUDIT STARTED. A snapshot: a pallet
  /// merged afterwards must not rewrite its own audit history.
  final int expectedQty;

  final int matchedQty;
  final int missingQty;
  final int foreignQty;

  /// Set on a rejection, and required by the server for one.
  final String? reason;

  final int? auditedBy;
  final DateTime? startedAt;
  final DateTime? decidedAt;

  /// Only present in the register listing, which joins them for display.
  final String? palletNo;
  final String? palletStatus;
  final String? auditedByName;

  const DplPalletAudit({
    required this.id,
    required this.palletId,
    this.status = 'in_progress',
    this.expectedQty = 0,
    this.matchedQty = 0,
    this.missingQty = 0,
    this.foreignQty = 0,
    this.reason,
    this.auditedBy,
    this.startedAt,
    this.decidedAt,
    this.palletNo,
    this.palletStatus,
    this.auditedByName,
  });

  factory DplPalletAudit.fromJson(Map<String, dynamic> json) {
    return DplPalletAudit(
      id: parseIntOr(json['id']),
      palletId: parseIntOr(json['pallet_id'] ?? json['palletId']),
      status: parseStringOr(json['status'], 'in_progress'),
      expectedQty: parseIntOr(json['expected_qty'] ?? json['expectedQty']),
      matchedQty: parseIntOr(json['matched_qty'] ?? json['matchedQty']),
      missingQty: parseIntOr(json['missing_qty'] ?? json['missingQty']),
      foreignQty: parseIntOr(json['foreign_qty'] ?? json['foreignQty']),
      reason: json['reason'] == null ? null : parseStringOr(json['reason']),
      auditedBy: json['audited_by'] == null && json['auditedBy'] == null
          ? null
          : parseIntOr(json['audited_by'] ?? json['auditedBy']),
      startedAt: parseDateTimeOrNull(json['started_at'] ?? json['startedAt']),
      decidedAt: parseDateTimeOrNull(json['decided_at'] ?? json['decidedAt']),
      palletNo: json['pallet_no'] == null && json['palletNo'] == null
          ? null
          : parseStringOr(json['pallet_no'] ?? json['palletNo']),
      palletStatus: json['pallet_status'] == null
          ? null
          : parseStringOr(json['pallet_status']),
      auditedByName: json['audited_by_name'] == null
          ? null
          : parseStringOr(json['audited_by_name']),
    );
  }

  bool get isOpen => status == 'in_progress';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';

  /// Nothing missing and nothing foreign. The only state the server will
  /// approve — it recomputes this and refuses a client that claims otherwise.
  bool get isClean => missingQty == 0 && foreignQty == 0;
}

/// One wheel in one audit.
class DplPalletAuditLine {
  final int id;

  /// As the auditor's scan produced it. For a wheel adopted from a supplier
  /// this is the code printed on THEIR label, not our internal serial, because
  /// ours appears on no physical sticker.
  final String serialNo;

  final int? stickerId;

  /// `matched` — on the pallet and scanned
  /// `missing` — on the pallet, never scanned
  /// `foreign` — scanned, but not on this pallet
  final String outcome;

  /// Where a foreign wheel actually lives, when the server can tell. This is
  /// what turns "two wheels are wrong" into a job somebody can do.
  final int? foundOnPalletId;

  final DateTime? scannedAt;

  const DplPalletAuditLine({
    required this.id,
    required this.serialNo,
    required this.outcome,
    this.stickerId,
    this.foundOnPalletId,
    this.scannedAt,
  });

  factory DplPalletAuditLine.fromJson(Map<String, dynamic> json) {
    return DplPalletAuditLine(
      id: parseIntOr(json['id']),
      serialNo: parseStringOr(json['serial_no'] ?? json['serialNo']),
      outcome: parseStringOr(json['outcome']),
      stickerId: json['sticker_id'] == null
          ? null
          : parseIntOr(json['sticker_id'] ?? json['stickerId']),
      foundOnPalletId: json['found_on_pallet_id'] == null
          ? null
          : parseIntOr(json['found_on_pallet_id']),
      scannedAt: parseDateTimeOrNull(json['scanned_at'] ?? json['scannedAt']),
    );
  }

  bool get isMatched => outcome == 'matched';
  bool get isMissing => outcome == 'missing';
  bool get isForeign => outcome == 'foreign';
}

/// A wheel the system says is on the pallet, as the audit screen lists it.
class DplAuditWheel {
  final int stickerId;

  /// What is PRINTED on the label the auditor will pick up.
  final String serialNo;

  /// `app` or `external`.
  final String source;

  final String customerPartNo;
  final String shiftCode;
  final String machineName;
  final DateTime? printedAt;
  final String status;

  const DplAuditWheel({
    required this.stickerId,
    required this.serialNo,
    this.source = 'app',
    this.customerPartNo = '',
    this.shiftCode = '',
    this.machineName = '',
    this.printedAt,
    this.status = '',
  });

  factory DplAuditWheel.fromJson(Map<String, dynamic> json) {
    return DplAuditWheel(
      stickerId: parseIntOr(json['sticker_id'] ?? json['stickerId']),
      serialNo: parseStringOr(json['serial_no'] ?? json['serialNo']),
      source: parseStringOr(json['source'], 'app'),
      customerPartNo: parseStringOr(
        json['customer_part_no'] ?? json['customerPartNo'],
      ),
      shiftCode: parseStringOr(json['shift_code'] ?? json['shiftCode']),
      machineName: parseStringOr(json['machine_name'] ?? json['machineName']),
      printedAt: parseDateTimeOrNull(json['printed_at'] ?? json['printedAt']),
      status: parseStringOr(json['status']),
    );
  }

  bool get isExternal => source == 'external';
}

/// What one wheel scan came back as.
class DplAuditScanResult {
  final DplPalletAuditLine line;

  /// True when this serial had already been scanned on this audit.
  ///
  /// The server answers rather than refusing. A hardware trigger fires far
  /// faster than a round trip, so a double pull is the scanner's doing, not
  /// the auditor's, and a red banner would blame the wrong person. The count
  /// cannot be inflated either way — a unique index sees to that.
  final bool duplicate;

  final DplPalletAudit? audit;

  const DplAuditScanResult({
    required this.line,
    this.duplicate = false,
    this.audit,
  });

  factory DplAuditScanResult.fromJson(Map<String, dynamic> json) {
    return DplAuditScanResult(
      line: DplPalletAuditLine.fromJson(
        Map<String, dynamic>.from(json['line'] as Map? ?? const {}),
      ),
      duplicate: json['duplicate'] == true,
      audit: json['audit'] is Map
          ? DplPalletAudit.fromJson(
              Map<String, dynamic>.from(json['audit'] as Map),
            )
          : null,
    );
  }
}

/// The whole working state of one audit: the pallet, what it should hold, and
/// what has been scanned so far.
class DplPalletAuditSession {
  final DplPalletAudit audit;
  final DplAuditPallet? pallet;
  final List<DplAuditWheel> wheels;
  final List<DplPalletAuditLine> lines;

  const DplPalletAuditSession({
    required this.audit,
    this.pallet,
    this.wheels = const [],
    this.lines = const [],
  });

  factory DplPalletAuditSession.fromJson(Map<String, dynamic> json) {
    return DplPalletAuditSession(
      audit: DplPalletAudit.fromJson(
        Map<String, dynamic>.from(json['audit'] as Map? ?? const {}),
      ),
      pallet: json['pallet'] is Map
          ? DplAuditPallet.fromJson(
              Map<String, dynamic>.from(json['pallet'] as Map),
            )
          : null,
      wheels: (json['wheels'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => DplAuditWheel.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      lines: (json['lines'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => DplPalletAuditLine.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
    );
  }

  /// Serials already scanned, upper-cased — the screen ticks the list against
  /// this, and the server matches case-insensitively too.
  Set<String> get scannedKeys =>
      lines.map((l) => l.serialNo.trim().toUpperCase()).toSet();

  List<DplPalletAuditLine> get foreign =>
      lines.where((l) => l.isForeign).toList(growable: false);

  /// Wheels the pallet holds that nobody has scanned yet.
  ///
  /// Computed here rather than read from the server, because until the auditor
  /// stops scanning nobody knows which of these they are not going to find —
  /// the server only writes `missing` lines at the verdict.
  List<DplAuditWheel> get notYetScanned {
    final done = scannedKeys;
    return wheels
        .where((w) => !done.contains(w.serialNo.trim().toUpperCase()))
        .toList(growable: false);
  }

  int get matchedCount => lines.where((l) => l.isMatched).length;
}

/// The pallet as the audit screens need it.
class DplAuditPallet {
  final int id;
  final String palletNo;
  final String palletType;
  final String status;
  final int qty;
  final int? standardQty;
  final int partId;
  final String customerPartNo;
  final String partDescription;

  const DplAuditPallet({
    required this.id,
    this.palletNo = '',
    this.palletType = '',
    this.status = '',
    this.qty = 0,
    this.standardQty,
    this.partId = 0,
    this.customerPartNo = '',
    this.partDescription = '',
  });

  factory DplAuditPallet.fromJson(Map<String, dynamic> json) {
    return DplAuditPallet(
      id: parseIntOr(json['id']),
      palletNo: parseStringOr(json['pallet_no'] ?? json['palletNo']),
      palletType: parseStringOr(json['pallet_type'] ?? json['palletType']),
      status: parseStringOr(json['status']),
      qty: parseIntOr(json['qty']),
      standardQty: json['standard_qty'] == null
          ? null
          : parseIntOr(json['standard_qty']),
      partId: parseIntOr(json['part_id'] ?? json['partId']),
      customerPartNo: parseStringOr(
        json['customer_part_no'] ?? json['customerPartNo'],
      ),
      partDescription: parseStringOr(
        json['part_description'] ?? json['partDescription'],
      ),
    );
  }
}

/// One page of the audit register.
class DplPalletAuditPage {
  final int total;
  final int limit;
  final int offset;
  final List<DplPalletAudit> audits;

  const DplPalletAuditPage({
    this.total = 0,
    this.limit = 50,
    this.offset = 0,
    this.audits = const [],
  });

  factory DplPalletAuditPage.fromJson(Map<String, dynamic> json) {
    return DplPalletAuditPage(
      total: parseIntOr(json['total']),
      limit: parseIntOr(json['limit'], 50),
      offset: parseIntOr(json['offset']),
      audits: (json['audits'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => DplPalletAudit.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
    );
  }
}
