import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:productivity_tracker/features/dpl/core/dpl_permissions_provider.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_part.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_part_sticker.dart';
import 'package:productivity_tracker/features/dpl/qa/services/part_sticker_label_pdf.dart';
import 'package:productivity_tracker/features/dpl/qa/services/pdf417_label_pdf.dart';
import 'package:productivity_tracker/features/dpl/qa/services/sticker_label_format.dart';

/// The Sanand JIT PDF417 label (backend migration 195). Like the QR sticker
/// test, these run the real document builder: a layout error in the pdf
/// package only shows up when `save()` runs, and `flutter analyze` cannot see
/// whether a barcode fits its die-cut.
const _payload = 'GA|GA|546469500119ZY|GA2600000147|261005|A|Nexon PR';

DplPartSticker _sticker({
  int id = 1,
  String serial = 'GA2600000147',
  String payload = _payload,
}) {
  return DplPartSticker(
    id: id,
    planId: 10,
    planItemId: 20,
    partId: 30,
    serialNo: serial,
    qrPayload: payload,
    substratePartNo: '195886530-083',
    customerPartNo: '546469500119ZY',
    shiftCode: 'A',
    machineName: 'Nexon PR',
    seqInBatch: 1,
    printedAt: DateTime(2026, 10, 5, 9, 30),
  );
}

// The part master as migration 020 seeds it: `description` holds the short
// code and `part_name` the long text.
const _part = DplPart(
  id: 30,
  partNumber: '546469500119ZY',
  description: '119ZY',
  name: 'NEXON PR HDL ASSY W BIG RLS C/O LLG,F',
);

class _Perms extends DplPermissionsController {
  _Perms(this.keys);
  final List<String> keys;

  @override
  DplPermissions build() => DplPermissions.of(keys);
}

