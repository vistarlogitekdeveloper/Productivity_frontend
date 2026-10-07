import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../models/dpl_spd.dart';

/// The SPD master sticker — the box label for one SPD conversion.
///
/// One conversion takes several wheels off a pallet and makes a pack of each.
/// The packs leave together, so the master sticker covers all of them, the way
/// a pallet sticker covers the wheels on a pallet:
///
///   ┌─────────────────────────────────────┐
///   │           PNAF19255A00B0            │  'PNAF' + item code + 'A00B0'
///   │ Al Finish Wheel 9255 Piano Black... │  the item's SPD description
///   │ QTY - 04 NOS              SPD BOX   │  every pack of the conversion
///   ├─────────────────────────────────────┤
///   │ SP26000023 GA2600000067 │ SP2600... │  each pack and the wheel in it
///   │ SP26000024 GA2600000068 │ ...       │
///   └─────────────────────────────────────┘
///
/// Packs are grouped by their batch (backend migration 199: the first pack
/// number of the conversion). A batch bigger than one sticker holds runs on
/// to a second one, each counting only what it lists, and numbered 1/2, 2/2.
///
/// Printed on the 100 x 75 mm stock the pallet label already uses, so the
/// plant needs no new roll. Same rules as every label here: pure black on
/// white (thermal heads dither grey), built-in Helvetica only (no font fetched
/// over a network the shop floor may not have).
class SpdMasterStickerPdf {
  const SpdMasterStickerPdf._();

  static const double labelWidthMm = 100;
  static const double labelHeightMm = 75;
  static const double _padMm = 4;
  static const double _rule = 1.2;
  static const double _rowMm = 4.6;

  /// Two columns of six. At 9 pt a pack number and its serial still read
  /// across a bay; more rows than this and they would not.
  static const int rowsPerColumn = 6;
  static const int perSticker = rowsPerColumn * 2;

  static const PdfColor _ink = PdfColor.fromInt(0xFF000000);
  static const PdfColor _paper = PdfColor.fromInt(0xFFFFFFFF);

  static const PdfPageFormat rollFormat = PdfPageFormat(
    labelWidthMm * PdfPageFormat.mm,
    labelHeightMm * PdfPageFormat.mm,
    marginAll: 0,
  );

  /// `PNAF` + item code + `A00B0`, e.g. `PNAF9311A00B0`.
  ///
  /// A fixed pattern the plant confirmed from its own stickers, so it is
  /// built rather than stored. Spaces in an item code (the master has
  /// "9345 Silver") are dropped: they cannot appear in a part code.
  static String partCode(DplSpdPack pack) {
    final item = pack.customerPartNo.replaceAll(RegExp(r'\s+'), '').toUpperCase();
    return item.isEmpty ? '' : 'PNAF${item}A00B0';
  }

  /// The SPD description, or the item description until a manager has filled
  /// it in — a sticker with a blank row is worse than one with Maxion's own
  /// wording on it.
  static String itemLine(DplSpdPack pack) {
    final spd = pack.spdDescription.trim();
    return spd.isNotEmpty ? spd : pack.partDescription.trim();
  }

  /// One pack is one wheel.
  static const String qtyLine = 'QTY - 01 NOS';

  /// `QTY - 04 NOS` — the plant's own wording, two digits.
  static String qtyFor(int n) => 'QTY - ${n.toString().padLeft(2, '0')} NOS';

  /// The stickers a set of packs prints as: one per batch (and per item, so a
  /// mixed reprint can never put two items under one part code), split into
  /// [perSticker]-pack sheets. Packs keep their number order.
  static List<List<DplSpdPack>> sheets(List<DplSpdPack> packs) {
    final groups = <String, List<DplSpdPack>>{};
    for (final p in packs) {
      groups.putIfAbsent(_key(p), () => []).add(p);
    }
    final out = <List<DplSpdPack>>[];
    for (final g in groups.values) {
      g.sort((a, b) => a.packNo.compareTo(b.packNo));
      for (var i = 0; i < g.length; i += perSticker) {
        final end = i + perSticker < g.length ? i + perSticker : g.length;
        out.add(g.sublist(i, end));
      }
    }
    return out;
  }

  static String _key(DplSpdPack p) =>
      '${p.batchNo.isNotEmpty ? p.batchNo : p.packNo}|${p.customerPartNo}';

  static Future<Uint8List> buildRoll(List<DplSpdPack> packs) async =>
      buildRollDocument(packs).save();

