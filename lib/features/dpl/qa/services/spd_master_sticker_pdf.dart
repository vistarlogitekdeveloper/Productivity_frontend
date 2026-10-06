import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../models/dpl_spd.dart';

/// The SPD master sticker — the box label for one spare-parts pack.
///
/// Re-authored from the plant's own stickers, a four-row ruled table:
///
///   ┌──────────────────────┐
///   │    PNAF9311A00B0     │  'PNAF' + item code + 'A00B0'
///   │      SP26000411      │  the SPD pack number
///   │ ALLOY WHEEL FOR Z101 │  the item's SPD description (migration 198)
///   │    QTY - 01 NOS      │  one wheel per pack, always
///   └──────────────────────┘
///
/// Printed on the 100 x 75 mm stock the pallet label already uses, so the
/// plant needs no new roll. Optional, and one per pack: the 50 x 25 mm pack
/// label still goes on the wheel; this goes on its box.
///
/// Same rules as every label here: pure black on white (thermal heads dither
/// grey), built-in Helvetica only (no font fetched over a network the shop
/// floor may not have).
class SpdMasterStickerPdf {
  const SpdMasterStickerPdf._();

  static const double labelWidthMm = 100;
  static const double labelHeightMm = 75;
  static const double _padMm = 4;
  static const double _rule = 1.2;

  static const PdfColor _ink = PdfColor.fromInt(0xFF000000);
  static const PdfColor _paper = PdfColor.fromInt(0xFFFFFFFF);

  static const PdfPageFormat rollFormat = PdfPageFormat(
    labelWidthMm * PdfPageFormat.mm,
    labelHeightMm * PdfPageFormat.mm,
    marginAll: 0,
  );

  /// Line 1: `PNAF` + item code + `A00B0`, e.g. `PNAF9311A00B0`.
  ///
  /// A fixed pattern the plant confirmed from its own stickers, so it is
  /// built rather than stored. Spaces in an item code (the master has
  /// "9345 Silver") are dropped: they cannot appear in a part code.
  static String partCode(DplSpdPack pack) {
    final item = pack.customerPartNo.replaceAll(RegExp(r'\s+'), '').toUpperCase();
    return item.isEmpty ? '' : 'PNAF${item}A00B0';
  }

  /// Line 3: the SPD description, or the item description until a manager
  /// has filled it in — a sticker with a blank row is worse than one with
  /// Maxion's own wording on it.
  static String itemLine(DplSpdPack pack) {
    final spd = pack.spdDescription.trim();
    return spd.isNotEmpty ? spd : pack.partDescription.trim();
  }

  static const String qtyLine = 'QTY - 01 NOS';

  static Future<Uint8List> buildRoll(List<DplSpdPack> packs) async =>
      buildRollDocument(packs).save();

  static pw.Document buildRollDocument(List<DplSpdPack> packs) {
    final doc = pw.Document(title: 'SPD master stickers');
    final bold = pw.Font.helveticaBold();
    // An empty run still yields a valid one-page document; some print
    // pipelines reject a zero-page PDF outright.
    final list = packs.isEmpty ? <DplSpdPack>[const DplSpdPack()] : packs;
    for (final pack in list) {
      doc.addPage(
        pw.Page(
          pageFormat: rollFormat,
          margin: pw.EdgeInsets.zero,
          build: (_) => _sticker(pack, bold),
        ),
      );
    }
    return doc;
  }

  static pw.Widget _sticker(DplSpdPack pack, pw.Font bold) {
    final rows = <String>[
      partCode(pack),
      pack.packNo,
      itemLine(pack),
      qtyLine,
    ];
    final side = pw.BorderSide(color: _ink, width: _rule);

    return pw.Container(
      width: labelWidthMm * PdfPageFormat.mm,
      height: labelHeightMm * PdfPageFormat.mm,
      color: _paper,
      padding: const pw.EdgeInsets.all(_padMm * PdfPageFormat.mm),
      child: pw.Container(
        decoration: pw.BoxDecoration(border: pw.Border.fromBorderSide(side)),
        child: pw.Column(
          children: [
            for (var i = 0; i < rows.length; i++)
              pw.Expanded(
                child: pw.Container(
                  alignment: pw.Alignment.center,
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 2.5 * PdfPageFormat.mm,
                  ),
                  decoration: i == 0
                      ? null
                      : pw.BoxDecoration(border: pw.Border(top: side)),
                  // Shrinks a long description to fit one row rather than
                  // wrapping it over the rule below.
                  child: pw.FittedBox(
                    fit: pw.BoxFit.scaleDown,
                    child: pw.Text(
                      rows[i].isEmpty ? '-' : rows[i],
                      maxLines: 1,
                      style: pw.TextStyle(font: bold, fontSize: 17, color: _ink),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
