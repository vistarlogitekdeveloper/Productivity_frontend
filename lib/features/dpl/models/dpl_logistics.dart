import '_json_helpers.dart';

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _list(dynamic v) =>
    v is List ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];

/// A transport company (backend migration 160).
class DplTransporter {
  final int id;
  final String code;
  final String name;
  final String? gstin;
  final String? contactName;
  final String? phone;
  final bool isActive;

  const DplTransporter({
    required this.id,
    required this.code,
    required this.name,
    this.gstin,
    this.contactName,
    this.phone,
    this.isActive = true,
  });

  factory DplTransporter.fromJson(Map<String, dynamic> j) => DplTransporter(
        id: parseIntOr(j['id']),
        code: parseStringOr(j['code']),
        name: parseStringOr(j['name']),
        gstin: j['gstin'] as String?,
        contactName: j['contact_name'] as String?,
        phone: j['phone'] as String?,
        isActive: j['is_active'] != false,
      );
}

/// A ship-to party: the OEM plant a trip delivers to.
class DplConsignee {
  final int id;
  final String code;
  final String name;
  final String? gstin;
  final String? address;
  final String? city;
  final String? state;
  final String? pincode;
  final bool isActive;

  const DplConsignee({
    required this.id,
    required this.code,
    required this.name,
    this.gstin,
    this.address,
    this.city,
    this.state,
    this.pincode,
    this.isActive = true,
  });

  factory DplConsignee.fromJson(Map<String, dynamic> j) => DplConsignee(
        id: parseIntOr(j['id']),
        code: parseStringOr(j['code']),
        name: parseStringOr(j['name']),
        gstin: j['gstin'] as String?,
        address: j['address'] as String?,
        city: j['city'] as String?,
        state: j['state'] as String?,
        pincode: j['pincode'] as String?,
        isActive: j['is_active'] != false,
      );
}

/// A dispatch lane (a `dpl_plants` row) and the machines that feed it.
class DplLane {
  final int id;
  final String code;
  final String name;
  final bool isActive;
  final List<({int id, String code, String name})> machines;

  const DplLane({
    required this.id,
    required this.code,
    required this.name,
    required this.isActive,
    this.machines = const [],
  });

  factory DplLane.fromJson(Map<String, dynamic> j) => DplLane(
        id: parseIntOr(j['id']),
        code: parseStringOr(j['code']),
        name: parseStringOr(j['name']),
        isActive: j['is_active'] != false,
        machines: _list(j['machines'])
            .map((m) => (
                  id: parseIntOr(m['id']),
                  code: parseStringOr(m['machine_code']),
                  name: parseStringOr(m['machine_name']),
                ))
            .toList(),
      );
}

/// Shipment details recorded on a trip (Ekatm's Shipment Creation).
class DplTripShipment {
  final int tripId;
  final int tripNumber;
  final String? tripDate;
  final String plantCode;
  final String status;
  final String? vehicleNo;
  final DplTransporter? transporter;
  final DplConsignee? consignee;
  final String? driverName;
  final String? driverMobile;
  final String? driverLicenceNo;
  final String? sealNo;
  final String? lrNo;
  final String? lrDate;
  final DateTime? vehicleInAt;
  final DateTime? dockInAt;
  final DateTime? dockOutAt;
  final DateTime? vehicleOutAt;
  final String? tatReason;
  final String? tatRemark;
  final int? minutesAtDock;
  final int? minutesInPlant;

  const DplTripShipment({
    required this.tripId,
    required this.tripNumber,
    required this.plantCode,
    required this.status,
    this.tripDate,
    this.vehicleNo,
    this.transporter,
    this.consignee,
    this.driverName,
    this.driverMobile,
    this.driverLicenceNo,
    this.sealNo,
    this.lrNo,
    this.lrDate,
    this.vehicleInAt,
    this.dockInAt,
    this.dockOutAt,
    this.vehicleOutAt,
    this.tatReason,
    this.tatRemark,
    this.minutesAtDock,
    this.minutesInPlant,
  });

  factory DplTripShipment.fromJson(Map<String, dynamic> j) {
    final t = j['transporter'];
    final c = j['consignee'];
    return DplTripShipment(
      tripId: parseIntOr(j['trip_id']),
      tripNumber: parseIntOr(j['trip_number']),
      tripDate: j['trip_date']?.toString(),
      plantCode: parseStringOr(j['plant_code']),
      status: parseStringOr(j['status']),
      vehicleNo: j['vehicle_no'] as String?,
      transporter: t is Map ? DplTransporter.fromJson(_map(t)) : null,
      consignee: c is Map ? DplConsignee.fromJson(_map(c)) : null,
      driverName: j['transport_driver_name'] as String?,
      driverMobile: j['transport_driver_mobile'] as String?,
      driverLicenceNo: j['driver_licence_no'] as String?,
      sealNo: j['seal_no'] as String?,
      lrNo: j['lr_no'] as String?,
      lrDate: j['lr_date']?.toString(),
      vehicleInAt: parseDateTimeOrNull(j['vehicle_in_at']),
      dockInAt: parseDateTimeOrNull(j['dock_in_at']),
      dockOutAt: parseDateTimeOrNull(j['dock_out_at']),
      vehicleOutAt: parseDateTimeOrNull(j['vehicle_out_at']),
      tatReason: j['tat_reason'] as String?,
      tatRemark: j['tat_remark'] as String?,
      minutesAtDock: parseIntOrNull(j['minutes_at_dock']),
      minutesInPlant: parseIntOrNull(j['minutes_in_plant']),
    );
  }
}

