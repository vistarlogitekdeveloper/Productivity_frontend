import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
// qr_flutter re-exports package:qr, so QrCode/QrErrorCorrectLevel are reachable
// without adding a dependency. We need them only to count modules so the quiet
// zone can be sized correctly — the symbol itself is drawn by the pdf package.
import 'package:qr_flutter/qr_flutter.dart' show QrCode, QrErrorCorrectLevel;

import '../../models/dpl_part_sticker.dart';

/// The finished-goods sticker QA prints onto a produced part.
///
/// This is a deliberate, faithful re-authoring of the Maxion Wheels "scanning"
/// label so both plants run the same physical stock and the same artwork. That
/// label is HTML+CSS behind a platform bridge in the Maxion app; none of that
/// code is reusable here (Productivity prints through `pdf` + `printing`, which
/// works on Android/iOS/web where Maxion's native path is only a stub), so what
/// ports across is the geometry and typography, measured in millimetres:
///
///   Stock        Avery Chromo 50 mm x 25 mm, 1UP, 1.5" core, 2000/roll
///   Page box     exactly the die-cut, zero margin — a mismatch makes the
///                printer rescale and drift across the roll
///   Cut rule     1 px (0.75 pt) solid black, INSIDE the box (border-box)
///   Padding      1.5 mm top/bottom, 2 mm left/right
///   Layout       horizontal row, 2 mm gap, centred
///   QR           21 mm square, ECC M, 2-module quiet zone per side
///   Text column  21 mm tall, rows distributed space-around
///     row 1      customer part ref (11 pt bold) + shift letter in a 1 px box
///     row 2      serial, monospace 10.5 pt bold
///     row 3      LINE {line} - {i}/{n}, 7 pt bold
///
/// Two rules are load-bearing rather than cosmetic:
///
///   * Pure #000 on pure #FFF, no greys, no fills, no rounded badges. Thermal
///     heads halftone-dither grey, which destroys read rate on a 21 mm symbol.
///   * Built-in Helvetica/Courier, never `PdfGoogleFonts`. Those fetch from a
///     CDN at build time; a shop floor with no internet would silently get
///     different metrics on a label where the monospace serial row is sized to
///     the millimetre.
///
/// Maxion's own note is worth repeating: a thermal media size in the page box
/// is silently ignored when the printer has A4 loaded, "which is how 96 labels
/// became 96 sheets". Hence [buildRoll] (one page per sticker, die-cut sized)
/// and [buildSheet] (A4 tiled) as separate, explicit choices.
class PartStickerLabelPdf {
  const PartStickerLabelPdf._();

  // ── Physical constants, all in millimetres ──
  static const double labelWidthMm = 50;
  static const double labelHeightMm = 25;
  static const double _padVMm = 1.5;
  static const double _padHMm = 2;
  static const double _gapMm = 2;
  static const double _qrBoxMm = 21;

  /// Quiet zone per side, in QR modules. Maxion's generator documents 4 but
  /// its parameter default — and therefore everything it has ever printed — is
  /// 2. Match what actually prints.
  static const int _quietModules = 2;

  /// CSS `1px` = 0.75 pt. The cut/registration rule.
  static const double _hairline = 0.75;

  static const PdfColor _ink = PdfColor.fromInt(0xFF000000);
  static const PdfColor _paper = PdfColor.fromInt(0xFFFFFFFF);

  /// The die-cut page box. Must equal the stock exactly.
  static const PdfPageFormat rollFormat = PdfPageFormat(
    labelWidthMm * PdfPageFormat.mm,
    labelHeightMm * PdfPageFormat.mm,
    marginAll: 0,
  );

  /// One page per sticker at the true die-cut size — for the thermal roll.
  static Future<Uint8List> buildRoll(List<DplPartSticker> stickers) async =>
      buildRollDocument(stickers).save();

  /// The roll document itself, before serialisation.
  ///
  /// Separate from [buildRoll] so the page structure can be asserted directly.
  /// Counting pages in the saved bytes is not possible — the output is
  /// compressed, so `/Type /Page` never appears as plain text.
  static pw.Document buildRollDocument(List<DplPartSticker> stickers) {
    final doc = pw.Document(
      title: 'Part Stickers',
      author: 'Grupo Antolin India Private Limited',
    );
    final fonts = _LabelFonts.builtIn();

    // One pw.Page per sticker rather than pw.MultiPage: the label is a single
    // bordered container and cannot be split, which is what makes MultiPage
    // throw TooManyPagesException elsewhere in this codebase.
    for (var i = 0; i < stickers.length; i++) {
      doc.addPage(
        pw.Page(
          pageFormat: rollFormat,
          margin: pw.EdgeInsets.zero,
          build: (_) => _label(
            stickers[i],
            index: i + 1,
            total: stickers.length,
            fonts: fonts,
          ),
        ),
      );
    }
    return doc;
  }

