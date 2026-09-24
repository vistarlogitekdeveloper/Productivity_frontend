import '_json_helpers.dart';
import 'dpl_part.dart';

/// A storage location from the manager-maintained master (backend migration 146).
///
/// [usedQty] / [freeQty] are computed server-side from the assignment ledger
/// and travel with every row, so the picker can show "18 / 50 used" without a
/// round trip per location.
class DplLocation {
  final int id;
  final String code;
  final String name;
  final String zone;

  /// How many pieces this location holds. Always set — the backend refuses a
  /// location without one, because a capacity that can be null cannot refuse
  /// an over-fill.
  final int capacityQty;

  final int usedQty;
  final int freeQty;
  final bool isActive;

  const DplLocation({
    required this.id,
    required this.code,
    this.name = '',
    this.zone = '',
    this.capacityQty = 0,
    this.usedQty = 0,
    this.freeQty = 0,
    this.isActive = true,
  });

  factory DplLocation.fromJson(Map<String, dynamic> json) {
    final capacity = parseIntOr(json['capacity_qty'] ?? json['capacityQty']);
    final used = parseIntOr(json['used_qty'] ?? json['usedQty']);
    return DplLocation(
      id: parseIntOr(json['id']),
      code: parseStringOr(json['code']),
      name: parseStringOr(json['name']),
      zone: parseStringOr(json['zone']),
      capacityQty: capacity,
      usedQty: used,
      // Fall back to computing it rather than showing a wrong zero if an
      // endpoint ever returns the row without the ledger roll-up.
      freeQty: json.containsKey('free_qty') || json.containsKey('freeQty')
          ? parseIntOr(json['free_qty'] ?? json['freeQty'])
          : (capacity - used).clamp(0, capacity),
      isActive: json['is_active'] is bool
          ? json['is_active'] as bool
          : json['isActive'] is bool
              ? json['isActive'] as bool
              : true,
    );
  }

  Map<String, dynamic> toJsonForWrite() => {
        'code': code,
        if (name.isNotEmpty) 'name': name,
        if (zone.isNotEmpty) 'zone': zone,
        'capacity_qty': capacityQty,
        'is_active': isActive,
      };

  DplLocation copyWith({
    int? id,
    String? code,
    String? name,
    String? zone,
    int? capacityQty,
    int? usedQty,
    int? freeQty,
    bool? isActive,
  }) {
    return DplLocation(
      id: id ?? this.id,
      code: code ?? this.code,
      name: name ?? this.name,
      zone: zone ?? this.zone,
      capacityQty: capacityQty ?? this.capacityQty,
      usedQty: usedQty ?? this.usedQty,
      freeQty: freeQty ?? this.freeQty,
      isActive: isActive ?? this.isActive,
    );
  }

  /// "FG-A-03 · Rack A" — what the picker row shows as its title.
  String get displayLabel {
    final n = name.trim();
    return n.isEmpty ? code : '$code · $n';
  }

  bool get isFull => freeQty <= 0;

  /// 0..1, for the capacity bar.
  double get fillRatio =>
      capacityQty <= 0 ? 0 : (usedQty / capacityQty).clamp(0.0, 1.0);
}

/// "This plan item's output is stored at that location."
class DplLocationAssignment {
  final int id;
  final int locationId;
  final int planId;
  final int planItemId;
  final int partId;
  final int qty;

  /// `stored` or `released`.
  final String status;

  final String remarks;
  final DateTime? assignedAt;

  /// Eager-loaded by the read endpoint so the card can name the rack without
  /// a second lookup.
  final DplLocation? location;

  final DplPart? part;

  const DplLocationAssignment({
    required this.id,
    required this.locationId,
    required this.planItemId,
    this.planId = 0,
    this.partId = 0,
    this.qty = 0,
    this.status = 'stored',
    this.remarks = '',
    this.assignedAt,
    this.location,
    this.part,
  });

  factory DplLocationAssignment.fromJson(Map<String, dynamic> json) {
    final rawLocation = json['location'];
    final rawPart = json['part'];
    return DplLocationAssignment(
      id: parseIntOr(json['id']),
      locationId: parseIntOr(json['location_id'] ?? json['locationId']),
      planId: parseIntOr(json['plan_id'] ?? json['planId']),
      planItemId: parseIntOr(json['plan_item_id'] ?? json['planItemId']),
      partId: parseIntOr(json['part_id'] ?? json['partId']),
      qty: parseIntOr(json['qty']),
      status: parseStringOr(json['status'], 'stored'),
      remarks: parseStringOr(json['remarks']),
      assignedAt: parseDateTimeOrNull(json['assigned_at'] ?? json['assignedAt']),
      location: rawLocation is Map
          ? DplLocation.fromJson(Map<String, dynamic>.from(rawLocation))
          : null,
      part: rawPart is Map
          ? DplPart.fromJson(Map<String, dynamic>.from(rawPart))
          : null,
    );
  }

  bool get isStored => status.toLowerCase() == 'stored';
}
