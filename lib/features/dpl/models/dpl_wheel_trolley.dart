import '_json_helpers.dart';
import 'dpl_pallet.dart';

/// A physical cart holding loose wheels that are not on a pallet yet.
///
/// The third place a wheel can be. Before this it was packed or unpacked,
/// which forces a plant that changes over mid-run either to open a pallet it
/// knows will stand part-filled for a month, or to leave the wheels off the
/// system altogether.
///
/// NOT the production-trolley photo the supervisor takes at shift stop, and
/// not the dispatch staging area. The word is overloaded on the floor; here it
/// always means a WHEEL trolley.
class DplWheelTrolley {
  final int id;
  final String trolleyNo;

  /// What the floor calls it — "Line 3 cart". May be empty.
  final String name;

  /// active | retired
  final String status;

  final int wheelQty;
  final DateTime? lastActivityAt;

  const DplWheelTrolley({
    this.id = 0,
    this.trolleyNo = '',
    this.name = '',
    this.status = 'active',
    this.wheelQty = 0,
    this.lastActivityAt,
  });

  factory DplWheelTrolley.fromJson(Map<String, dynamic> json) =>
      DplWheelTrolley(
        id: parseIntOr(json['id']),
        trolleyNo: parseStringOr(json['trolley_no']),
        name: parseStringOr(json['name']),
        status: parseStringOr(json['status'], 'active'),
        wheelQty: parseIntOr(json['wheel_qty']),
        lastActivityAt: parseDateTimeOrNull(json['last_activity_at']),
      );

  bool get isActive => status == 'active';
  bool get isEmpty => wheelQty < 1;

  /// "TR26000001 · Line 3 cart", or just the number when it has no nickname.
  String get label => name.isEmpty ? trolleyNo : '$trolleyNo · $name';
}

/// The outcome of parking one wheel.
class DplTrolleyParkResult {
  final DplWheelTrolley trolley;

  /// What the operator will see printed on the sticker in their hand.
  final String serialNo;

  /// 'external' when this came in on one of the plant's old labels. Worth
  /// showing: during the changeover the operator is holding two kinds of
  /// sticker and a silent acceptance looks identical either way.
  final String source;

  const DplTrolleyParkResult({
    this.trolley = const DplWheelTrolley(),
    this.serialNo = '',
    this.source = 'app',
  });

  factory DplTrolleyParkResult.fromJson(Map<String, dynamic> json) {
    final t = json['trolley'];
    return DplTrolleyParkResult(
      trolley: t is Map
          ? DplWheelTrolley.fromJson(Map<String, dynamic>.from(t))
          : const DplWheelTrolley(),
      serialNo: parseStringOr(json['serial_no']),
      source: parseStringOr(json['source'], 'app'),
    );
  }

  bool get isExternal => source == 'external';
}

/// The outcome of moving wheels off a cart onto a closed pallet.
class DplTrolleyMergeResult {
  final DplPallet pallet;
  final DplWheelTrolley trolley;
  final int moved;

  /// True when the pallet is now at its standard quantity.
  final bool isFull;

  /// The number it used to carry, when the merge moved it onto the PM series.
  /// Empty when nothing was renumbered.
  final String renamedFrom;
  final String renamedTo;

  /// Pallets whose labels are now stale. Always the target: its count changed
  /// and its number may have.
  final List<int> reprint;

  const DplTrolleyMergeResult({
    this.pallet = const DplPallet(),
    this.trolley = const DplWheelTrolley(),
    this.moved = 0,
    this.isFull = false,
    this.renamedFrom = '',
    this.renamedTo = '',
    this.reprint = const [],
  });

