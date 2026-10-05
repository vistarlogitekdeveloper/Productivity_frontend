import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../models/dpl_part.dart';
import '../../models/dpl_part_sticker.dart';

/// The long PDF417 barcode label — the Antolin/TML finished-part layout.
///
/// Re-authored from a photograph of the label already on Sanand JIT's parts.
/// Read the right way up, it is:
///
///   ┌──────────────────────────────────────────────┬──────────┐
///   │ NEXON PR HDL ASSY W BIG RLS C/O LLG,F         │ ANTOLIN  │
///   │ ▌▌║║ ▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒ ║║▌▌     │ INDIA    │
///   │ 546469500119ZY GA2600000147 05Oct26 A         │ 119ZY    │
///   └──────────────────────────────────────────────┴──────────┘
///
///   Stock        75 mm x 25 mm, one label per page — [rollFormat]
///   Padding      1.5 mm top/bottom, 2 mm left/right
///   Top line     part name (`part_name`), Helvetica 6.5 pt
///   Symbol       PDF417, security level 2, rows 3 modules tall
///   Bottom line  customer part no, serial, date, shift — Courier Bold 6 pt
///   Right block  ANTOLIN / INDIA, then the short part code (`description`)
///
/// THE SYMBOL HOLDS OUR PAYLOAD, NOT A NEW ONE. It encodes the sticker's
/// `qrPayload` (`GA|plant|part|serial|YYMMDD|shift|line`) exactly as the QR
/// sticker does, so every scan downstream — loading a trip, returns, stock
/// counts — resolves this label with no backend change. Only the artwork
/// differs between the two layouts.
///
/// The same two rules as [PartStickerLabelPdf] apply, for the same reasons:
/// pure black on white (thermal heads dither grey), and built-in fonts only
/// (no network fetch on a shop floor that may have no internet).
class Pdf417LabelPdf {
  const Pdf417LabelPdf._();

  // ── Physical constants, all in millimetres ──
  static const double labelWidthMm = 75;
  static const double labelHeightMm = 25;
  static const double _padVMm = 1.5;
  static const double _padHMm = 2;
  static const double _sideBlockMm = 16;
  static const double _gapMm = 2;
  static const double _symbolHeightMm = 13.5;

  /// Rows of a PDF417 symbol must be at least three modules tall to scan
  /// reliably; this is that minimum.
  static const double _rowHeightModules = 3;

  /// Width of the symbol's box. Everything left of the side block.
  static const double symbolWidthMm =
      labelWidthMm - (2 * _padHMm) - _sideBlockMm - _gapMm;

  static const double _hairline = 0.75;

  static const PdfColor _ink = PdfColor.fromInt(0xFF000000);
  static const PdfColor _paper = PdfColor.fromInt(0xFFFFFFFF);

  /// Printed in the side block, on two lines, as the photographed label has it.
  static const String brandLine1 = 'ANTOLIN';
  static const String brandLine2 = 'INDIA';

  /// The die-cut page box. Must equal the stock exactly, or the printer
  /// rescales the artwork and it drifts across the roll.
  static const PdfPageFormat rollFormat = PdfPageFormat(
    labelWidthMm * PdfPageFormat.mm,
    labelHeightMm * PdfPageFormat.mm,
    marginAll: 0,
  );

  /// The symbol for [data], sized to fill its box AND to decode.
  ///
  /// THE ROW COUNT MUST BE A MULTIPLE OF THREE. `package:barcode` (2.2.9)
  /// writes the cluster-0 left row indicator as `(rows - 3) ~/ 3` where
  /// ISO/IEC 15438 has `(rows - 1) ~/ 3`. The two agree only when rows is a
  /// multiple of 3; for any other count the indicators contradict each other
  /// and ZXing rejects the symbol with a checksum error. It also allows two
  /// rows, below the standard's minimum of three. A label that looks perfect
  /// and does not scan is the worst kind of misprint, so we never hand it a
  /// row count it gets wrong.
  ///
  /// The row count cannot be set directly, only steered through
  /// `preferredRatio`, so this tries ratios around the box's own aspect and
  /// keeps the closest one that lands on a safe row count. Filling the box
  /// keeps the narrowest bar as wide as the label allows, which is what a
  /// 203 dpi thermal head needs.
  static pw.Barcode symbologyFor(String data) {
    final key = _shapeOf(data);
    final cached = _ratioByShape[key];
    if (cached != null) return _pdf417(cached);

    final target = symbolWidthMm / _symbolHeightMm;
    double? best;
    var bestMiss = double.infinity;
    // Multiplicative steps from a quarter of the target to four times it.
    for (var i = -40; i <= 40; i++) {
      final ratio = target * math.pow(2, i / 20);
      final dims = _measure(_pdf417(ratio), data);
      if (dims == null || dims.rows < 3 || dims.rows % 3 != 0) continue;
      final miss = (math.log(dims.aspect / target)).abs();
      if (miss < bestMiss) {
        bestMiss = miss;
        best = ratio;
      }
    }
    // Nothing safe in range is not expected for any payload a label carries;
    // fall back to the box aspect rather than refuse to print.
    final chosen = best ?? target;
    _ratioByShape[key] = chosen;
    return _pdf417(chosen);
  }

