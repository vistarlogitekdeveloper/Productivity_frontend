import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_feature_flags.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_trip_label_scan.dart';
import 'package:productivity_tracker/features/dpl/summary/services/master_sticker_pdf.dart';

/// The master sticker is a 100x75 mm thermal label that goes on a loaded
/// trolley. `flutter analyze` proves it compiles; only running `save()` proves
/// it renders, because a pdf-package layout fault — an unbounded flex, a
/// barcode that cannot measure itself — surfaces nowhere else.
DplMasterSticker _sticker({
  int scannedQty = 16,
  String customerPartNo = '546469500102ZX',
  List<String>? serials,
}) {
  return DplMasterSticker(
    tripId: 7,
    planId: 21,
    tripNumber: 2,
    tripDate: DateTime(2026, 9, 19),
    plantCode: 'NEXON_EV',
    vehicleNo: 'GJ01AB1234',
    plannedQty: 16,
    scannedQty: scannedQty,
    customerPartNo: customerPartNo,
    substratePartNo: '195245450-083',
    materialCode: '587136190-083',
    description: '102ZX',
    partName: 'NEXON MCE2 SR HL SUBSTRATE 102CC SML RS',
    machineName: 'Nexon SR',
    shiftCode: 'A',
    serialFrom: 'GA2600000147',
    serialTo: 'GA2600000162',
    serials: serials ??
        List.generate(scannedQty, (i) => 'GA26000001${(47 + i).toString()}'),
  );
}

