import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_part.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_spd.dart';
import 'package:productivity_tracker/features/dpl/qa/services/spd_master_sticker_pdf.dart';

/// The SPD master sticker — the plant's samples read, top to bottom:
///   PNAF9311A00B0 / AZ00224 / ALLOY WHEEL FOR Z101 / QTY - 01 NOS
/// with our SPD pack number in place of AZ00224.
void main() {
  DplSpdPack pack({
    String item = '9311',
    String spd = 'ALLOY WHEEL FOR Z101',
    String no = 'SP26000411',
    String? batch,
  }) => DplSpdPack.fromJson({
    'id': 1,
    'pallet_no': no,
    'serial_no': 'GA26000000${no.substring(no.length - 2)}',
    'spd_batch_no': ?batch,
    'part': {
      'customer_part_no': item,
      'description': '9311- 7.5Jx18_GREY SPARKLE BM',
      'spd_description': spd,
    },
  });

  group('the four lines', () {
    test('line 1 is PNAF + item code + A00B0, as on the samples', () {
      expect(SpdMasterStickerPdf.partCode(pack()), 'PNAF9311A00B0');
      expect(SpdMasterStickerPdf.partCode(pack(item: '9042')), 'PNAF9042A00B0');
      // The master has "9345 Silver"; a space cannot be in a part code.
      expect(
        SpdMasterStickerPdf.partCode(pack(item: '9345 Silver')),
        'PNAF9345SILVERA00B0',
      );
    });

    test('line 2 is the SPD pack number', () {
      expect(pack().packNo, 'SP26000411');
    });

    test('line 3 is the SPD description, else the item description', () {
      expect(SpdMasterStickerPdf.itemLine(pack()), 'ALLOY WHEEL FOR Z101');
      expect(
        SpdMasterStickerPdf.itemLine(pack(spd: '')),
        '9311- 7.5Jx18_GREY SPARKLE BM',
      );
    });

    test('a pack label counts one piece; the box counts its packs', () {
      expect(SpdMasterStickerPdf.qtyLine, 'QTY - 01 NOS');
      expect(SpdMasterStickerPdf.qtyFor(4), 'QTY - 04 NOS');
      expect(SpdMasterStickerPdf.qtyFor(12), 'QTY - 12 NOS');
    });

    test('the batch comes from the server, else the pack is its own', () {
      expect(pack(batch: 'SP26000400').batchNo, 'SP26000400');
      expect(pack().batchNo, 'SP26000411');
    });
  });

  group('the document', () {
    test('is the 100 x 75 mm pallet-label stock', () {
      expect(
        SpdMasterStickerPdf.rollFormat.width,
        closeTo(100 * PdfPageFormat.mm, 0.001),
      );
      expect(
        SpdMasterStickerPdf.rollFormat.height,
        closeTo(75 * PdfPageFormat.mm, 0.001),
      );
    });

    test('one sticker for a whole conversion, and it renders', () async {
      final four = [
        for (final n in [
          'SP26000026',
          'SP26000024',
          'SP26000023',
          'SP26000025',
        ])
          pack(item: '19255', no: n, batch: 'SP26000023'),
      ];
      final doc = SpdMasterStickerPdf.buildRollDocument(four);
      expect(doc.document.pdfPageList.pages.length, 1);
      final sheet = SpdMasterStickerPdf.sheets(four).single;
      // Listed in number order, whatever order they arrived in.
      expect(sheet.map((p) => p.packNo), [
        'SP26000023',
        'SP26000024',
        'SP26000025',
        'SP26000026',
      ]);
      expect(SpdMasterStickerPdf.qtyFor(sheet.length), 'QTY - 04 NOS');
      final bytes = await SpdMasterStickerPdf.buildRoll(four);
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });

    test('two conversions print two stickers', () {
      final sheets = SpdMasterStickerPdf.sheets([
        pack(no: 'SP26000023', batch: 'SP26000023'),
        pack(no: 'SP26000024', batch: 'SP26000023'),
        pack(no: 'SP26000030', batch: 'SP26000030'),
      ]);
      expect(sheets.map((s) => s.length), [2, 1]);
    });

    test('a pack from an older server is a box of its own', () {
      final sheets = SpdMasterStickerPdf.sheets([
        pack(no: 'SP26000001'),
        pack(no: 'SP26000002'),
      ]);
      expect(sheets.length, 2);
    });

    test('a batch bigger than one sticker runs on to the next', () {
      final many = [
        for (var i = 10; i < 10 + SpdMasterStickerPdf.perSticker + 3; i++)
          pack(no: 'SP260000$i', batch: 'SP26000010'),
      ];
      final sheets = SpdMasterStickerPdf.sheets(many);
      expect(sheets.map((s) => s.length), [SpdMasterStickerPdf.perSticker, 3]);
      expect(
        SpdMasterStickerPdf.buildRollDocument(
          many,
        ).document.pdfPageList.pages.length,
        2,
      );
    });

    test('an empty run still yields one valid page', () {
      expect(
        SpdMasterStickerPdf.buildRollDocument(
          const [],
        ).document.pdfPageList.pages.length,
        1,
      );
    });
  });

  group('the SPD description on the item master', () {
    test('is sent only when known, so an older backend still saves parts', () {
      // Read from a server that predates migration 198: no key at all.
      final old = DplPart.fromJson({
        'id': 1,
        'customer_part_no': '9311',
        'description': 'x',
      });
      expect(old.spdDescription, isNull);
      expect(old.toJsonForWrite().containsKey('spd_description'), isFalse);

      final set = DplPart.fromJson({
        'id': 1,
        'customer_part_no': '9311',
        'description': 'x',
        'spd_description': 'ALLOY WHEEL FOR Z101',
      });
      expect(set.toJsonForWrite()['spd_description'], 'ALLOY WHEEL FOR Z101');
    });

    test('a blank clears it rather than storing an empty string', () {
      const cleared = DplPart(
        id: 1,
        partNumber: '9311',
        description: 'x',
        spdDescription: '  ',
      );
      final body = cleared.toJsonForWrite();
      expect(body.containsKey('spd_description'), isTrue);
      expect(body['spd_description'], isNull);
    });
  });
}