  static pw.Barcode _pdf417(double ratio) => pw.Barcode.pdf417(
        securityLevel: pw.Pdf417SecurityLevel.level2,
        moduleHeight: _rowHeightModules,
        preferredRatio: ratio,
      );

  /// Rows and width-to-height ratio of the symbol [barcode] draws for [data].
  static ({int rows, double aspect})? _measure(pw.Barcode barcode, String data) {
    try {
      final bars = barcode
          .make(data, width: 1000, height: 1000)
          .whereType<pw.BarcodeBar>()
          .toList();
      if (bars.isEmpty) return null;
      var left = double.infinity, top = double.infinity;
      var right = 0.0, bottom = 0.0;
      final rowTops = <double>{};
      for (final b in bars) {
        rowTops.add(b.top);
        left = math.min(left, b.left);
        top = math.min(top, b.top);
        right = math.max(right, b.left + b.width);
        bottom = math.max(bottom, b.top + b.height);
      }
      return (rows: rowTops.length, aspect: (right - left) / (bottom - top));
    } catch (_) {
      return null;
    }
  }

  /// Payloads with the same shape encode to the same codeword count, and so
  /// to the same dimensions. Within a batch only the serial's digits change,
  /// so a 500-label run searches once instead of 500 times.
  static String _shapeOf(String data) => data
      .replaceAll(RegExp(r'[0-9]'), '0')
      .replaceAll(RegExp(r'[A-Z]'), 'A')
      .replaceAll(RegExp(r'[a-z]'), 'a');

  static final Map<String, double> _ratioByShape = <String, double>{};

  /// One page per sticker at the true die-cut size.
  static Future<Uint8List> buildRoll(
    List<DplPartSticker> stickers, {
    required DplPart part,
    DateTime? runAt,
  }) async =>
      buildRollDocument(stickers, part: part, runAt: runAt).save();

  /// The roll document before serialisation, so tests can count its pages.
  static pw.Document buildRollDocument(
    List<DplPartSticker> stickers, {
    required DplPart part,
    DateTime? runAt,
  }) {
    // One timestamp for a whole run, as on the QR sticker.
    final at = runAt ?? DateTime.now();
    final doc = pw.Document(
      title: 'Part Labels (PDF417)',
      author: 'Grupo Antolin India Private Limited',
    );
    final regular = pw.Font.helvetica();
    final bold = pw.Font.helveticaBold();
    final mono = pw.Font.courierBold();

    for (final sticker in stickers) {
      doc.addPage(
        pw.Page(
          pageFormat: rollFormat,
          margin: pw.EdgeInsets.zero,
          build: (_) => _label(
            sticker,
            part: part,
            runAt: at,
            regular: regular,
            bold: bold,
            mono: mono,
          ),
        ),
      );
    }
    return doc;
  }

  // ── Artwork ──