void main() {
  test('page format is exactly the 100 x 75 mm pallet die-cut', () {
    expect(
      MasterStickerPdf.pageFormat.width,
      closeTo(100 * PdfPageFormat.mm, 0.001),
    );
    expect(
      MasterStickerPdf.pageFormat.height,
      closeTo(75 * PdfPageFormat.mm, 0.001),
    );
    expect(MasterStickerPdf.pageFormat.marginLeft, 0);
    expect(MasterStickerPdf.pageFormat.marginTop, 0);
  });

  test('renders a master sticker without throwing', () async {
    final bytes = await MasterStickerPdf.build(_sticker());
    expect(bytes.lengthInBytes, greaterThan(500));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });

  test('renders when every optional field is empty', () async {
    // A trip with no vehicle, no shift and an unnamed part must still produce
    // a label rather than failing the print at the trolley.
    const bare = DplMasterSticker(tripId: 1, planId: 1, scannedQty: 1);
    final bytes = await MasterStickerPdf.build(bare);
    expect(bytes.lengthInBytes, greaterThan(500));
  });

  test('renders an unusually long customer part reference', () async {
    // FittedBox scales it rather than overflowing the die-cut; the failure
    // mode guarded against is a layout exception at print time.
    final bytes = await MasterStickerPdf.build(
      _sticker(customerPartNo: '5464695001020ZX-EXTENDED-VARIANT-0001'),
    );
    expect(bytes.lengthInBytes, greaterThan(500));
  });

  test('renders a large scanned batch', () async {
    // The grid is capped at six cells, so a 500-piece batch must not push the
    // layout past the page.
    final bytes = await MasterStickerPdf.build(_sticker(scannedQty: 500));
    expect(bytes.lengthInBytes, greaterThan(500));
  });

  test('QR payload is distinguishable from a single-piece label', () {
    // A piece label starts `GA|`; the master starts `GAM|`, so a scanner can
    // tell a unit load from one part by its first field alone.
    final payload = _sticker().qrPayload;
    expect(payload.startsWith('GAM|'), isTrue);
    expect(payload.startsWith('GA|'), isFalse);
    final parts = payload.split('|');
    expect(parts.length, 6);
    expect(parts[2], '546469500102ZX');
    expect(parts[5], '16', reason: 'carries the scanned quantity');
  });

  test('the plan-time label cap is OFF, so trips can always be planned', () {
    // Turning this on with nothing printed drives the allowance to zero, which
    // makes the qty formatter reject every keystroke and leaves Submit
    // permanently disabled — there is no way to plan a trip at all. It was
    // switched off for exactly that reason and must not drift back on without
    // someone deliberately changing this line and the matching backend env var
    // DPL_ENFORCE_LABEL_STOCK_ON_PLAN.
    //
    // This does NOT weaken the dispatch guarantee: createSlipFromTrip still
    // refuses to cut a slip until every planned piece has been scanned onto
    // the trip, and that gate is independent of this flag.
    expect(
      DplFeatureFlags.enforceLabelStockOnPlan,
      isFalse,
      reason: 'planning must stay unblocked until labels flow for every part',
    );
  });

  test('with the cap off, the hint informs rather than accuses', () {
    // "No labels printed" beside a field that accepts any value reads as a
    // malfunction. Unenforced wording has to state a fact, not a verdict.
    const nothing = DplLabelStock();
    expect(nothing.hintFor(enforced: false), 'No labels printed yet');

    const some = DplLabelStock(
      labelledQty: 28,
      onTripQty: 16,
      freeQty: 12,
      availableQty: 12,
    );
    expect(some.hintFor(enforced: false), 'Labels: 12 free of 28');
    expect(some.hintFor(enforced: true), 'Labels: 12 NOS');
  });

  test('a zero allowance says WHY, not just that it is zero', () {
    // The bug this pins: a part with 28 printed labels read "No labels
    // printed", which sent the planner off to print more when nothing of the
    // sort was wrong.
    const nothing = DplLabelStock();
    expect(nothing.nothingPrinted, isTrue);
    expect(nothing.allLoaded, isFalse);
    expect(nothing.hint, 'No labels printed');

    const loaded = DplLabelStock(
      labelledQty: 28,
      onTripQty: 28,
      freeQty: 0,
      committedQty: 0,
      availableQty: 0,
    );
    expect(loaded.nothingPrinted, isFalse);
    expect(loaded.allLoaded, isTrue);
    expect(loaded.hint, contains('all 28 already loaded'));
    expect(loaded.hint, isNot(contains('No labels printed')));
  });

  test('another trip PLANNING a part does not reduce what may be planned', () {
    // The deadlock this pins: reserving stock at plan time meant two open
    // trips claiming 32 NOS left nothing to plan a third with, while those
    // same two could not be sent without scanning every piece. Both doors
    // locked. A plan is an intention; only a scan consumes a label.
    const stock = DplLabelStock(
      labelledQty: 28,
      onTripQty: 0,
      freeQty: 28,
      committedQty: 32, // two other trips have planned 32 NOS
      availableQty: 28, // ...and it changes nothing
    );
    expect(stock.availableQty, 28);
    expect(stock.allLoaded, isFalse);
    expect(stock.plannedElsewhere, isTrue);
    // Still reported, so the planner knows the part is spoken for.
    expect(stock.hint, contains('28 NOS'));
    expect(stock.hint, contains('32 planned elsewhere'));
  });

  test('scanning pieces onto a trip DOES reduce what may be planned', () {
    const stock = DplLabelStock(
      labelledQty: 28,
      onTripQty: 16,
      freeQty: 12,
      committedQty: 0,
      availableQty: 12,
    );
    expect(stock.availableQty, 12);
    expect(stock.hint, 'Labels: 12 NOS');
  });

  test('scan progress treats an unknown plan as NOT complete', () {
    // Absence of evidence is not evidence of scanning — a plan the server has
    // no row for must never satisfy the Send gate.
    const progress = DplTripScanProgress(tripId: 1, plans: []);
    expect(progress.areComplete([99]), isFalse);
    expect(progress.scannedFor(99), 0);
  });

  test('scan progress is complete only when every named plan is', () {
    const progress = DplTripScanProgress(
      tripId: 1,
      plans: [
        DplTripPlanScan(planId: 1, plannedQty: 16, scannedQty: 16, isComplete: true),
        DplTripPlanScan(planId: 2, plannedQty: 16, scannedQty: 4, isComplete: false),
      ],
    );
    expect(progress.areComplete([1]), isTrue);
    expect(progress.areComplete([1, 2]), isFalse);
    expect(progress.areComplete([2]), isFalse);
  });
}
