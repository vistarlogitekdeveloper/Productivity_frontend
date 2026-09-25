import '_json_helpers.dart';

/// One serial scanned onto a trip.
class DplScannedSerial {
  final int id;
  final String serialNo;
  final DateTime? scannedAt;

  const DplScannedSerial({
    required this.id,
    required this.serialNo,
    this.scannedAt,
  });

  factory DplScannedSerial.fromJson(Map<String, dynamic> json) {
    return DplScannedSerial(
      id: parseIntOr(json['id']),
      serialNo: parseStringOr(json['serial_no'] ?? json['serialNo']),
      scannedAt: parseDateTimeOrNull(json['scanned_at'] ?? json['scannedAt']),
    );
  }
}

/// Scan progress for one plan on a trip.
class DplTripPlanScan {
  final int planId;
  final int partId;
  final int machineId;
  final String customerPartNo;
  final String description;
  final String status;

  final int plannedQty;
  final int scannedQty;
  final int remainingQty;

  /// True when every planned piece has been scanned. A cancelled plan is
  /// complete by definition — nothing is being loaded for it, so requiring
  /// scans would leave the trip permanently unsendable.
  final bool isComplete;

  final List<DplScannedSerial> serials;

  const DplTripPlanScan({
    required this.planId,
    this.partId = 0,
    this.machineId = 0,
    this.customerPartNo = '',
    this.description = '',
    this.status = '',
    this.plannedQty = 0,
    this.scannedQty = 0,
    this.remainingQty = 0,
    this.isComplete = false,
    this.serials = const [],
  });

  factory DplTripPlanScan.fromJson(Map<String, dynamic> json) {
    final rawSerials = json['serials'];
    return DplTripPlanScan(
      planId: parseIntOr(json['plan_id'] ?? json['planId']),
      partId: parseIntOr(json['part_id'] ?? json['partId']),
      machineId: parseIntOr(json['machine_id'] ?? json['machineId']),
      customerPartNo: parseStringOr(
        json['customer_part_no'] ?? json['customerPartNo'],
      ),
      description: parseStringOr(json['description']),
      status: parseStringOr(json['status']),
      plannedQty: parseIntOr(json['planned_qty'] ?? json['plannedQty']),
      scannedQty: parseIntOr(json['scanned_qty'] ?? json['scannedQty']),
      remainingQty: parseIntOr(json['remaining_qty'] ?? json['remainingQty']),
      isComplete: json['is_complete'] is bool
          ? json['is_complete'] as bool
          : json['isComplete'] is bool
              ? json['isComplete'] as bool
              : false,
      serials: rawSerials is List
          ? rawSerials
              .whereType<Map>()
              .map((e) => DplScannedSerial.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
    );
  }

  String get label =>
      customerPartNo.isNotEmpty ? customerPartNo : (description.isNotEmpty ? description : 'Part #$partId');
}

/// Scan progress across a whole trip — what the Send button is gated on.
/// A whole pallet loaded onto a trip (backend migration 159).
class DplLoadedPallet {
  final int palletId;
  final String palletNo;
  final String? palletType;
  final int qty;

  const DplLoadedPallet({required this.palletId, required this.palletNo, required this.qty, this.palletType});

  factory DplLoadedPallet.fromJson(Map<String, dynamic> j) => DplLoadedPallet(
        palletId: parseIntOr(j['pallet_id']),
        palletNo: parseStringOr(j['pallet_no']),
        palletType: j['pallet_type'] as String?,
        qty: parseIntOr(j['qty']),
      );
}

class DplTripScanProgress {
  final int tripId;
  final List<DplTripPlanScan> plans;

  /// Pallets scanned onto the trip whole (one scan of the pallet label loads
  /// every wheel on it); each can be unloaded until a slip is cut.
  final List<DplLoadedPallet> pallets;

  /// Client-side courtesy only. The server re-derives the same figure when a
  /// slip is cut, because the client cannot be the authority on whether
  /// pieces are physically on a trolley.
  final bool isComplete;