  /// A4-tiled for an office laser printer, so a test run does not burn a roll.
  ///
  /// 5 across x 7 down at 3 mm gutters inside an 8 mm margin — the same fit
  /// Maxion computes for this stock on A4 landscape.
  static Future<Uint8List> buildSheet(List<DplPartSticker> stickers) async =>
      buildSheetDocument(stickers).save();

  /// The A4 document itself, before serialisation. See [buildRollDocument].
  static pw.Document buildSheetDocument(List<DplPartSticker> stickers) {
    final doc = pw.Document(
      title: 'Part Stickers',
      author: 'Grupo Antolin India Private Limited',
    );
    final fonts = _LabelFonts.builtIn();
    const perPage = 35;

    for (var start = 0; start < stickers.length; start += perPage) {
      final slice = stickers.sublist(
        start,
        (start + perPage).clamp(0, stickers.length),
      );
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4.landscape,
          orientation: pw.PageOrientation.landscape,
          margin: const pw.EdgeInsets.all(8 * PdfPageFormat.mm),
          build: (_) => pw.Wrap(
            spacing: 3 * PdfPageFormat.mm,
            runSpacing: 3 * PdfPageFormat.mm,
            children: [
              for (var i = 0; i < slice.length; i++)
                pw.SizedBox(
                  width: labelWidthMm * PdfPageFormat.mm,
                  height: labelHeightMm * PdfPageFormat.mm,
                  child: _label(
                    slice[i],
                    index: start + i + 1,
                    total: stickers.length,
                    fonts: fonts,
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return doc;
  }

  // ── Artwork ──

  static pw.Widget _label(
    DplPartSticker sticker, {
    required int index,
    required int total,
    required _LabelFonts fonts,
  }) {
    final code = sticker.customerPartNo.trim().isNotEmpty
        ? sticker.customerPartNo.trim()
        : sticker.substratePartNo.trim();

    return pw.Container(
      width: labelWidthMm * PdfPageFormat.mm,
      height: labelHeightMm * PdfPageFormat.mm,
      decoration: pw.BoxDecoration(
        color: _paper,
        // box-sizing: border-box — the rule sits inside the die-cut.
        border: pw.Border.all(color: _ink, width: _hairline),
      ),
      padding: const pw.EdgeInsets.symmetric(
        vertical: _padVMm * PdfPageFormat.mm,
        horizontal: _padHMm * PdfPageFormat.mm,
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          _qr(sticker.qrPayload),
          pw.SizedBox(width: _gapMm * PdfPageFormat.mm),
          // Expanded gives the text column a bounded width so nothing can
          // overflow the die-cut; the explicit height is what lets
          // spaceAround distribute the three rows instead of collapsing them.
          pw.Expanded(
            child: pw.SizedBox(
              height: _qrBoxMm * PdfPageFormat.mm,
              child: pw.Column(
                mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  _rowTop(code, sticker.payloadShift, fonts),
                  _rowSerial(sticker.payloadSerial, fonts),
                  _rowMeta(sticker.payloadLine, index, total, fonts),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The symbol, with an explicit quiet zone.
  ///
  /// `pw.BarcodeWidget` paints the matrix edge to edge — `BarcodeQR.convert`
  /// builds it with no quiet zone at all. Dropped straight into a 21 mm box
  /// against the label padding and the cut rule, the finder patterns end up
  /// with almost no margin and scanners fail to lock on. So the symbol is
  /// inset by exactly the 2 modules per side Maxion prints, computed from the
  /// real module count for this payload at ECC M.
  static pw.Widget _qr(String payload) {
    final data = payload.trim().isEmpty ? ' ' : payload;

    var modules = 33; // sane fallback ≈ version 4
    try {
      modules = QrCode.fromData(
        data: data,
        errorCorrectLevel: QrErrorCorrectLevel.M,
      ).moduleCount;
    } catch (_) {
      // A payload too long for ECC M at any version. The barcode widget below
      // still renders (the pdf package picks its own version), and the inset
      // simply falls back to the nominal figure rather than failing the print.
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
          // pw.Barcode.qrCode() defaults to LOW. Maxion prints this stock at
          // M — enough redundancy for a scuffed thermal label without pushing
          // the module count up and the module size below the printer's dot
          // pitch.
          errorCorrectLevel: pw.BarcodeQRCorrectionLevel.medium,
        ),
        data: data,
        drawText: false,
        color: _ink,
        backgroundColor: _paper,
      ),
    );
  }

  /// Customer part reference + shift letter.
  ///
  /// The part ref gets the flexible width and the chip is sized to content:
  /// Maxion records that without this the chip won the squeeze and a 5-digit
  /// item code ellipsised to "18...".
  static pw.Widget _rowTop(String code, String shift, _LabelFonts fonts) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Expanded(
          child: pw.FittedBox(
            fit: pw.BoxFit.scaleDown,
            alignment: pw.Alignment.centerLeft,
            child: pw.Text(
              code.isEmpty ? '-' : code,
              maxLines: 1,
              style: pw.TextStyle(
                font: fonts.bold,
                fontSize: 11,
                letterSpacing: -0.15, // CSS -0.2px
              ),
            ),
          ),
        ),
        pw.SizedBox(width: 1 * PdfPageFormat.mm),
        // Square 1 px outline holding ONLY the letter. Spelling out "SHIFT A"
        // costs ~10 mm of a 22 mm column, which is why Maxion abbreviates it.
        pw.Container(
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: _ink, width: _hairline),
          ),
          padding: const pw.EdgeInsets.symmetric(
            vertical: 0.6 * PdfPageFormat.mm,
            horizontal: 1 * PdfPageFormat.mm,
          ),
          child: pw.Text(
            _shiftLetter(shift),
            maxLines: 1,
            style: pw.TextStyle(font: fonts.bold, fontSize: 8),
          ),
        ),
      ],
    );
  }

  static pw.Widget _rowSerial(String serial, _LabelFonts fonts) {
    return pw.FittedBox(
      fit: pw.BoxFit.scaleDown,
      alignment: pw.Alignment.centerLeft,
      child: pw.Text(
        serial.isEmpty ? '-' : serial,
        maxLines: 1,
        style: pw.TextStyle(
          font: fonts.mono,
          fontSize: 10.5,
          letterSpacing: 0.15, // CSS 0.2px
        ),
      ),
    );
  }

  static pw.Widget _rowMeta(
    String line,
    int index,
    int total,
    _LabelFonts fonts,
  ) {
    // Maxion uses U+2022 here. Helvetica's WinAnsi encoding carries it, but a
    // hyphen is the zero-risk choice on a 7 pt row and reads the same at arm's
    // length on a thermal print.
    final text = 'LINE ${_short(line, 12)} - $index/$total';
    return pw.FittedBox(
      fit: pw.BoxFit.scaleDown,
      alignment: pw.Alignment.centerLeft,
      child: pw.Text(
        text,
        maxLines: 1,
        style: pw.TextStyle(font: fonts.bold, fontSize: 7),
      ),
    );
  }

  /// Shift codes are single letters in the master ("A"/"B"/"C"), but tolerate
  /// "Shift A" or an empty value without printing something silly.
  static String _shiftLetter(String shift) {
    final s = shift.trim();
    if (s.isEmpty || s == '-') return '-';
    final letters = RegExp(r'[A-Za-z0-9]').allMatches(s).map((m) => m[0]!).toList();
    if (letters.isEmpty) return '-';
    return letters.last.toUpperCase();
  }

  static String _short(String v, int max) {
    final s = v.trim();
    if (s.isEmpty) return '-';
    return s.length <= max ? s : s.substring(0, max);
  }
}

/// Built-in Type1 fonts only — no network fetch, so the label prints
/// identically on a shop floor with no internet.
class _LabelFonts {
  final pw.Font bold;
  final pw.Font mono;

  const _LabelFonts({required this.bold, required this.mono});

  factory _LabelFonts.builtIn() => _LabelFonts(
        // CSS asks for Arial at weight 900; Arial ships no Black on most
        // systems, so a browser renders Arial Bold. Helvetica Bold is
        // metric-compatible with Arial Bold and visually faithful.
        bold: pw.Font.helveticaBold(),
        mono: pw.Font.courierBold(),
      );
}
