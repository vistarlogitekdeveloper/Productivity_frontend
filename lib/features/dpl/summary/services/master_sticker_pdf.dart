import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:qr_flutter/qr_flutter.dart' show QrCode, QrErrorCorrectLevel;

import '../../models/dpl_trip_label_scan.dart';

/// The aggregate "master sticker" that goes on a loaded trolley.
///
/// One label describing what a whole trip plan contains: the customer part, the
/// quantity actually scanned onto it, the serial range, and the trip it leaves
/// on. Scanning its QR identifies the unit load; scanning any individual piece
/// label still identifies that piece. Both are needed — the master is what a
/// forklift or a gate reads across a distance.
///
/// Geometry is the Maxion Wheels **pallet** stock, the larger of the two
/// die-cuts already loaded on the plant's printers:
///
///   Stock        Avery Chromo 100 mm x 75 mm, 1UP, 1.5" core, 500/roll
///   Page box     exactly the die-cut, zero margin
///   Cut rule     1 px (0.75 pt) solid black, inside the box
///   Padding      2.5 mm, with a 1 mm inner frame
///   QR           36 mm square, ECC **Quartile**, 2-module quiet zone
///   Title bar    plant + "MASTER" tag, 2 px rule under it
///   Detail grid  2 columns, up to 6 cells
///   Footer       full QR payload (mono) + scanned quantity
///
/// The stock carries a higher error-correction level than the small piece
/// label: at 100x75 there is room for the redundancy, and these ride on
/// trolleys that get scuffed in a way a sticker on a single part does not.
///
/// Same two rules as the piece label, for the same reasons: pure black on pure
/// white (thermal heads halftone grey and destroy read rate), and built-in
/// fonts only (PdfGoogleFonts fetches from a CDN, and a shop floor with no
/// internet would silently get different metrics).
class MasterStickerPdf {
  const MasterStickerPdf._();

  static const double labelWidthMm = 100;
  static const double labelHeightMm = 75;
  static const double _padMm = 2.5;
  static const double _framePadMm = 1;
  static const double _qrBoxMm = 36;
  static const int _quietModules = 2;
  static const double _hairline = 0.75;

  static const PdfColor _ink = PdfColor.fromInt(0xFF000000);
  static const PdfColor _paper = PdfColor.fromInt(0xFFFFFFFF);

  static const PdfPageFormat pageFormat = PdfPageFormat(
    labelWidthMm * PdfPageFormat.mm,
    labelHeightMm * PdfPageFormat.mm,
    marginAll: 0,
  );

  static Future<Uint8List> build(DplMasterSticker data) async {
    final doc = pw.Document(
      title: 'Master Sticker',
      author: 'Grupo Antolin India Private Limited',
    );
    final bold = pw.Font.helveticaBold();
    final regular = pw.Font.helvetica();
    final mono = pw.Font.courierBold();

    doc.addPage(
      pw.Page(
        pageFormat: pageFormat,
        margin: pw.EdgeInsets.zero,
        build: (_) => _label(data, bold: bold, regular: regular, mono: mono),
      ),
    );
    return doc.save();
  }

