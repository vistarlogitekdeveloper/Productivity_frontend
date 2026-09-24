import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../models/dpl_pallet.dart';

/// The 100 x 75 mm master pallet label — Maxion SSR v3.0 Module 4.
///
/// SIZE IS NOT A DESIGN CHOICE. The Maxion reference app's `label_stock.dart`
/// documents the physical stock the plant buys: "Maxion stocks exactly two
/// Avery Chromo die-cuts, so every label the system prints must be one of
/// these — Pallet 100 mm x 75 mm, 1UP, 500 pcs/roll". SSR §17.2 says
/// 100 x 150 mm, but it also says "Final choice fixed in the label trial",
/// and the reference app records what is actually loaded on the printers.
/// The die-cut wins: an `@page` box that does not match makes the printer
/// scale the artwork and drift across the roll.
///
/// WHAT THE QR CARRIES, AND WHY SO LITTLE
/// SSR §5, Pallet QR row: "MWP|PM26000012 — Only the pallet number is in the
/// code. Scanning it shows the full wheel list from the system."
///
/// That is deliberate and worth not 'improving'. A pallet's contents change on
/// a merge, and §5 says the pallet QR "is reprinted when the pallet changes".
/// A payload that embedded the quantity would be wrong the moment the pallet
/// was topped up; a bare number always resolves to the truth. Everything else
/// on this label is human-readable text, printed once, for a person.
///
/// Open point C-04 settles the wheel list: "QR plus a summary is enough. A
/// separate contents sheet can be printed when needed." So no serial list.
class PalletLabelPdf {
  const PalletLabelPdf._();

  static const double labelWidthMm = 100;
  static const double labelHeightMm = 75;

  /// 34 mm at Quartile, straight from the reference app's `LabelStock.pallet`:
  /// "100x75 has room to spare, so buy the extra damage tolerance: these ride
  /// outdoors on trailers and get scuffed by strapping."
  static const double _qrBoxMm = 34;

  static const double _padMm = 2.5;
  static const double _hairline = 0.75;

  /// Pure black on pure white, no greys. Thermal heads halftone-dither grey,
  /// which destroys read rate on the symbol and legibility on 7 pt text.
  static const PdfColor _ink = PdfColor.fromInt(0xFF000000);
  static const PdfColor _paper = PdfColor.fromInt(0xFFFFFFFF);

  static const PdfPageFormat pageFormat = PdfPageFormat(
    labelWidthMm * PdfPageFormat.mm,
    labelHeightMm * PdfPageFormat.mm,
    marginAll: 0,
  );

  static Future<Uint8List> build(DplPalletSticker data) async =>
      buildDocument(data).save();

  static pw.Document buildDocument(DplPalletSticker data) {
    // Built-in Helvetica/Courier only — never PdfGoogleFonts, which fetches
    // from a CDN at build time. A shop floor with no internet would silently
    // get different metrics on a label sized to the millimetre.
    final doc = pw.Document(title: 'Pallet ${data.palletNo}');
    doc.addPage(
      pw.Page(
        pageFormat: pageFormat,
        build: (_) => _label(data),
      ),
    );
    return doc;
  }

  static pw.Widget _label(DplPalletSticker d) {
    return pw.Container(
      width: double.infinity,
      height: double.infinity,
      color: _paper,
      padding: const pw.EdgeInsets.all(_padMm * PdfPageFormat.mm),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          _titleBar(d),
          pw.SizedBox(height: 2 * PdfPageFormat.mm),
          pw.Expanded(child: _body(d)),
          _foot(d),
        ],
      ),
    );
  }

  /// Type is the loudest thing after the number. An operator deciding whether
  /// a pallet can be shipped or must go back for topping up reads FULL / HALF
  /// / MERGED from across a bay.
  static pw.Widget _titleBar(DplPalletSticker d) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Expanded(
          child: pw.Text(
            'MAXION WHEELS',
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          ),
        ),
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: _ink, width: _hairline),
          ),
          child: pw.Text(
            d.typeWord,
            style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
          ),
        ),
      ],
    );
  }

  static pw.Widget _body(DplPalletSticker d) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        // Fixed-width column so the QR is never squeezed by a long part name —
        // a scaled-down symbol is an unreadable symbol.
        pw.Container(
          width: _qrBoxMm * PdfPageFormat.mm,
          height: _qrBoxMm * PdfPageFormat.mm,
          child: pw.BarcodeWidget(
            barcode: pw.Barcode.qrCode(
              errorCorrectLevel: pw.BarcodeQRCorrectionLevel.quartile,
            ),
            data: d.qrPayload,
            drawText: false,
            color: _ink,
            backgroundColor: _paper,
          ),
        ),
        pw.SizedBox(width: 3 * PdfPageFormat.mm),
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              // The pallet number, as large as it will go. This is what
              // somebody reads out over a radio when the scanner will not.
              _shrinkToFit(d.palletNo, 20),
              _shrinkToFit(d.customerPartNo, 13),
              pw.Text(
                d.qtyLine,
                style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
              ),
              if (d.partName.isNotEmpty)
                pw.Text(
                  d.partName,
                  maxLines: 2,
                  style: const pw.TextStyle(fontSize: 7),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// One line of text scaled down to fit the column it is given.
  ///
  /// The empty guard is not defensive padding — pdf's FittedBox asserts
  /// `width > 0.0` while laying out, so a single empty string anywhere in this
  /// column throws instead of rendering, and the throw happens AFTER the
  /// pallet has already been closed on the server. The operator would read
  /// that as the close failing and close it again. A missing field prints as
  /// nothing; it never takes the label with it.
  static pw.Widget _shrinkToFit(String text, double fontSize) {
    if (text.trim().isEmpty) return pw.SizedBox();
    return pw.FittedBox(
      fit: pw.BoxFit.scaleDown,
      alignment: pw.Alignment.centerLeft,
      child: pw.Text(
        text,
        style: pw.TextStyle(fontSize: fontSize, fontWeight: pw.FontWeight.bold),
      ),
    );
  }

  /// The detail row. SSR §5: "The label also prints item, quantity, dates
  /// and, for a merged pallet, the old half pallet number."
  static pw.Widget _foot(DplPalletSticker d) {
    final cells = d.detailCells;
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Divider(height: 2 * PdfPageFormat.mm, thickness: _hairline, color: _ink),
        pw.Wrap(
          spacing: 6,
          runSpacing: 1,
          children: [
            for (final c in cells)
              pw.RichText(
                text: pw.TextSpan(
                  children: [
                    pw.TextSpan(
                      text: '${c.key}: ',
                      style: const pw.TextStyle(fontSize: 6.5),
                    ),
                    pw.TextSpan(
                      text: c.value,
                      style: pw.TextStyle(
                        fontSize: 6.5,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        pw.SizedBox(height: 1),
        // The payload in plain text, so a dead scanner never stops the floor —
        // SSR §5: "the same information is printed in normal text under the
        // code, so a damaged code can still be keyed in".
        pw.Text(
          d.qrPayload,
          style: const pw.TextStyle(fontSize: 6, font: null),
        ),
      ],
    );
  }
}
