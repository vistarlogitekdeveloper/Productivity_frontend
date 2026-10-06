import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_part.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_spd.dart';
import 'package:productivity_tracker/features/dpl/qa/services/spd_master_sticker_pdf.dart';

/// The SPD master sticker — the plant's samples read, top to bottom:
///   PNAF9311A00B0 / AZ00224 / ALLOY WHEEL FOR Z101 / QTY - 01 NOS
/// with our SPD pack number in place of AZ00224.
void main() {
  DplSpdPack pack({String item = '9311', String spd = 'ALLOY WHEEL FOR Z101'}) =>
      DplSpdPack.fromJson({
        'id': 1,
        'pallet_no': 'SP26000411',
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
      expect(SpdMasterStickerPdf.partCode(pack(item: '9345 Silver')),
          'PNAF9345SILVERA00B0');
    });

    test('line 2 is the SPD pack number', () {
      expect(pack().packNo, 'SP26000411');
    });

    test('line 3 is the SPD description, else the item description', () {
      expect(SpdMasterStickerPdf.itemLine(pack()), 'ALLOY WHEEL FOR Z101');
      expect(SpdMasterStickerPdf.itemLine(pack(spd: '')),
          '9311- 7.5Jx18_GREY SPARKLE BM');
    });

    test('line 4 is always one piece', () {
      expect(SpdMasterStickerPdf.qtyLine, 'QTY - 01 NOS');
    });
  });

  group('the document', () {
    test('is the 100 x 75 mm pallet-label stock', () {
      expect(SpdMasterStickerPdf.rollFormat.width,
          closeTo(100 * PdfPageFormat.mm, 0.001));
      expect(SpdMasterStickerPdf.rollFormat.height,
          closeTo(75 * PdfPageFormat.mm, 0.001));
    });

    test('one page per pack, and it renders', () async {
      final doc = SpdMasterStickerPdf.buildRollDocument([pack(), pack(item: '9042')]);
      expect(doc.document.pdfPageList.pages.length, 2);
      final bytes = await SpdMasterStickerPdf.buildRoll([pack()]);
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });
  });

  group('the SPD description on the item master', () {
    test('is sent only when known, so an older backend still saves parts', () {
      // Read from a server that predates migration 198: no key at all.
      final old = DplPart.fromJson({'id': 1, 'customer_part_no': '9311', 'description': 'x'});
      expect(old.spdDescription, isNull);
      expect(old.toJsonForWrite().containsKey('spd_description'), isFalse);

      final set = DplPart.fromJson({
        'id': 1, 'customer_part_no': '9311', 'description': 'x',
        'spd_description': 'ALLOY WHEEL FOR Z101',
      });
      expect(set.toJsonForWrite()['spd_description'], 'ALLOY WHEEL FOR Z101');
    });

    test('a blank clears it rather than storing an empty string', () {
      const cleared = DplPart(id: 1, partNumber: '9311', description: 'x', spdDescription: '  ');
      final body = cleared.toJsonForWrite();
      expect(body.containsKey('spd_description'), isTrue);
      expect(body['spd_description'], isNull);
    });
  });
}