  const DplTripScanProgress({
    required this.tripId,
    this.plans = const [],
    this.pallets = const [],
    this.isComplete = false,
  });

  factory DplTripScanProgress.fromJson(Map<String, dynamic> json) {
    final rawPlans = json['plans'];
    return DplTripScanProgress(
      tripId: parseIntOr(json['trip_id'] ?? json['tripId']),
      plans: rawPlans is List
          ? rawPlans
              .whereType<Map>()
              .map((e) => DplTripPlanScan.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      pallets: json['pallets'] is List
          ? (json['pallets'] as List)
              .whereType<Map>()
              .map((e) => DplLoadedPallet.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      isComplete: json['is_complete'] is bool
          ? json['is_complete'] as bool
          : json['isComplete'] is bool
              ? json['isComplete'] as bool
              : false,
    );
  }

  DplTripPlanScan? forPlan(int planId) {
    for (final p in plans) {
      if (p.planId == planId) return p;
    }
    return null;
  }

  /// True when every plan in [planIds] is fully scanned. A plan the server has
  /// no row for is treated as NOT complete — absence is not evidence of
  /// having scanned anything.
  bool areComplete(Iterable<int> planIds) {
    for (final id in planIds) {
      final p = forPlan(id);
      if (p == null || !p.isComplete) return false;
    }
    return true;
  }

  int scannedFor(int planId) => forPlan(planId)?.scannedQty ?? 0;
  int plannedFor(int planId) => forPlan(planId)?.plannedQty ?? 0;
}

/// Labelled-stock position for one part, as the trip planner sees it.
///
/// Carries all four numbers rather than just the allowance, because a zero
/// allowance has two very different causes and the screen has to say which:
/// nothing has been printed, or everything printed is already claimed by
/// another trip. Collapsing them was the bug that made a part with 28 printed
/// labels read "No labels printed".
class DplLabelStock {
  /// Everything ever printed for this part.
  final int labelledQty;

  /// Of those, how many are already scanned onto a trip.
  final int onTripQty;

  /// Printed but not yet loaded.
  final int freeQty;

  /// Quantity claimed by plans that are still open or awaiting a slip, minus
  /// what has already been scanned against them.
  final int committedQty;

  /// What may still be planned. `max(0, free - committed)`.
  final int availableQty;

  const DplLabelStock({
    this.labelledQty = 0,
    this.onTripQty = 0,
    this.freeQty = 0,
    this.committedQty = 0,
    this.availableQty = 0,
  });

  factory DplLabelStock.fromJson(Map<String, dynamic> json) {
    return DplLabelStock(
      labelledQty: parseIntOr(json['labelled_qty'] ?? json['labelledQty']),
      onTripQty: parseIntOr(json['on_trip_qty'] ?? json['onTripQty']),
      freeQty: parseIntOr(json['free_qty'] ?? json['freeQty']),
      committedQty: parseIntOr(json['committed_qty'] ?? json['committedQty']),
      availableQty: parseIntOr(json['available_qty'] ?? json['availableQty']),
    );
  }

  /// Nothing has ever been printed for this part.
  bool get nothingPrinted => labelledQty <= 0;

  /// Labels exist, but every one has already been loaded onto a trip.
  ///
  /// Note this is about pieces PHYSICALLY SCANNED onto a trip, not about other
  /// trips' plans. A plan does not reserve stock — reserving at plan time is
  /// what used to lock the planner out entirely.
  bool get allLoaded => labelledQty > 0 && availableQty <= 0;

  /// Other trips have planned this part but not yet loaded it. Shown as
  /// context only; it never reduces what may be planned.
  bool get plannedElsewhere => committedQty > 0;

  /// The one-line hint shown beside the qty input.
  ///
  /// [enforced] reflects `DplFeatureFlags.enforceLabelStockOnPlan`. When the
  /// cap is off these numbers are information, not a verdict, so the wording
  /// must not imply the planner is being stopped — "No labels printed" beside
  /// a field that accepts any value reads as a malfunction.
  String hintFor({required bool enforced}) {
    if (nothingPrinted) {
      return enforced ? 'No labels printed' : 'No labels printed yet';
    }
    if (allLoaded) {
      return enforced
          ? 'Labels: 0 free (all $labelledQty already loaded onto trips)'
          : 'Labels: all $labelledQty already loaded onto trips';
    }
    final base = enforced
        ? 'Labels: $availableQty NOS'
        : 'Labels: $availableQty free of $labelledQty';
    // Surfacing the other-trip claim keeps the planner informed without
    // pretending the stock is unavailable to them.
    return plannedElsewhere ? '$base ($committedQty planned elsewhere)' : base;
  }

  /// Convenience for the enforced case, kept so existing call sites and tests
  /// read naturally.
  String get hint => hintFor(enforced: true);
}

/// Everything the aggregate "master sticker" prints for one trip plan.
///
/// Built from the SCANNED pieces, not the planned quantity — the sticker
/// describes what is physically on the trolley.
class DplMasterSticker {
  final int tripId;
  final int tripNumber;
  final DateTime? tripDate;
  final String plantCode;
  final String vehicleNo;

  final int planId;
  final int plannedQty;
  final int scannedQty;

  final String customerPartNo;
  final String substratePartNo;
  final String materialCode;
  final String description;
  final String partName;
  final String machineName;
  final String shiftCode;

  final String serialFrom;
  final String serialTo;
  final List<String> serials;

  const DplMasterSticker({
    required this.tripId,
    required this.planId,
    this.tripNumber = 0,
    this.tripDate,
    this.plantCode = '',
    this.vehicleNo = '',
    this.plannedQty = 0,
    this.scannedQty = 0,
    this.customerPartNo = '',
    this.substratePartNo = '',
    this.materialCode = '',
    this.description = '',
    this.partName = '',
    this.machineName = '',
    this.shiftCode = '',
    this.serialFrom = '',
    this.serialTo = '',
    this.serials = const [],
  });

  factory DplMasterSticker.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> sub(String key) {
      final v = json[key];
      return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    }

    final trip = sub('trip');
    final plan = sub('plan');
    final part = sub('part');
    final rawSerials = json['serials'];

    return DplMasterSticker(
      tripId: parseIntOr(trip['id']),
      tripNumber: parseIntOr(trip['trip_number'] ?? trip['tripNumber']),
      tripDate: parseDateTimeOrNull(trip['trip_date'] ?? trip['tripDate']),
      plantCode: parseStringOr(trip['plant_code'] ?? trip['plantCode']),
      vehicleNo: parseStringOr(trip['vehicle_no'] ?? trip['vehicleNo']),
      planId: parseIntOr(plan['id']),
      plannedQty: parseIntOr(plan['planned_qty'] ?? plan['plannedQty']),
      scannedQty: parseIntOr(json['scanned_qty'] ?? json['scannedQty']),
      customerPartNo: parseStringOr(
        part['customer_part_no'] ?? part['customerPartNo'],
      ),
      substratePartNo: parseStringOr(
        part['substrate_part_no'] ?? part['substratePartNo'],
      ),
      materialCode: parseStringOr(part['material_code'] ?? part['materialCode']),
      description: parseStringOr(part['description']),
      partName: parseStringOr(part['part_name'] ?? part['partName']),
      machineName: parseStringOr(json['machine_name'] ?? json['machineName']),
      shiftCode: parseStringOr(json['shift_code'] ?? json['shiftCode']),
      serialFrom: parseStringOr(json['serial_from'] ?? json['serialFrom']),
      serialTo: parseStringOr(json['serial_to'] ?? json['serialTo']),
      serials: rawSerials is List
          ? rawSerials.map((e) => parseStringOr(e)).where((e) => e.isNotEmpty).toList()
          : const [],
    );
  }

  /// What the master sticker's own QR encodes. Positionally distinct from a
  /// piece label (`GA|…`) so a scanner can tell a master from a single piece
  /// by its first field alone.
  String get qrPayload =>
      'GAM|$plantCode|$customerPartNo|$tripNumber|$planId|$scannedQty';
}