  factory DplTrolleyMergeResult.fromJson(Map<String, dynamic> json) {
    final p = json['pallet'];
    final t = json['trolley'];
    final renamed = json['renamed'];
    final renamedMap =
        renamed is Map ? Map<String, dynamic>.from(renamed) : const {};
    final raw = json['reprint'];
    return DplTrolleyMergeResult(
      pallet: p is Map
          ? DplPallet.fromJson(Map<String, dynamic>.from(p))
          : const DplPallet(),
      trolley: t is Map
          ? DplWheelTrolley.fromJson(Map<String, dynamic>.from(t))
          : const DplWheelTrolley(),
      moved: parseIntOr(json['moved']),
      isFull: json['is_full'] == true,
      renamedFrom: parseStringOr(renamedMap['from']),
      renamedTo: parseStringOr(renamedMap['to']),
      reprint: raw is List
          ? raw.map(parseIntOr).where((e) => e > 0).toList()
          : const [],
    );
  }

  bool get wasRenamed => renamedTo.isNotEmpty;
}

/// One wheel parked on a cart.
class DplTrolleyWheel {
  final int id;

  /// The RAW external payload for an adopted wheel, and our serial otherwise.
  ///
  /// Deliberately not the stored serial for an old label: that is a shortened
  /// hash which appears on no physical sticker, so a list showing it gives the
  /// operator nothing to match against what is in their hand.
  final String serialNo;

  final String source;
  final int partId;
  final String customerPartNo;
  final String partDescription;
  final String shiftCode;
  final DateTime? printedAt;
  final String status;

  const DplTrolleyWheel({
    this.id = 0,
    this.serialNo = '',
    this.source = 'app',
    this.partId = 0,
    this.customerPartNo = '',
    this.partDescription = '',
    this.shiftCode = '',
    this.printedAt,
    this.status = '',
  });

  factory DplTrolleyWheel.fromJson(Map<String, dynamic> json) =>
      DplTrolleyWheel(
        id: parseIntOr(json['id']),
        serialNo: parseStringOr(json['serial_no']),
        source: parseStringOr(json['source'], 'app'),
        partId: parseIntOr(json['part_id']),
        customerPartNo: parseStringOr(json['customer_part_no']),
        partDescription: parseStringOr(json['part_description']),
        shiftCode: parseStringOr(json['shift_code']),
        printedAt: parseDateTimeOrNull(json['printed_at']),
        status: parseStringOr(json['status']),
      );

  bool get isVoided => status == 'voided';
  bool get isExternal => source == 'external';
}

/// What `GET /warehouse/trolleys/:id/wheels` answers.
class DplTrolleyContents {
  final DplWheelTrolley trolley;
  final List<DplTrolleyWheel> wheels;

  const DplTrolleyContents({
    this.trolley = const DplWheelTrolley(),
    this.wheels = const [],
  });

  factory DplTrolleyContents.fromJson(Map<String, dynamic> json) {
    final t = json['trolley'];
    final raw = json['wheels'];
    return DplTrolleyContents(
      trolley: t is Map
          ? DplWheelTrolley.fromJson(Map<String, dynamic>.from(t))
          : const DplWheelTrolley(),
      wheels: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => DplTrolleyWheel.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
    );
  }

  /// Only wheels that can actually be packed.
  List<DplTrolleyWheel> get packable =>
      wheels.where((w) => !w.isVoided).toList(growable: false);
}

/// One suggested move: fill this half pallet with this many wheels.
class DplTrolleyPlanStep {
  final int palletId;
  final String palletNo;
  final int qty;
  final int? standardQty;

  /// How many it is short.
  final int need;

  final int ageDays;

  /// How many to take off the cart. Equals [need] — a step that does not
  /// COMPLETE the pallet is not suggested, because a half pallet only stops
  /// ageing when it becomes full.
  final int take;

  const DplTrolleyPlanStep({
    this.palletId = 0,
    this.palletNo = '',
    this.qty = 0,
    this.standardQty,
    this.need = 0,
    this.ageDays = 0,
    this.take = 0,
  });

  factory DplTrolleyPlanStep.fromJson(Map<String, dynamic> json) =>
      DplTrolleyPlanStep(
        palletId: parseIntOr(json['pallet_id']),
        palletNo: parseStringOr(json['pallet_no']),
        qty: parseIntOr(json['qty']),
        standardQty: parseIntOrNull(json['standard_qty']),
        need: parseIntOr(json['need']),
        ageDays: parseIntOr(json['age_days']),
        take: parseIntOr(json['take']),
      );