  static pw.Widget _label(
    DplMasterSticker d, {
    required pw.Font bold,
    required pw.Font regular,
    required pw.Font mono,
  }) {
    final code = d.customerPartNo.isNotEmpty ? d.customerPartNo : d.description;

    return pw.Container(
      width: labelWidthMm * PdfPageFormat.mm,
      height: labelHeightMm * PdfPageFormat.mm,
      decoration: pw.BoxDecoration(
        color: _paper,
        border: pw.Border.all(color: _ink, width: _hairline),
      ),
      padding: const pw.EdgeInsets.all(_padMm * PdfPageFormat.mm),
      child: pw.Padding(
        padding: const pw.EdgeInsets.all(_framePadMm * PdfPageFormat.mm),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            _bar(d, bold: bold),
            _main(d, code: code, bold: bold, regular: regular),
            _grid(d, bold: bold, regular: regular),
            _foot(d, bold: bold, mono: mono),
          ],
        ),
      ),
    );
  }

  /// Title row: who made it, and an outlined MASTER tag so this label is never
  /// mistaken for a piece label at a glance.
  static pw.Widget _bar(DplMasterSticker d, {required pw.Font bold}) {
    return pw.Container(
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _ink, width: 1.5)),
      ),
      padding: const pw.EdgeInsets.only(bottom: 1.5 * PdfPageFormat.mm),
      margin: const pw.EdgeInsets.only(bottom: 2 * PdfPageFormat.mm),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(
            'GRUPO ANTOLIN${d.plantCode.isEmpty ? '' : ' · ${d.plantCode}'}',
            style: pw.TextStyle(font: bold, fontSize: 12, letterSpacing: 0.375),
          ),
          pw.Container(
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: _ink, width: 1.125),
            ),
            padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            child: pw.Text(
              'MASTER STICKER',
              style: pw.TextStyle(font: bold, fontSize: 8, letterSpacing: 0.225),
            ),
          ),
        ],
      ),
    );
  }

  /// QR beside the identity block.
  ///
  /// A Table with fixed + flex columns rather than a Row: `pw.BarcodeWidget`
  /// cannot measure itself inside an unbounded flex and silently renders
  /// nothing, which is documented at the slip builder's barcode call site.
  static pw.Widget _main(
    DplMasterSticker d, {
    required String code,
    required pw.Font bold,
    required pw.Font regular,
  }) {
    return pw.Table(
      columnWidths: {
        0: const pw.FixedColumnWidth(_qrBoxMm * PdfPageFormat.mm),
        1: const pw.FlexColumnWidth(1),
      },
      children: [
        pw.TableRow(
          verticalAlignment: pw.TableCellVerticalAlignment.middle,
          children: [
            _qr(d.qrPayload),
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 4 * PdfPageFormat.mm),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                mainAxisSize: pw.MainAxisSize.min,
                children: [
                  pw.FittedBox(
                    fit: pw.BoxFit.scaleDown,
                    alignment: pw.Alignment.centerLeft,
                    child: pw.Text(
                      code.isEmpty ? '-' : code,
                      maxLines: 1,
                      style: pw.TextStyle(
                        font: bold,
                        fontSize: _codeFontSize(code),
                        letterSpacing: -0.225,
                      ),
                    ),
                  ),
                  pw.SizedBox(height: 1.5 * PdfPageFormat.mm),
                  pw.Text(
                    'QTY: ${d.scannedQty} NOS',
                    style: pw.TextStyle(font: bold, fontSize: 14),
                  ),
                  if (d.partName.isNotEmpty || d.description.isNotEmpty) ...[
                    pw.SizedBox(height: 1 * PdfPageFormat.mm),
                    pw.Text(
                      _clip(
                        d.partName.isNotEmpty ? d.partName : d.description,
                        44,
                      ),
                      maxLines: 2,
                      style: pw.TextStyle(font: regular, fontSize: 8),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Maxion sizes the code by its length so a long part number still fits.
  static double _codeFontSize(String code) {
    final n = code.trim().length;
    if (n <= 10) return 20;
    if (n <= 14) return 16;
    if (n <= 18) return 13;
    return 11;
  }

  static pw.Widget _qr(String payload) {
    final data = payload.trim().isEmpty ? ' ' : payload;

    var modules = 33;
    try {
      modules = QrCode.fromData(
        data: data,
        // Quartile on this stock: there is room for the redundancy at 36 mm,
        // and these ride on trolleys that get scuffed.
        errorCorrectLevel: QrErrorCorrectLevel.Q,
      ).moduleCount;
    } catch (_) {
      // Payload too long for Q at any version — the widget still renders at a
      // version the pdf package picks; the inset just falls back to nominal.
    }

    final span = modules + (_quietModules * 2);
    final insetMm = _qrBoxMm * (_quietModules / span);

    return pw.Container(
      width: _qrBoxMm * PdfPageFormat.mm,
      height: _qrBoxMm * PdfPageFormat.mm,
      color: _paper,
      padding: pw.EdgeInsets.all(insetMm * PdfPageFormat.mm),
      child: pw.BarcodeWidget(
        barcode: pw.Barcode.qrCode(
          errorCorrectLevel: pw.BarcodeQRCorrectionLevel.quartile,
        ),
        data: data,
        drawText: false,
        color: _ink,
        backgroundColor: _paper,
      ),
    );
  }

  /// Two-column detail grid, capped at six cells like the Maxion pallet label.
  static pw.Widget _grid(
    DplMasterSticker d, {
    required pw.Font bold,
    required pw.Font regular,
  }) {
    final df = DateFormat('dd MMM yyyy');
    final cells = <List<String>>[
      ['TRIP', d.tripNumber == 0 ? '-' : '#${d.tripNumber}'],
      ['DATE', d.tripDate == null ? '-' : df.format(d.tripDate!)],
      if (d.serialFrom.isNotEmpty) ['SERIAL FROM', d.serialFrom],
      if (d.serialTo.isNotEmpty) ['SERIAL TO', d.serialTo],
      if (d.machineName.isNotEmpty) ['LINE', d.machineName],
      if (d.shiftCode.isNotEmpty) ['SHIFT', d.shiftCode],
      if (d.vehicleNo.isNotEmpty) ['VEHICLE', d.vehicleNo],
      if (d.substratePartNo.isNotEmpty) ['SUBSTRATE', d.substratePartNo],
    ].take(6).toList();

    final rows = <pw.TableRow>[];
    for (var i = 0; i < cells.length; i += 2) {
      rows.add(
        pw.TableRow(
          children: [
            _cell(cells[i], bold: bold, regular: regular),
            i + 1 < cells.length
                ? _cell(cells[i + 1], bold: bold, regular: regular)
                : pw.SizedBox(),
          ],
        ),
      );
    }

    return pw.Container(
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: _ink, width: 1.125)),
      ),
      padding: const pw.EdgeInsets.only(top: 2 * PdfPageFormat.mm),
      margin: const pw.EdgeInsets.only(top: 2 * PdfPageFormat.mm),
      child: pw.Table(children: rows),
    );
  }

  static pw.Widget _cell(
    List<String> kv, {
    required pw.Font bold,
    required pw.Font regular,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 1.5 * PdfPageFormat.mm),
      child: pw.FittedBox(
        fit: pw.BoxFit.scaleDown,
        alignment: pw.Alignment.centerLeft,
        child: pw.RichText(
          maxLines: 1,
          text: pw.TextSpan(
            children: [
              pw.TextSpan(
                text: '${kv[0]}: ',
                style: pw.TextStyle(font: regular, fontSize: 8),
              ),
              pw.TextSpan(
                text: _clip(kv[1], 26),
                style: pw.TextStyle(font: bold, fontSize: 8),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Dashed rule, the raw payload in mono, and the piece count.
  static pw.Widget _foot(
    DplMasterSticker d, {
    required pw.Font bold,
    required pw.Font mono,
  }) {
    return pw.Container(
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: _ink, width: _hairline)),
      ),
      padding: const pw.EdgeInsets.only(top: 1 * PdfPageFormat.mm),
      margin: const pw.EdgeInsets.only(top: 2 * PdfPageFormat.mm),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Text(
              _clip(d.qrPayload, 52),
              maxLines: 1,
              style: pw.TextStyle(font: mono, fontSize: 6.5),
            ),
          ),
          pw.SizedBox(width: 2 * PdfPageFormat.mm),
          pw.Text(
            '${d.scannedQty} PCS',
            style: pw.TextStyle(font: bold, fontSize: 6.5),
          ),
        ],
      ),
    );
  }

  /// pdf 3.x has no TextOverflow.ellipsis, so long values are pre-truncated.
  static String _clip(String v, int max) {
    final s = v.trim();
    if (s.isEmpty) return '-';
    return s.length <= max ? s : '${s.substring(0, max - 1)}…';
  }
}
