import '_json_helpers.dart';

/// Empty-to-null, so an absent value and a blank string behave the same. The
/// shared helpers return non-null defaults, which would make "" look like a
/// real reading.
String? _strOrNull(dynamic v) {
  final s = parseStringOr(v).trim();
  return s.isEmpty ? null : s;
}

double? _doubleOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

/// Result of `POST /dispatch/trips/:id/leci-scan` — the LECI slip the driver
/// photographed, read by the backend's offline OCR.
///
/// WHY THIS IS A SEPARATE CALL AND NOT PART OF tata-gate-in
///
/// The gate-in endpoint enforces a plate cross-check: a supplied
/// `leci_truck_no` that does not match the trip's vehicle is rejected with
/// `409 VEHICLE_MISMATCH`. If OCR fed that field directly, one misread
/// character — a '1' read as 'Z', routine on a dot-matrix slip — would strand
/// a loaded truck at the TATA gate behind an error the driver cannot argue
/// with. That is strictly worse than typing the plate.
///
/// So this reads the slip and fills the FORM; the driver confirms, and
/// tata-gate-in runs exactly as before with a human-confirmed value. The
/// server records nothing on this call ([recordsNothing]), so it is safe to
/// call again on every retake.
///
/// WHAT THE TRIP CONTEXT BUYS
///
/// Unlike a bare document scan, here the expected answer is already known —
/// the trip has a vehicle. So [plateStatus] tells the driver, BEFORE
/// submitting, whether the cross-check will pass: a post-submit 409 becomes
/// information at the gate.
class DplLeciScan {
  /// False when nothing legible was found (blank frame, out of focus).
  final bool readable;

  final String? scanId;

  /// Truck number read off the slip. Named to match the gate-in body so the
  /// form field can be filled directly.
  final String? leciTruckNo;
  final String? leciNo;

  /// The vehicle recorded on this trip — what gate-in will compare against.
  final String? tripVehicle;

  /// One of:
  ///   `exact`       — agrees; gate-in will pass
  ///   `ocrTolerant` — agrees once shape-confusable characters collapse, but
  ///                   gate-in compares EXACTLY, so the driver must confirm
  ///                   which plate is on the truck
  ///   `mismatch`    — genuinely different, worth knowing at the gate
  ///   `unknown`     — no vehicle on the trip, so nothing to compare. NOT the
  ///                   same as a failed comparison.
  final String plateStatus;

  /// Null when [plateStatus] is `unknown` — absence of a comparison rather
  /// than a negative result.
  final bool? matchesTrip;

  /// Plain-language explanation of [plateStatus], written for the driver.
  final String? plateNote;

  /// Mean OCR confidence for the page, 0-100 — how legible the photo was.
  final double? pageConfidence;

  final List<DplScanWarning> warnings;

  /// Always true from the server. Kept explicit because the whole design
  /// rests on it: this endpoint writes nothing.
  final bool recordsNothing;

  const DplLeciScan({
    required this.readable,
    this.scanId,
    this.leciTruckNo,
    this.leciNo,
    this.tripVehicle,
    this.plateStatus = 'unknown',
    this.matchesTrip,
    this.plateNote,
    this.pageConfidence,
    this.warnings = const [],
    this.recordsNothing = true,
  });

  bool get hasTruckNo => (leciTruckNo ?? '').isNotEmpty;

  /// The plate agrees exactly — corroborated by data we already hold, which
  /// is stronger than any OCR confidence, so the driver need not re-read it.
  bool get plateConfirmedByTrip => plateStatus == 'exact';

  /// Read something, but it disagrees with the trip. Submitting it as-is
  /// would be rejected, so the driver has to look at the plate.
  bool get plateNeedsAttention =>
      hasTruckNo && (plateStatus == 'mismatch' || plateStatus == 'ocrTolerant');

  DplScanWarning? warningWithCode(String code) {
    for (final w in warnings) {
      if (w.code == code) return w;
    }
    return null;
  }

  /// The photo itself was the problem — offer a retake rather than sending the
  /// driver to type everything.
  bool get isPhotoProblem => warnings.any((w) => w.isPhotoQuality);

  factory DplLeciScan.fromJson(Map<String, dynamic> json) {
    final plate = json['plateCheck'];
    final plateMap = plate is Map
        ? plate.cast<String, dynamic>()
        : const <String, dynamic>{};
    final rawWarnings = json['warnings'];
    return DplLeciScan(
      readable: json['readable'] == true,
      scanId: _strOrNull(json['scanId']),
      leciTruckNo: _strOrNull(json['leci_truck_no'] ?? json['leciTruckNo']),
      leciNo: _strOrNull(json['leci_no'] ?? json['leciNo']),
      tripVehicle: _strOrNull(json['tripVehicle']),
      plateStatus: _strOrNull(plateMap['status']) ?? 'unknown',
      matchesTrip: plateMap['matchesTrip'] is bool
          ? plateMap['matchesTrip'] as bool
          : null,
      plateNote: _strOrNull(plateMap['note']),
      pageConfidence: _doubleOrNull(json['confidence']),
      warnings: rawWarnings is List
          ? rawWarnings
              .whereType<Map>()
              .map((w) => DplScanWarning.fromJson(w.cast<String, dynamic>()))
              .toList()
          : const [],
      recordsNothing: json['recordsNothing'] != false,
    );
  }
}

class DplScanWarning {
  final String code;
  final String message;
  final List<String> fields;

  const DplScanWarning({
    required this.code,
    required this.message,
    this.fields = const [],
  });

  bool get isPhotoQuality => const {
        'BLURRED_IMAGE',
        'LOW_CONTRAST_IMAGE',
        'LOW_RESOLUTION_IMAGE',
        'NO_TEXT_DETECTED',
      }.contains(code);

  factory DplScanWarning.fromJson(Map<String, dynamic> json) {
    final f = json['fields'];
    return DplScanWarning(
      code: _strOrNull(json['code']) ?? 'WARNING',
      message: _strOrNull(json['message']) ?? '',
      fields: f is List ? f.map((e) => e.toString()).toList() : const [],
    );
  }
}
