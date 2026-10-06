import '_json_helpers.dart';

class DplPart {
  final int id;
  /// Customer-facing part number (`customer_part_no` on the backend).
  final String partNumber;
  /// Short code shown to operators (e.g. "102D1"). Backend field `description`.
  final String description;
  /// Long descriptive name (e.g. "X0 HL ASSEMBLY WO MIC CUTOUT").
  final String name;
  final String substratePartNo;
  final String materialCode;
  /// Optional machine the part belongs to — backend annotates parts with
  /// `machine_name` so the Excel parser can disambiguate when the same
  /// `description` (e.g. "102ZX") exists for more than one machine.
  final String machineName;
  final bool isActive;

  /// Wheels per full pallet (`packaging_qty`). Null when the master has none.
  ///
  /// READ-ONLY here, and deliberately absent from [toJsonForWrite]: it is
  /// edited on its own screen (`/manager/packaging-qtys`), and sending it back
  /// from the parts master would let a save there overwrite it.
  final int? packagingQty;

  /// What the SPD master sticker calls the item, e.g. "ALLOY WHEEL FOR Z101"
  /// (backend migration 198).
  ///
  /// NULL MEANS "NOT SENT", not "blank": a backend that predates the column
  /// refuses any part save that mentions it, so [toJsonForWrite] includes it
  /// only when it is known — read from a server that has it, or typed in the
  /// form. An empty string clears it.
  final String? spdDescription;

  const DplPart({
    required this.id,
    required this.partNumber,
    required this.description,
    this.name = '',
    this.substratePartNo = '',
    this.materialCode = '',
    this.machineName = '',
    this.isActive = true,
    this.packagingQty,
    this.spdDescription,
  });

  factory DplPart.fromJson(Map<String, dynamic> json) {
    return DplPart(
      id: parseIntOr(json['id']),
      partNumber: parseStringOr(
        json['customer_part_no'] ??
            json['customerPartNo'] ??
            json['part_number'] ??
            json['partNumber'] ??
            json['code'],
      ),
      description: parseStringOr(json['description']),
      name: parseStringOr(json['part_name'] ?? json['partName'] ?? json['name']),
      substratePartNo: parseStringOr(
        json['substrate_part_no'] ?? json['substratePartNo'],
      ),
      materialCode: parseStringOr(
        json['material_code'] ?? json['materialCode'],
      ),
      machineName: parseStringOr(
        json['machine_name'] ?? json['machineName'],
      ),
      isActive: json['is_active'] is bool
          ? json['is_active'] as bool
          : json['isActive'] is bool
              ? json['isActive'] as bool
              : true,
      packagingQty: _positiveOrNull(
        json['packaging_qty'] ?? json['packagingQty'],
      ),
      spdDescription: json.containsKey('spd_description')
          ? parseStringOr(json['spd_description'])
          : null,
    );
  }

  /// A pallet size of 0 or below is no pallet size at all.
  static int? _positiveOrNull(dynamic value) {
    final n = parseIntOrNull(value);
    return (n == null || n <= 0) ? null : n;
  }

  /// Convenience label for dropdowns/autocomplete:
  ///   "{description} — {part_name}"  or fallback chain.
  String get displayLabel {
    final desc = description.trim();
    final nm = name.trim();
    final pn = partNumber.trim();

    if (desc.isNotEmpty && nm.isNotEmpty) return '$desc — $nm';
    if (desc.isNotEmpty) return desc;
    if (nm.isNotEmpty) return nm;
    if (pn.isNotEmpty) return pn;
    return '#$id';
  }

  Map<String, dynamic> toJsonForWrite() => {
        'customer_part_no': partNumber,
        'description': description,
        if (name.isNotEmpty) 'part_name': name,
        // Sent ALWAYS, as null when blank, rather than being omitted when
        // empty like the fields around them. These two became editable on the
        // parts master so QA's scan can resolve a substrate to a customer
        // part; omitting them on a blank value would mean a manager could add
        // a mapping but never correct a wrong one — the PUT would simply not
        // mention the field and the old value would survive. The backend's
        // create/update validators both `allow(null, '')`, and the columns
        // are nullable, so an explicit null clears them properly.
        'substrate_part_no': substratePartNo.isEmpty ? null : substratePartNo,
        'material_code': materialCode.isEmpty ? null : materialCode,
        if (machineName.isNotEmpty) 'machine_name': machineName,
        'is_active': isActive,
        if (spdDescription != null)
          'spd_description':
              spdDescription!.trim().isEmpty ? null : spdDescription!.trim(),
      };

  DplPart copyWith({
    int? id,
    String? partNumber,
    String? description,
    String? name,
    String? substratePartNo,
    String? materialCode,
    String? machineName,
    bool? isActive,
  }) {
    return DplPart(
      id: id ?? this.id,
      partNumber: partNumber ?? this.partNumber,
      description: description ?? this.description,
      name: name ?? this.name,
      substratePartNo: substratePartNo ?? this.substratePartNo,
      materialCode: materialCode ?? this.materialCode,
      machineName: machineName ?? this.machineName,
      isActive: isActive ?? this.isActive,
      packagingQty: packagingQty,
      spdDescription: spdDescription,
    );
  }
}
