import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../models/dpl_spd.dart';

/// The individual SPD pack label — Maxion SSR §8, Module 12.
///
/// SIZE IS NOT A CHOICE. The Maxion reference app's `label_stock.dart` lists
/// exactly two die-cuts the plant buys, and names the small one the "Individual
/// wheel / SPD pack scanning label": 50 x 25 mm, QR 19 mm, Medium correction.
/// So an SPD pack prints on the SAME stock as a wheel label, not on the 100 x
/// 75 mm pallet stock — a pack is one wheel going into a box, not a pallet.
///
/// QR PAYLOAD: `MWS|SP26000411`. Three prefixes now exist and they must stay
/// distinguishable at a glance, because each one sends the scanner somewhere
/// different:
///   MW  / GA  — a wheel
///   MWP       — a pallet
///   MWS       — an SPD pack
///
/// One page per pack. They are printed as a run straight after conversion, and
/// a roll that stops between labels is a roll somebody has to re-align.
class SpdLabelPdf {
  const SpdLabelPdf._();

  static const double labelWidthMm = 50;
  static const double labelHeightMm = 25;

  /// 19 mm, from the reference's `LabelStock.scanning`. Medium rather than
  /// Quartile because there are only 25 mm of height to work with and Medium
  /// keeps the module count — and therefore each module's printed size — large
  /// enough for a worn thermal head to resolve.
  static const double _qrBoxMm = 19;

  static const double _padMm = 1.6;

  /// Pure black on pure white. Thermal heads halftone-dither grey, which
  /// destroys read rate on the symbol and legibility on 5 pt text.
  static const PdfColor _ink = PdfColor.fromInt(0xFF000000);
  static const PdfColor _paper = PdfColor.fromInt(0xFFFFFFFF);

  static const PdfPageFormat rollFormat = PdfPageFormat(
    labelWidthMm * PdfPageFormat.mm,
    labelHeightMm * PdfPageFormat.mm,
    marginAll: 0,
  );

  static Future<Uint8List> buildRoll(List<DplSpdPack> packs) async =>
      buildRollDocument(packs).save();

  static pw.Document buildRollDocument(List<DplSpdPack> packs) {
    // Built-in Helvetica only — never PdfGoogleFonts, which fetches from a CDN
    // at build time. A shop floor with no internet would silently get different
    // metrics on a label sized to the millimetre.
    final doc = pw.Document(title: 'SPD packs');
    // An empty run still produces a valid one-page document rather than a
    // zero-page PDF, which some print pipelines reject outright.
    final list = packs.isEmpty ? <DplSpdPack>[const DplSpdPack()] : packs;
    for (final pack in list) {
      doc.addPage(
        pw.Page(pageFormat: rollFormat, build: (_) => _label(pack)),
      );
    }
    return doc;
  }

  static pw.Widget _label(DplSpdPack p) {
    return pw.Container(
      width: double.infinity,
      height: double.infinity,
      color: _paper,
      padding: const pw.EdgeInsets.all(_padMm * PdfPageFormat.mm),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(
            width: _qrBoxMm * PdfPageFormat.mm,
            height: _qrBoxMm * PdfPageFormat.mm,
            child: pw.BarcodeWidget(
              barcode: pw.Barcode.qrCode(
                errorCorrectLevel: pw.BarcodeQRCorrectionLevel.medium,
              ),
              data: p.qrPayload,
              drawText: false,
              color: _ink,
              backgroundColor: _paper,
            ),
          ),
          pw.SizedBox(width: 1.6 * PdfPageFormat.mm),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                // Boxed, and the loudest thing on the label. A pack sitting in
                // a bin next to wheel labels on identical stock has to be
                // tellable apart without reading a number.
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 0.8,
                  ),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: _ink, width: 0.6),
                  ),
                  child: pw.Text(
                    'SPD INDIVIDUAL PACK',
                    style: pw.TextStyle(
                      fontSize: 5.2,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
                _fit(p.packNo, 10),
                if (p.customerPartNo.isNotEmpty) _fit(p.customerPartNo, 7),
                // The wheel inside. A customer query arrives quoting a wheel
                // serial far more often than a pack number.
                if (p.serialNo.isNotEmpty)
                  pw.Text(
                    p.serialNo,
                    style: const pw.TextStyle(fontSize: 5.6),
                  ),
                // The payload in plain text, so a dead scanner never stops the
                // bench — the same rule §5 sets for the pallet label.
                pw.Text(
                  p.qrPayload,
                  style: const pw.TextStyle(fontSize: 4.6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Scaled-down single line.
  ///
  /// The empty guard is not defensive padding: pdf's FittedBox asserts
  /// `width > 0.0` while laying out, so one empty string anywhere in this
  /// column throws instead of rendering — and the throw would happen AFTER the
  /// conversion was already committed on the server.
  static pw.Widget _fit(String text, double fontSize) {
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
}
