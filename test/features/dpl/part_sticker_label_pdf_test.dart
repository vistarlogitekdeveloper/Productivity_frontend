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

  /// The production-sticker line, checked against a real Maxion print.
  ///
  /// Every expectation here is read off PROD-007258 — a 20-up run of item
  /// 18663 at station std01, shift A, printed 29 Sep 2026 16:36:45.
  group('the Maxion production line', () {
    DplPartSticker sticker({
      String customerPartNo = '18663',
      String qrPayload = 'GA|P1|18663|GA2600000063|260929|A|std01',
      int seq = 1,
      DateTime? printedAt,
      String shiftCode = 'A',
      String machineName = 'std01',
    }) =>
        DplPartSticker(
          id: 1,
          planId: 1,
          planItemId: 1,
          partId: 1,
          serialNo: 'GA2600000063',
          qrPayload: qrPayload,
          customerPartNo: customerPartNo,
          shiftCode: shiftCode,
          machineName: machineName,
          seqInBatch: seq,
          printedAt: printedAt,
        );

    final runAt = DateTime(2026, 9, 29, 16, 36, 45);

    test('reproduces page 1 of PROD-007258 exactly', () {
      expect(
        PartStickerLabelPdf.productionLine(sticker(), index: 1, runAt: runAt),
        '18663/std01//1/29Sep26/16:36:45/A/1',
      );
    });

    test('reproduces the two-digit sequence pages', () {
      // Pages 10 and 20 are where a padding mistake would show.
      expect(
        PartStickerLabelPdf.productionLine(sticker(seq: 10), index: 10, runAt: runAt),
        '18663/std01//10/29Sep26/16:36:45/A/10',
      );
      expect(
        PartStickerLabelPdf.productionLine(sticker(seq: 20), index: 20, runAt: runAt),
        '18663/std01//20/29Sep26/16:36:45/A/20',
      );
    });

    test('field 2 stays empty', () {
      // Blank on every sticker in the sample. Putting anything there shifts
      // the date, time and shift one place along for anyone parsing by index.
      final parts = PartStickerLabelPdf
          .productionLine(sticker(), index: 1, runAt: runAt)
          .split('/');
      expect(parts.length, 8);
      expect(parts[2], isEmpty);
      expect(parts[4], '29Sep26', reason: 'date must stay at index 4');
      expect(parts[6], 'A', reason: 'shift must stay at index 6');
    });

    test('a single-digit day is not zero-padded, but the clock is', () {
      expect(
        PartStickerLabelPdf.productionLine(
          sticker(),
          index: 1,
          runAt: DateTime(2026, 9, 1, 6, 5, 4),
        ),
        '18663/std01//1/1Sep26/06:05:04/A/1',
      );
    });

    test('the whole run shares one timestamp', () {
      // Twenty stickers off one Save & Print all read 16:36:45 in the sample.
      final one = PartStickerLabelPdf.productionLine(sticker(seq: 1), index: 1, runAt: runAt);
      final twenty = PartStickerLabelPdf.productionLine(sticker(seq: 20), index: 20, runAt: runAt);
      expect(one.split('/')[5], twenty.split('/')[5]);
    });

    test("a sticker's own printedAt wins over the run clock", () {
      // The server stamps it; a reprint of one spoiled label should carry when
      // THAT label was issued, not when this run started.
      expect(
        PartStickerLabelPdf.productionLine(
          sticker(printedAt: DateTime(2026, 9, 30, 9, 0, 1)),
          index: 1,
          runAt: runAt,
        ),
        '18663/std01//1/30Sep26/09:00:01/A/1',
      );
    });

    test('station and shift come off the payload, not the stored columns', () {
      // The payload is the snapshot taken at print time; the columns can be
      // edited afterwards. The label must say what was printed.
      expect(
        PartStickerLabelPdf.productionLine(
          sticker(
            qrPayload: 'GA|P1|18663|GA2600000063|260929|B|std07',
            shiftCode: 'A',
            machineName: 'std01',
          ),
          index: 1,
          runAt: runAt,
        ),
        '18663/std07//1/29Sep26/16:36:45/B/1',
      );
    });

    test('a missing station leaves the field empty, not a dash', () {
      // '-' is what the getters use for "nothing"; printing it into a
      // positional string would make it look like a real station name.
      expect(
        PartStickerLabelPdf.productionLine(
          sticker(qrPayload: 'GA|P1|18663|GA2600000063|260929|A|', machineName: ''),
          index: 1,
          runAt: runAt,
        ),
        '18663///1/29Sep26/16:36:45/A/1',
      );
    });

    test('the QR still holds OUR payload, not the printed line', () {
      // The whole system resolves on the serial inside the pipe payload.
      // If this ever flips, every scanning screen stops working.
      final s = sticker();
      expect(s.qrPayload, contains('GA2600000063'));
      expect(s.qrPayload, contains('|'));
      expect(s.qrPayload, isNot(contains('/')));
    });
  });
}