class DplGatePassLine {
  final String customerPartNo;
  final String description;
  final String? hsnCode;
  final int qty;
  final int palletCount;
  final String palletNos;
  final String invoiceNos;

  const DplGatePassLine({
    required this.customerPartNo,
    required this.description,
    required this.qty,
    required this.palletCount,
    required this.palletNos,
    required this.invoiceNos,
    this.hsnCode,
  });

  factory DplGatePassLine.fromJson(Map<String, dynamic> j) => DplGatePassLine(
        customerPartNo: parseStringOr(j['customer_part_no']),
        description: parseStringOr(j['description']),
        hsnCode: j['hsn_code'] as String?,
        qty: parseIntOr(j['qty']),
        palletCount: parseIntOr(j['pallet_count']),
        palletNos: parseStringOr(j['pallet_nos']),
        invoiceNos: parseStringOr(j['invoice_nos']),
      );
}

/// The outward gate pass / delivery challan for a trip.
class DplGatePass {
  final String gatePassNo;
  final DplTripShipment shipment;
  final List<DplGatePassLine> lines;
  final int totalQty;
  final int totalPallets;
  final bool readyForGate;
  final List<String> missing;
  final String qrToken;

  const DplGatePass({
    required this.gatePassNo,
    required this.shipment,
    required this.lines,
    required this.totalQty,
    required this.totalPallets,
    required this.readyForGate,
    required this.missing,
    required this.qrToken,
  });

  factory DplGatePass.fromJson(Map<String, dynamic> j) {
    final totals = _map(j['totals']);
    return DplGatePass(
      gatePassNo: parseStringOr(j['gate_pass_no']),
      shipment: DplTripShipment.fromJson(_map(j['shipment'])),
      lines: _list(j['lines']).map(DplGatePassLine.fromJson).toList(),
      totalQty: parseIntOr(totals['qty']),
      totalPallets: parseIntOr(totals['pallets']),
      readyForGate: j['ready_for_gate'] == true,
      missing: (j['missing'] is List) ? (j['missing'] as List).map((e) => e.toString()).toList() : const [],
      qrToken: parseStringOr(j['qr_token']),
    );
  }
}

/// What security sees after scanning a gate pass.
class DplGatePassCheck {
  final bool valid;
  final String? problem;
  final DateTime? gatedOutAt;
  final String? gatedOutBy;
  final String gatePassNo;
  final String tripStatus;
  final DplTripShipment? shipment;
  final List<DplGatePassLine> lines;
  final int totalQty;

  const DplGatePassCheck({
    required this.valid,
    required this.gatePassNo,
    required this.tripStatus,
    this.problem,
    this.gatedOutAt,
    this.gatedOutBy,
    this.shipment,
    this.lines = const [],
    this.totalQty = 0,
  });

  bool get alreadyGatedOut => gatedOutAt != null;

  factory DplGatePassCheck.fromJson(Map<String, dynamic> j) {
    final out = j['already_gated_out'];
    final s = j['shipment'];
    return DplGatePassCheck(
      valid: j['valid'] == true,
      problem: j['problem'] as String?,
      gatedOutAt: out is Map ? parseDateTimeOrNull(out['at']) : null,
      gatedOutBy: out is Map ? out['by']?.toString() : null,
      gatePassNo: parseStringOr(j['gate_pass_no']),
      tripStatus: parseStringOr(j['trip_status']),
      shipment: s is Map ? DplTripShipment.fromJson(_map(s)) : null,
      lines: _list(j['lines']).map(DplGatePassLine.fromJson).toList(),
      totalQty: parseIntOr(_map(j['totals'])['qty']),
    );
  }
}

/// A slip's reversal state (request → manager decision).
class DplSlipReversal {
  final int slipId;
  final String slipNo;
  final String status;
  final String? invoiceNo;
  final int? tripId;
  final String? reversalStatus;
  final String? reason;
  final String? requestedBy;
  final DateTime? requestedAt;
  final String? decidedBy;
  final String? decisionNote;
  final int? wheelsReturned;
  final List<String> palletsReturned;

  const DplSlipReversal({
    required this.slipId,
    required this.slipNo,
    required this.status,
    this.invoiceNo,
    this.tripId,
    this.reversalStatus,
    this.reason,
    this.requestedBy,
    this.requestedAt,
    this.decidedBy,
    this.decisionNote,
    this.wheelsReturned,
    this.palletsReturned = const [],
  });

  factory DplSlipReversal.fromJson(Map<String, dynamic> j) => DplSlipReversal(
        slipId: parseIntOr(j['slip_id']),
        slipNo: parseStringOr(j['slip_no']),
        status: parseStringOr(j['status']),
        invoiceNo: j['invoice_no'] as String?,
        tripId: parseIntOrNull(j['trip_id']),
        reversalStatus: j['reversal_status'] as String?,
        reason: j['reversal_reason'] as String?,
        requestedBy: j['reversal_requested_by_name'] as String?,
        requestedAt: parseDateTimeOrNull(j['reversal_requested_at']),
        decidedBy: j['reversal_decided_by_name'] as String?,
        decisionNote: j['reversal_decision_note'] as String?,
        wheelsReturned: parseIntOrNull(j['wheels_returned']),
        palletsReturned: _list(j['pallets_returned']).map((p) => parseStringOr(p['pallet_no'])).toList(),
      );
}