  static pw.Widget _label(
    DplPartSticker sticker, {
    required DplPart part,
    required DateTime runAt,
    required pw.Font regular,
    required pw.Font bold,
    required pw.Font mono,
  }) {
    return pw.Container(
      width: labelWidthMm * PdfPageFormat.mm,
      height: labelHeightMm * PdfPageFormat.mm,
      decoration: pw.BoxDecoration(
        color: _paper,
        border: pw.Border.all(color: _ink, width: _hairline),
      ),
      padding: const pw.EdgeInsets.symmetric(
        vertical: _padVMm * PdfPageFormat.mm,
        horizontal: _padHMm * PdfPageFormat.mm,
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.SizedBox(
            width: symbolWidthMm * PdfPageFormat.mm,
            child: pw.Column(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _oneLine(
                  partTitle(part),
                  pw.TextStyle(font: regular, fontSize: 6.5),
                ),
                pw.SizedBox(
                  width: symbolWidthMm * PdfPageFormat.mm,
                  height: _symbolHeightMm * PdfPageFormat.mm,
                  child: pw.BarcodeWidget(
                    barcode: symbologyFor(symbolData(sticker)),
                    data: symbolData(sticker),
                    drawText: false,
                    color: _ink,
                    backgroundColor: _paper,
                  ),
                ),
                _oneLine(
                  readableLine(sticker, part: part, runAt: runAt),
                  pw.TextStyle(font: mono, fontSize: 6),
                ),
              ],
            ),
          ),
          pw.SizedBox(width: _gapMm * PdfPageFormat.mm),
          pw.Expanded(
            child: pw.Column(
              mainAxisAlignment: pw.MainAxisAlignment.center,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _oneLine(brandLine1, pw.TextStyle(font: bold, fontSize: 8)),
                _oneLine(brandLine2, pw.TextStyle(font: bold, fontSize: 8)),
                pw.SizedBox(height: 1.2 * PdfPageFormat.mm),
                _oneLine(
                  shortCode(part, sticker),
                  pw.TextStyle(font: bold, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One line that shrinks rather than wraps or spills past the die-cut.
  ///
  /// The part master's strings vary in length between plants, and a line that
  /// overflows its column on a fixed-size label is a misprint rather than a
  /// layout glitch.
  static pw.Widget _oneLine(String text, pw.TextStyle style) => pw.FittedBox(
        fit: pw.BoxFit.scaleDown,
        alignment: pw.Alignment.centerLeft,
        child: pw.Text(text.isEmpty ? '-' : text, maxLines: 1, style: style),
      );

  /// What the symbol encodes: the sticker's payload, or the bare serial for a
  /// malformed row — which every scanner in the app also accepts.
  static String symbolData(DplPartSticker sticker) =>
      sticker.qrPayload.trim().isEmpty ? sticker.serialNo : sticker.qrPayload;

  /// The top line: the part's long name (`part_name`), e.g.
  /// `NEXON PR HDL ASSY W BIG RLS C/O LLG,F`.
  static String partTitle(DplPart part) {
    final name = part.name.trim();
    return name.isNotEmpty ? name : part.description.trim();
  }

  /// The big code in the side block, e.g. `119ZY` — the part master keeps it
  /// in `description`.
  static String shortCode(DplPart part, DplPartSticker sticker) {
    final code = part.description.trim();
    if (code.isNotEmpty) return code;
    final pn = sticker.customerPartNo.trim();
    // `546469500119ZY` -> `119ZY`: the short code is the customer part no's
    // tail on every seeded part.
    return pn.length > 5 ? pn.substring(pn.length - 5) : pn;
  }

  /// The readable line under the symbol, e.g.
  /// `546469500119ZY GA2600000147 05Oct26 A`.
  ///
  /// The customer part number first, as on the photographed label, then the
  /// serial. The serial is what an operator keys in when a label is too
  /// scuffed to scan, so it must always be printed in full.
  static String readableLine(
    DplPartSticker sticker, {
    required DplPart part,
    required DateTime runAt,
  }) {
    final pn = sticker.customerPartNo.trim().isNotEmpty
        ? sticker.customerPartNo.trim()
        : part.partNumber.trim();
    final at = sticker.printedAt ?? runAt;
    final shift = sticker.payloadShift == '-' ? '' : sticker.payloadShift;
    return [
      if (pn.isNotEmpty) pn,
      sticker.payloadSerial,
      _ddMMMyy(at),
      if (shift.isNotEmpty) shift,
    ].join(' ');
  }

  static const _months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _ddMMMyy(DateTime t) =>
      '${t.day.toString().padLeft(2, '0')}${_months[t.month - 1]}'
      '${(t.year % 100).toString().padLeft(2, '0')}';
}