  bool get isOld => ageDays >= 7;
}

/// A half pallet the plan could not help, and why.
class DplTrolleyPlanSkipped {
  final int palletId;
  final String palletNo;
  final int need;
  final int ageDays;
  final String why;

  const DplTrolleyPlanSkipped({
    this.palletId = 0,
    this.palletNo = '',
    this.need = 0,
    this.ageDays = 0,
    this.why = '',
  });

  factory DplTrolleyPlanSkipped.fromJson(Map<String, dynamic> json) =>
      DplTrolleyPlanSkipped(
        palletId: parseIntOr(json['pallet_id']),
        palletNo: parseStringOr(json['pallet_no']),
        need: parseIntOr(json['need']),
        ageDays: parseIntOr(json['age_days']),
        why: parseStringOr(json['why']),
      );

  bool get isOld => ageDays >= 7;
}

/// The plan for one item on the cart.
class DplTrolleyPlanItem {
  final int partId;
  final String customerPartNo;
  final String partDescription;
  final int onTrolley;

  /// How many half pallets this plan brings to full.
  final int completes;

  /// Total age of the pallets it retires. The tie-break, made visible.
  final int ageDaysRetired;

  final int wheelsUsed;
  final int leftover;
  final List<DplTrolleyPlanStep> steps;
  final List<DplTrolleyPlanSkipped> ignored;

  const DplTrolleyPlanItem({
    this.partId = 0,
    this.customerPartNo = '',
    this.partDescription = '',
    this.onTrolley = 0,
    this.completes = 0,
    this.ageDaysRetired = 0,
    this.wheelsUsed = 0,
    this.leftover = 0,
    this.steps = const [],
    this.ignored = const [],
  });

  factory DplTrolleyPlanItem.fromJson(Map<String, dynamic> json) {
    final steps = json['steps'];
    final ignored = json['ignored'];
    return DplTrolleyPlanItem(
      partId: parseIntOr(json['part_id']),
      customerPartNo: parseStringOr(json['customer_part_no']),
      partDescription: parseStringOr(json['part_description']),
      onTrolley: parseIntOr(json['on_trolley']),
      completes: parseIntOr(json['completes']),
      ageDaysRetired: parseIntOr(json['age_days_retired']),
      wheelsUsed: parseIntOr(json['wheels_used']),
      leftover: parseIntOr(json['leftover']),
      steps: steps is List
          ? steps
              .whereType<Map>()
              .map((e) => DplTrolleyPlanStep.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      ignored: ignored is List
          ? ignored
              .whereType<Map>()
              .map((e) =>
                  DplTrolleyPlanSkipped.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
    );
  }

  bool get hasWork => steps.isNotEmpty;
}

/// What `GET /warehouse/trolleys/:id/plan` answers.
class DplTrolleyPlan {
  final DplWheelTrolley trolley;
  final List<DplTrolleyPlanItem> items;

  /// Half pallets this whole plan completes, across every item.
  final int completes;

  /// Wheels that stay on the cart. Deliberately not dribbled onto the oldest
  /// remaining half pallet: a wheel on the cart is available to every future
  /// plan, while one put on a pallet to no purpose is stuck there.
  final int leftover;

  const DplTrolleyPlan({
    this.trolley = const DplWheelTrolley(),
    this.items = const [],
    this.completes = 0,
    this.leftover = 0,
  });

  factory DplTrolleyPlan.fromJson(Map<String, dynamic> json) {
    final t = json['trolley'];
    final raw = json['items'];
    return DplTrolleyPlan(
      trolley: t is Map
          ? DplWheelTrolley.fromJson(Map<String, dynamic>.from(t))
          : const DplWheelTrolley(),
      items: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => DplTrolleyPlanItem.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      completes: parseIntOr(json['completes']),
      leftover: parseIntOr(json['leftover']),
    );
  }

  bool get hasWork => items.any((i) => i.hasWork);
}
