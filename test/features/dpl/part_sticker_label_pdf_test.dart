import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_part_sticker.dart';
import 'package:productivity_tracker/features/dpl/qa/services/part_sticker_label_pdf.dart';

/// The label is a physical artefact: 50 mm x 25 mm of thermal stock with a
/// 21 mm QR on it. `flutter analyze` proves it compiles and says nothing about
/// whether it renders — and a pdf-package layout error (an unbounded flex, a
/// barcode that cannot measure itself) only surfaces when `save()` runs.
///
/// These tests run the real document builder. They are deliberately about the
/// things that would put wrong labels on real parts: the page really is the
/// die-cut size, one page really is emitted per sticker, and the payload
/// fields the artwork reads positionally really do fall where expected.
DplPartSticker _sticker({
  int id = 1,
  String serial = 'GA2600000147',
  String payload = 'GA|GA|546469500102ZX|GA2600000147|260919|A|Nexon SR',
  String customerPartNo = '546469500102ZX',
}) {
  return DplPartSticker(
    id: id,
    planId: 10,
    planItemId: 20,
    partId: 30,
    serialNo: serial,
    qrPayload: payload,
    substratePartNo: '195245450-083',
    customerPartNo: customerPartNo,
    shiftCode: 'A',
    machineName: 'Nexon SR',
    batchId: '1b1f0e2a-0000-4000-8000-000000000000',
    seqInBatch: 1,
  );
}

void main() {
  test('roll page format is exactly the 50 x 25 mm die-cut', () {
    // If the page box does not equal the stock, the printer rescales the
    // artwork and it drifts across the roll.
    expect(
      PartStickerLabelPdf.rollFormat.width,
      closeTo(50 * PdfPageFormat.mm, 0.001),
    );
    expect(
      PartStickerLabelPdf.rollFormat.height,
      closeTo(25 * PdfPageFormat.mm, 0.001),
    );
    expect(PartStickerLabelPdf.rollFormat.marginLeft, 0);
    expect(PartStickerLabelPdf.rollFormat.marginTop, 0);
  });

  test('builds a roll document without throwing', () async {
    final bytes = await PartStickerLabelPdf.buildRoll([_sticker()]);
    expect(bytes.lengthInBytes, greaterThan(500));
    // Every PDF starts with %PDF.
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });

  test('emits one page per sticker on the roll', () async {
    final stickers = [
      for (var i = 1; i <= 6; i++)
        _sticker(
          id: i,
          serial: 'GA260000015$i',
          payload: 'GA|GA|546469500102ZX|GA260000015$i|260919|A|Nexon SR',
        ),
    ];
    // Six labels on a roll must be six pages — one label per page, the
    // equivalent of Maxion's `page-break-after: always`.
    final doc = PartStickerLabelPdf.buildRollDocument(stickers);
    expect(doc.document.pdfPageList.pages.length, 6);
  });

  test('A4 sheet mode tiles many stickers onto few pages', () async {
    final stickers = [
      for (var i = 1; i <= 40; i++)
        _sticker(
          id: i,
          serial: 'GA26000002${i.toString().padLeft(2, '0')}',
          payload:
              'GA|GA|546469500102ZX|GA26000002${i.toString().padLeft(2, '0')}|260919|A|Nexon SR',
        ),
    ];
    // 35 per A4 sheet, so 40 stickers is 2 pages — not 40.
    final doc = PartStickerLabelPdf.buildSheetDocument(stickers);
    expect(doc.document.pdfPageList.pages.length, 2);

    // And it still serialises.
    final bytes = await PartStickerLabelPdf.buildSheet(stickers);
    expect(bytes.lengthInBytes, greaterThan(500));
  });

  test('renders when optional label fields are empty', () async {
    // A part with no machine or shift recorded must still produce a label
    // rather than failing the whole print job mid-shift.
    final bare = DplPartSticker(
      id: 99,
      planId: 1,
      planItemId: 2,
      partId: 3,
      serialNo: 'GA2600000001',
      qrPayload: 'GA|GA|X|GA2600000001|260919|-|-',
    );
    final bytes = await PartStickerLabelPdf.buildRoll([bare]);
    expect(bytes.lengthInBytes, greaterThan(500));
  });

  test('renders an unusually long customer part reference', () async {
    // FittedBox scales it down rather than overflowing the die-cut. The
    // failure mode this guards against is a layout exception at print time.
    final long = _sticker(
      customerPartNo: '5464695001020ZX-EXTENDED-VARIANT-SUFFIX-0001',
      payload:
          'GA|GA|5464695001020ZX-EXTENDED-VARIANT-SUFFIX-0001|GA2600000147|260919|A|Nexon SR Line 2',
    );
    final bytes = await PartStickerLabelPdf.buildRoll([long]);
    expect(bytes.lengthInBytes, greaterThan(500));
  });

  test('payload fields are read positionally, matching the Maxion layout', () {
    final s = _sticker();
    // MW|P1|item|serial|YYMMDD|shift|line -> index 3 serial, 5 shift, 6 line.
    expect(s.payloadSerial, 'GA2600000147');
    expect(s.payloadShift, 'A');
    expect(s.payloadLine, 'Nexon SR');
  });

  test('payload getters fall back to stored columns when it is malformed', () {
    // A truncated payload must not blank the label — the database still knows
    // what the sticker is.
    final s = DplPartSticker(
      id: 1,
      planId: 1,
      planItemId: 1,
      partId: 1,
      serialNo: 'GA2600000999',
      qrPayload: 'GA|GA',
      shiftCode: 'B',
      machineName: 'X0 HL',
    );
    expect(s.payloadSerial, 'GA2600000999');
    expect(s.payloadShift, 'B');
    expect(s.payloadLine, 'X0 HL');
  });
}
