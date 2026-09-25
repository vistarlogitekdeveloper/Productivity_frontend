import '_json_helpers.dart';
import 'dpl_pallet.dart';

/// One wheel on a pallet, as the SPD picker lists it.
///
/// The pallet LABEL never carries this list (open point C-04 — ninety-six
/// serials do not fit on a 100 x 75 mm die-cut), but picking which wheels leave
/// the pallet is impossible without seeing them, so the screen asks for it
/// separately.
class DplWheel {
  final int id;
  final String serialNo;
  final String customerPartNo;
  final String shiftCode;
  final String machineName;
  final DateTime? printedAt;
  final String status;

  const DplWheel({
    this.id = 0,
    this.serialNo = '',
    this.customerPartNo = '',
    this.shiftCode = '',
    this.machineName = '',
    this.printedAt,
    this.status = '',
  });

  factory DplWheel.fromJson(Map<String, dynamic> json) => DplWheel(
        id: parseIntOr(json['id']),
        serialNo: parseStringOr(json['serial_no']),
        customerPartNo: parseStringOr(json['customer_part_no']),
        shiftCode: parseStringOr(json['shift_code']),
        machineName: parseStringOr(json['machine_name']),
        printedAt: parseDateTimeOrNull(json['printed_at']),
        status: parseStringOr(json['status']),
      );

  /// A voided wheel was spoiled and retired. It cannot be shipped as a spare,
  /// and the picker must not offer it — the server refuses it anyway, but
  /// finding that out after choosing is a wasted trip.
  bool get isVoided => status == 'voided';
}

/// What `GET /qa/pallets/:id/wheels` answers.
class DplPalletWheels {
  final DplPallet pallet;
  final List<DplWheel> wheels;

  const DplPalletWheels({
    this.pallet = const DplPallet(),
    this.wheels = const [],
  });

  factory DplPalletWheels.fromJson(Map<String, dynamic> json) {
    final p = json['pallet'];
    final raw = json['wheels'];
    return DplPalletWheels(
      pallet: p is Map
          ? DplPallet.fromJson(Map<String, dynamic>.from(p))
          : const DplPallet(),
      wheels: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => DplWheel.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
    );
  }

  /// Only wheels that can actually be shipped.
  List<DplWheel> get sellable =>
      wheels.where((w) => !w.isVoided).toList(growable: false);
}

/// An individual spare-parts pack — one wheel, its own number, its own label.
///
/// Modelled server-side as a pallet row with `pallet_type = 'S'` and `qty = 1`,
/// because a pack is a shippable unit: it gets put away, picked, loaded and
/// gate-passed exactly like a pallet. A one-wheel pallet is what it physically
/// is, and every one of those joins keeps working for free.
class DplSpdPack {
  final int id;
  final String packNo;
  final String qrPayload;

  /// The wheel inside. A customer query arrives quoting this far more often
  /// than the pack number.
  final String serialNo;

  final String customerPartNo;
  final String partDescription;
  final String status;
  final DateTime? closedAt;

  const DplSpdPack({
    this.id = 0,
    this.packNo = '',
    this.qrPayload = '',
    this.serialNo = '',
    this.customerPartNo = '',
    this.partDescription = '',
    this.status = '',
    this.closedAt,
  });

  factory DplSpdPack.fromJson(Map<String, dynamic> json) {
    final part = json['part'];
    final partMap = part is Map ? Map<String, dynamic>.from(part) : const {};
    final no = parseStringOr(json['pallet_no']);
    return DplSpdPack(
      id: parseIntOr(json['id']),
      packNo: no,
      // Falls back to deriving it rather than printing an empty QR: a label
      // with no payload is a label nobody can scan, and the rule is fixed.
      qrPayload: parseStringOr(json['qr_payload']).isNotEmpty
          ? parseStringOr(json['qr_payload'])
          : (no.isEmpty ? '' : 'MWS|$no'),
      serialNo: parseStringOr(json['serial_no']),
      customerPartNo: parseStringOr(partMap['customer_part_no']),
      partDescription: parseStringOr(partMap['description']),
      status: parseStringOr(json['status']),
      closedAt: parseDateTimeOrNull(json['closed_at']),
    );
  }
}

