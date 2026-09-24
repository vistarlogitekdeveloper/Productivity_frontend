import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_pallet.dart';
import 'package:productivity_tracker/features/dpl/qa/services/pallet_label_pdf.dart';

/// The master pallet label is a physical artefact: 100 mm x 75 mm of Avery
/// Chromo stock with a 34 mm QR on it. `flutter analyze` proves it compiles and
/// says nothing about whether it RENDERS — a pdf-package layout error (an
/// unbounded flex, a barcode that cannot measure itself, text that overflows a
/// fixed box) only surfaces when `save()` runs.
///
/// So these tests run the real document builder, and they lean on the inputs
/// that would break it in the plant rather than in a demo: no standard pallet
/// quantity, a part name longer than the label, a merged pallet carrying the
/// extra cell, and an empty response.
DplPalletSticker _sticker({
  String palletNo = 'PM26000012',
  String type = 'PM',
  int qty = 96,
  int? standardQty = 96,
  String partName = 'X0 HL ASSEMBLY WO MIC CUTOUT',
  String mergedFrom = 'H26000007',
}) {
  return DplPalletSticker(
    palletId: 5,
    palletNo: palletNo,
    palletType: type,
    qty: qty,
    standardQty: standardQty,
    customerPartNo: '546469500102ZX',
    description: '102D1',
    partName: partName,
    machineName: 'Pack 1',
    locationCode: 'FG-A-03',
    shiftCode: 'A',
    closedAt: DateTime(2026, 9, 22, 10),
    oldestWheelAt: DateTime(2026, 9, 5, 6),
    mergedFromPalletNo: mergedFrom,
    serialFrom: 'GA2600000101',
    serialTo: 'GA2600000196',
  );
}

void main() {
  test('the page really is the 100 x 75 mm die-cut', () {
    // Not a design choice. The Maxion reference app's label_stock.dart records
    // the stock the plant actually buys — "Maxion stocks exactly two Avery
    // Chromo die-cuts, so every label the system prints must be one of these".
    // A page box that does not match makes the printer scale the artwork and
    // drift across the roll.
    expect(
      PalletLabelPdf.pageFormat.width,
      closeTo(100 * PdfPageFormat.mm, 0.01),
    );
    expect(
      PalletLabelPdf.pageFormat.height,
      closeTo(75 * PdfPageFormat.mm, 0.01),
    );
    expect(PalletLabelPdf.pageFormat.marginLeft, 0);
  });

  test('it renders, and emits exactly one page', () async {
    final bytes = await PalletLabelPdf.build(_sticker());
    expect(bytes.length, greaterThan(1000));
    // %PDF-
    expect(bytes.sublist(0, 5), [0x25, 0x50, 0x44, 0x46, 0x2D]);

    final doc = PalletLabelPdf.buildDocument(_sticker());
    expect(doc.document.pdfPageList.pages.length, 1);
  });

  test('it renders with no standard pallet quantity set', () async {
    // The state every Maxion item is in until that master data lands. If the
    // label only renders for parts with a target, the first real pallet closed
    // at the plant throws instead of printing.
    final bytes = await PalletLabelPdf.build(_sticker(standardQty: null, qty: 37));
    expect(bytes.length, greaterThan(1000));
  });

  test('a part name far longer than the label does not overflow it', () async {
    // The item master has names that run past the width of the stock. The
    // layout clamps rather than throwing, because a pallet that cannot be
    // labelled cannot leave the pack point.
    final bytes = await PalletLabelPdf.build(
      _sticker(
        partName: 'X0 HL ASSEMBLY WITHOUT MICROPHONE CUTOUT LONG VARIANT '
            'FOR EXPORT MARKETS WITH ADDITIONAL TRIM AND FIXINGS',
      ),
    );
    expect(bytes.length, greaterThan(1000));
  });

  test('every pallet type renders, including one the app has not seen', () async {
    for (final t in ['P', 'H', 'PM', '', 'ZZ']) {
      final bytes = await PalletLabelPdf.build(_sticker(type: t));
      expect(bytes.length, greaterThan(1000), reason: 'type "$t" failed');
    }
  });

  test('a blank sticker still produces a page rather than throwing', () async {
    // Printing follows a successful close. An exception here would look to the
    // operator exactly like the close failing, and they would close it again.
    final bytes = await PalletLabelPdf.build(const DplPalletSticker());
    expect(bytes.length, greaterThan(500));
  });
}
