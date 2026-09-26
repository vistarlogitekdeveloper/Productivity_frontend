// CONTRACT tests for POST /dispatch/trips/:id/leci-scan.
//
// The fixtures in test/fixtures were captured by running the REAL backend
// service (vistar_CRM, offline Tesseract over a rendered TATA gate slip) and
// serialising exactly what its controller sends. So these fail when the
// server's shape and this client's expectations drift apart — the actual
// integration risk for a feature split across two repositories — rather than
// checking hand-written JSON that agrees with itself.
//
// The safety assertions are the ones that matter. tata-gate-in rejects a
// supplied truck number that does not match the trip's vehicle with
// 409 VEHICLE_MISMATCH, so if this scan fed that field directly, one misread
// character would strand a loaded truck at the TATA gate. Three properties
// keep that from happening and are pinned below: the scan records nothing,
// the SCANNED plate is never replaced by the expected one, and a disagreement
// is reported rather than resolved.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:productivity_tracker/features/dpl/models/dpl_leci_scan.dart';

void main() {
  DplLeciScan load(String name) {
    final json =
        jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map;
    return DplLeciScan.fromJson((json['data'] as Map).cast<String, dynamic>());
  }

  group('slip matches the trip vehicle', () {
    late DplLeciScan scan;
    setUp(() => scan = load('leci_scan_match.json'));

    test('the truck number is read', () {
      expect(scan.readable, isTrue);
      expect(scan.hasTruckNo, isTrue);
      expect(scan.leciTruckNo, 'MH12AB1234');
    });

    test('the LECI number is read too', () {
      // Saves the driver the second field on the sheet.
      expect(scan.leciNo, 'LE/2026/778101');
    });

    test('the plate agrees exactly, so gate-in will pass', () {
      expect(scan.plateStatus, 'exact');
      expect(scan.matchesTrip, isTrue);
      expect(scan.plateConfirmedByTrip, isTrue);
      // Corroborated by data we already hold, so the driver is not asked to
      // re-check a plate we can prove.
      expect(scan.plateNeedsAttention, isFalse);
    });

    test('SAFETY: the scan records nothing', () {
      // The whole design rests on this. The scan feeds the FORM; gate-in
      // still compares a human-confirmed value, so no OCR reading can trip
      // its VEHICLE_MISMATCH check.
      expect(scan.recordsNothing, isTrue);
    });

    test('no warnings on a clean read', () {
      expect(scan.warnings, isEmpty);
      expect(scan.isPhotoProblem, isFalse);
    });
  });

  group('slip is for a DIFFERENT truck', () {
    late DplLeciScan scan;
    setUp(() => scan = load('leci_scan_mismatch.json'));

    test('the mismatch is reported, not resolved away', () {
      expect(scan.plateStatus, 'mismatch');
      expect(scan.matchesTrip, isFalse);
      expect(scan.plateNeedsAttention, isTrue);
    });

    test('SAFETY: the SCANNED plate comes back, not the expected one', () {
      // The critical assertion. Substituting the trip's vehicle for what was
      // read would destroy the very check being performed — a plate
      // cross-check exists to notice that a different truck turned up.
      expect(scan.leciTruckNo, 'MH12AB1234');
      expect(scan.tripVehicle, 'MH14CD9876');
    });

    test('and the note names both plates so the driver can act on it', () {
      expect(scan.plateNote, isNotNull);
      expect(scan.plateNote, contains('MH12AB1234'));
      expect(scan.plateNote, contains('MH14CD9876'));
    });
  });

  group('unreadable photo', () {
    late DplLeciScan scan;
    setUp(() => scan = load('leci_scan_unreadable.json'));

    test('nothing is invented', () {
      expect(scan.hasTruckNo, isFalse);
      expect(scan.leciTruckNo, isNull);
    });

    test('the reason is actionable and points at the TRUCK', () {
      final w = scan.warningWithCode('NO_TRUCK_NUMBER_READ');
      expect(w, isNotNull);
      // Not "read the paper again" — the plate on the vehicle is the thing
      // that has to be right.
      expect(w!.message, contains('plate on the truck'));
    });

    test('a photo-quality problem is classified as one', () {
      // Drives the retake hint rather than sending the driver to type
      // everything by hand.
      expect(scan.isPhotoProblem, isTrue);
      expect(scan.warningWithCode('NO_TEXT_DETECTED')!.isPhotoQuality, isTrue);
    });
  });

  group('defensive parsing', () {
    test('an empty object does not throw', () {
      final scan = DplLeciScan.fromJson(const {});
      expect(scan.readable, isFalse);
      expect(scan.hasTruckNo, isFalse);
      // Absence of a comparison, not a failed one.
      expect(scan.plateStatus, 'unknown');
      expect(scan.matchesTrip, isNull);
      expect(scan.warnings, isEmpty);
    });

    test('no vehicle on the trip reads as unknown, never as a mismatch', () {
      final scan = DplLeciScan.fromJson(const {
        'readable': true,
        'leci_truck_no': 'MH12AB1234',
        'tripVehicle': null,
        'plateCheck': {'status': 'unknown', 'matchesTrip': null},
      });
      expect(scan.hasTruckNo, isTrue);
      // A driver must not be told the plate is wrong when there was nothing
      // to compare it against.
      expect(scan.plateNeedsAttention, isFalse);
      expect(scan.plateConfirmedByTrip, isFalse);
      expect(scan.matchesTrip, isNull);
    });

    test('an OCR-tolerant match still needs the driver to look', () {
      // Agrees once confusable glyphs collapse — but gate-in compares
      // EXACTLY, so submitting the scanned form as-is would be rejected.
      final scan = DplLeciScan.fromJson(const {
        'readable': true,
        'leci_truck_no': 'MH12AB0234',
        'tripVehicle': 'MH12ABO234',
        'plateCheck': {'status': 'ocrTolerant', 'matchesTrip': false},
      });
      expect(scan.plateNeedsAttention, isTrue);
      expect(scan.plateConfirmedByTrip, isFalse);
    });

    test('unexpected types are tolerated', () {
      // A blank string must not look like a real reading, and a stringified
      // number must not crash a driver's phone mid-shift.
      final scan = DplLeciScan.fromJson(const {
        'readable': true,
        'leci_truck_no': '   ',
        'confidence': '84',
        'warnings': 'not-a-list',
      });
      expect(scan.hasTruckNo, isFalse);
      expect(scan.pageConfidence, 84);
      expect(scan.warnings, isEmpty);
    });
  });
}