ProviderContainer _container(List<String> keys) {
  final c = ProviderContainer(
    overrides: [dplPermissionsProvider.overrideWith(() => _Perms(keys))],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('artwork', () {
    test('roll page format is exactly the 75 x 25 mm die-cut', () {
      expect(Pdf417LabelPdf.rollFormat.width, closeTo(75 * PdfPageFormat.mm, 0.001));
      expect(Pdf417LabelPdf.rollFormat.height, closeTo(25 * PdfPageFormat.mm, 0.001));
      expect(Pdf417LabelPdf.rollFormat.marginLeft, 0);
      expect(Pdf417LabelPdf.rollFormat.marginTop, 0);
    });

    test('builds a roll document without throwing', () async {
      final bytes = await Pdf417LabelPdf.buildRoll([_sticker()], part: _part);
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });

    test('emits one page per sticker', () {
      final stickers = [
        for (var i = 1; i <= 5; i++)
          _sticker(
            id: i,
            serial: 'GA260000015$i',
            payload: 'GA|GA|546469500119ZY|GA260000015$i|261005|A|Nexon PR',
          ),
      ];
      final doc = Pdf417LabelPdf.buildRollDocument(stickers, part: _part);
      expect(doc.document.pdfPageList.pages.length, 5);
    });

    test('survives a part master with missing or very long strings', () async {
      // FittedBox keeps every line inside the die-cut; this proves the
      // layout does not throw when a plant's master is not shaped like ours.
      const odd = DplPart(
        id: 31,
        partNumber: '',
        description: '',
        name: 'A VERY LONG PART NAME THAT IS FAR WIDER THAN THE LABEL COULD EVER HOLD ON ONE LINE',
      );
      final bytes = await Pdf417LabelPdf.buildRoll([_sticker()], part: odd);
      expect(bytes.lengthInBytes, greaterThan(500));
    });

    test('the text matches the photographed label', () {
      expect(Pdf417LabelPdf.partTitle(_part), 'NEXON PR HDL ASSY W BIG RLS C/O LLG,F');
      expect(Pdf417LabelPdf.shortCode(_part, _sticker()), '119ZY');
      expect(
        Pdf417LabelPdf.readableLine(_sticker(), part: _part, runAt: DateTime(2026)),
        '546469500119ZY GA2600000147 05Oct26 A',
      );
    });

    test('the short code falls back to the customer part number tail', () {
      const bare = DplPart(id: 1, partNumber: '546469500119ZY', description: '');
      expect(Pdf417LabelPdf.shortCode(bare, _sticker()), '119ZY');
    });
  });

  group('symbol', () {
    // Every bar the symbology draws for our payload at the label's box size.
    List<pw.BarcodeBar> bars([String payload = _payload]) =>
        Pdf417LabelPdf.symbologyFor(payload)
        .make(
          payload,
          width: Pdf417LabelPdf.symbolWidthMm * PdfPageFormat.mm,
          height: 13.5 * PdfPageFormat.mm,
        )
        .whereType<pw.BarcodeBar>()
        .toList();

    test('encodes without throwing for a real payload', () {
      expect(bars(), isNotEmpty);
    });

    test('always lands on a row count that decodes (multiple of 3, at least 3)', () {
      // package:barcode 2.2.9 writes a wrong cluster-0 left row indicator
      // unless rows % 3 == 0, and allows a two-row symbol the standard
      // forbids. Both scan as checksum failures. Checked by decoding with
      // ZXing when this was written; this pins the property that made those
      // symbols decode.
      const payloads = [
        _payload,
        'GA|GA|546469500102ZX|GA2612345678|261231|C|X0 HL SR-2',
        'GA|GA|546469500205AX|GA2600000001|260101|-|-',
        'GA|GA|18663|GA2600009999|260929|B|std01',
        'GA2600000147',
        'GA|GA|A VERY LONG CUSTOMER PART REFERENCE 1234567890|GA2699999999|261005|A|Machine with a long name',
      ];
      for (final p in payloads) {
        final rows = bars(p).map((b) => b.top).toSet().length;
        expect(rows, greaterThanOrEqualTo(3), reason: p);
        expect(rows % 3, 0, reason: '$p -> $rows rows');
      }
    });

    test('the narrowest bar is wide enough for a 203 dpi thermal head', () {
      // Two printer dots at 203 dpi is 0.25 mm. Below that the head cannot
      // render a module reliably and read rate falls apart.
      final narrowest = bars()
          .where((b) => b.black)
          .map((b) => b.width)
          .reduce((a, b) => a < b ? a : b);
      expect(narrowest / PdfPageFormat.mm, greaterThanOrEqualTo(0.25));
    });

    test('fills most of its box rather than shrinking to one side', () {
      // The column count is chosen from the box's own aspect ratio. If that
      // ever regresses, the symbol shrinks and the modules with it.
      final all = bars();
      final left = all.map((b) => b.left).reduce((a, b) => a < b ? a : b);
      final right =
          all.map((b) => b.left + b.width).reduce((a, b) => a > b ? a : b);
      final top = all.map((b) => b.top).reduce((a, b) => a < b ? a : b);
      final bottom =
          all.map((b) => b.top + b.height).reduce((a, b) => a > b ? a : b);
      final boxW = Pdf417LabelPdf.symbolWidthMm * PdfPageFormat.mm;
      final boxH = 13.5 * PdfPageFormat.mm;
      // Width-limited or height-limited, one side is always full; the other
      // must not be left mostly empty. Not 1.0: the row count is held to a
      // multiple of three (see symbologyFor), which costs a little fill.
      expect((right - left) / boxW, greaterThan(0.6));
      expect((bottom - top) / boxH, greaterThan(0.6));
    });
  });

  group('format choice', () {
    test('each format prints on its own stock', () {
      expect(StickerLabelFormat.qr.rollFormat, PartStickerLabelPdf.rollFormat);
      expect(StickerLabelFormat.pdf417.rollFormat, Pdf417LabelPdf.rollFormat);
    });

    test('without labels.print_pdf417 the QR sticker always prints', () {
      final c = _container(const ['labels.print']);
      // Even if the operator chose PDF417 earlier in the session.
      c.read(stickerLabelFormatChoiceProvider.notifier).select(StickerLabelFormat.pdf417);
      expect(c.read(effectiveStickerLabelFormatProvider), StickerLabelFormat.qr);
    });

    test('with it, the operator choice prints, defaulting to the QR sticker', () {
      final c = _container(const ['labels.print', 'labels.print_pdf417']);
      expect(c.read(effectiveStickerLabelFormatProvider), StickerLabelFormat.qr);
      c.read(stickerLabelFormatChoiceProvider.notifier).select(StickerLabelFormat.pdf417);
      expect(c.read(effectiveStickerLabelFormatProvider), StickerLabelFormat.pdf417);
    });

    test('is opt-in: an unknown permission list never offers it', () {
      // A backend without migration 195, or a failed /auth/me, must not put
      // the barcode layout on every plant's print screen.
      expect(DplPermission.labelsPrintPdf417, 'labels.print_pdf417');
      expect(DplPermission.optInOnly, contains(DplPermission.labelsPrintPdf417));
      expect(const DplPermissions.unknown().can(DplPermission.labelsPrintPdf417), isFalse);
    });
  });
}