/// A page of the SPD register.
class DplSpdPage {
  final List<DplSpdPack> packs;
  final int total;
  final int limit;
  final int offset;

  const DplSpdPage({
    this.packs = const [],
    this.total = 0,
    this.limit = 50,
    this.offset = 0,
  });

  factory DplSpdPage.fromJson(Map<String, dynamic> json) {
    final raw = json['packs'];
    return DplSpdPage(
      packs: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => DplSpdPack.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      total: parseIntOr(json['total']),
      limit: parseIntOr(json['limit'], 50),
      offset: parseIntOr(json['offset']),
    );
  }

  bool get hasMore => offset + packs.length < total;
}

/// The outcome of a conversion.
class DplSpdResult {
  /// The pallet the wheels came off, as it is now.
  final DplPallet source;

  /// True when every wheel went and the pallet holds nothing.
  final bool sourceConsumed;

  final List<DplSpdPack> packs;

  /// The source pallet's id when its master label must be printed again —
  /// null when the pallet was consumed, because a label for a pallet that
  /// holds nothing is worse than no label.
  final int? reprintSource;

  const DplSpdResult({
    this.source = const DplPallet(),
    this.sourceConsumed = false,
    this.packs = const [],
    this.reprintSource,
  });

  factory DplSpdResult.fromJson(Map<String, dynamic> json) {
    final s = json['source'];
    final raw = json['packs'];
    return DplSpdResult(
      source: s is Map
          ? DplPallet.fromJson(Map<String, dynamic>.from(s))
          : const DplPallet(),
      sourceConsumed: json['source_consumed'] == true,
      packs: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => DplSpdPack.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      reprintSource: parseIntOrNull(json['reprint_source']),
    );
  }
}

/// Which item a scanned WHEEL label belongs to — `GET /qa/wheels/resolve`.
///
/// Lets the pack point start a pallet by scanning rather than picking the item
/// from a list the label already names. [part] is null when the item cannot be
/// determined, which is normal for an old label whose item code is not in our
/// master — the screen then falls back to the picker rather than guessing,
/// because a pallet opened for the wrong item mislabels every wheel after it.
class DplWheelResolution {
  final String code;
  final String source;
  final int partId;
  final String customerPartNo;
  final String partDescription;
  final int? machineId;
  final String machineName;

  /// The cart this wheel is parked on, when it is on one. Empty otherwise.
  ///
  /// Reported rather than refused. The operator is holding the wheel and the
  /// usual next step is to take it off the cart and pack it, which the scan
  /// does — but they must be TOLD, because drawing a wheel off a trolley
  /// somebody else is planning a merge from is a decision, not a side effect.
  final String trolleyNo;

  /// How many are on that cart, so the size of what they are drawing down is
  /// visible before they do it.
  final int trolleyWheelQty;

  /// Why the item could not be determined. Empty when it was.
  final String reason;

  const DplWheelResolution({
    this.code = '',
    this.source = 'app',
    this.partId = 0,
    this.customerPartNo = '',
    this.partDescription = '',
    this.machineId,
    this.machineName = '',
    this.trolleyNo = '',
    this.trolleyWheelQty = 0,
    this.reason = '',
  });

  factory DplWheelResolution.fromJson(Map<String, dynamic> json) {
    final p = json['part'];
    final m = json['machine'];
    final t = json['trolley'];
    final part = p is Map ? Map<String, dynamic>.from(p) : const {};
    final machine = m is Map ? Map<String, dynamic>.from(m) : const {};
    final trolley = t is Map ? Map<String, dynamic>.from(t) : const {};
    return DplWheelResolution(
      code: parseStringOr(json['code']),
      source: parseStringOr(json['source'], 'app'),
      partId: parseIntOr(part['id']),
      customerPartNo: parseStringOr(part['customer_part_no']),
      partDescription: parseStringOr(part['description']),
      machineId: parseIntOrNull(machine['id']),
      machineName: parseStringOr(machine['machine_name']),
      trolleyNo: parseStringOr(trolley['trolley_no']),
      trolleyWheelQty: parseIntOr(trolley['wheel_qty']),
      reason: parseStringOr(json['reason']),
    );
  }

  bool get hasPart => partId > 0;

  /// True when this wheel is currently parked on a cart.
  bool get isOnTrolley => trolleyNo.isNotEmpty;
}