  static pw.Document buildRollDocument(List<DplSpdPack> packs) {
    final doc = pw.Document(title: 'SPD master stickers');
    final bold = pw.Font.helveticaBold();
    final regular = pw.Font.helvetica();
    // An empty run still yields a valid one-page document; some print
    // pipelines reject a zero-page PDF outright.
    final list = sheets(packs);
    if (list.isEmpty) list.add(const [DplSpdPack()]);

    // "1/2" only within a batch that ran over one sticker.
    final perBatch = <String, int>{};
    for (final s in list) {
      perBatch.update(_key(s.first), (n) => n + 1, ifAbsent: () => 1);
    }
    final seen = <String, int>{};
    for (final sheet in list) {
      final key = _key(sheet.first);
      final n = seen.update(key, (v) => v + 1, ifAbsent: () => 1);
      final total = perBatch[key] ?? 1;
      doc.addPage(
        pw.Page(
          pageFormat: rollFormat,
          margin: pw.EdgeInsets.zero,
          build: (_) => _sticker(
            sheet,
            bold,
            regular,
            part: total > 1 ? '$n/$total' : '',
          ),
        ),
      );
    }
    return doc;
  }

  static pw.Widget _sticker(
    List<DplSpdPack> packs,
    pw.Font bold,
    pw.Font regular, {
    String part = '',
  }) {
    final first = packs.first;
    final side = pw.BorderSide(color: _ink, width: _rule);
    final thin = pw.BorderSide(color: _ink, width: 0.6);

    pw.Widget band(double heightMm, pw.Widget child, {bool ruled = true}) =>
        pw.Container(
          height: heightMm * PdfPageFormat.mm,
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.symmetric(horizontal: 2.5 * PdfPageFormat.mm),
          decoration: ruled ? pw.BoxDecoration(border: pw.Border(top: side)) : null,
          child: child,
        );

    final left = packs.take(rowsPerColumn).toList();
    final right = packs.skip(rowsPerColumn).toList();

    return pw.Container(
      width: labelWidthMm * PdfPageFormat.mm,
      height: labelHeightMm * PdfPageFormat.mm,
      color: _paper,
      padding: const pw.EdgeInsets.all(_padMm * PdfPageFormat.mm),
      child: pw.Container(
        decoration: pw.BoxDecoration(border: pw.Border.fromBorderSide(side)),
        child: pw.Column(
          children: [
            band(12, _line(partCode(first), bold, 18), ruled: false),
            band(9, _line(itemLine(first), bold, 12)),
            band(
              9,
              pw.Row(
                children: [
                  pw.Expanded(
                    child: _line(qtyFor(packs.length), bold, 15, left: true),
                  ),
                  pw.Text(
                    part.isEmpty ? 'SPD BOX' : 'SPD BOX $part',
                    style: pw.TextStyle(font: bold, fontSize: 9, color: _ink),
                  ),
                ],
              ),
            ),
            // Every pack in the box, and the wheel in it.
            pw.Expanded(
              child: pw.Container(
                decoration: pw.BoxDecoration(border: pw.Border(top: side)),
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 2 * PdfPageFormat.mm,
                  vertical: 1.2 * PdfPageFormat.mm,
                ),
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Expanded(child: _column(left, bold, regular)),
                    if (right.isNotEmpty) ...[
                      pw.Container(
                        width: 0,
                        height: rowsPerColumn * _rowMm * PdfPageFormat.mm,
                        margin: const pw.EdgeInsets.symmetric(
                          horizontal: 1.5 * PdfPageFormat.mm,
                        ),
                        decoration: pw.BoxDecoration(border: pw.Border(left: thin)),
                      ),
                      pw.Expanded(child: _column(right, bold, regular)),
                    ] else
                      pw.Expanded(child: pw.SizedBox()),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static pw.Widget _column(List<DplSpdPack> packs, pw.Font bold, pw.Font regular) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        for (final p in packs)
          pw.Container(
            height: _rowMm * PdfPageFormat.mm,
            alignment: pw.Alignment.centerLeft,
            child: pw.FittedBox(
              fit: pw.BoxFit.scaleDown,
              alignment: pw.Alignment.centerLeft,
              child: pw.Row(
                mainAxisSize: pw.MainAxisSize.min,
                children: [
                  pw.Text(
                    p.packNo.isEmpty ? '-' : p.packNo,
                    style: pw.TextStyle(font: bold, fontSize: 9.5, color: _ink),
                  ),
                  if (p.serialNo.isNotEmpty) ...[
                    pw.SizedBox(width: 2 * PdfPageFormat.mm),
                    pw.Text(
                      p.serialNo,
                      style: pw.TextStyle(font: regular, fontSize: 9, color: _ink),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// One line, shrunk to fit rather than wrapped over the rule below. Never
  /// empty: pdf's FittedBox asserts on a zero-width child.
  static pw.Widget _line(String text, pw.Font font, double size, {bool left = false}) {
    return pw.FittedBox(
      fit: pw.BoxFit.scaleDown,
      alignment: left ? pw.Alignment.centerLeft : pw.Alignment.center,
      child: pw.Text(
        text.trim().isEmpty ? '-' : text,
        maxLines: 1,
        style: pw.TextStyle(font: font, fontSize: size, color: _ink),
      ),
    );
  }
}
