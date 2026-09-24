import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_constants.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_permissions_provider.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_spd.dart';
import 'package:productivity_tracker/features/dpl/qa/services/spd_label_pdf.dart';

/// SPD conversion — Maxion SSR §8, Module 12.
///
/// A customer orders spare parts by the wheel, so a pack is ONE wheel with its
/// own number and its own label. These pin the things a person cannot check by
/// looking at a screen: what goes into the QR, and whether the label renders at
/// all on inputs the plant will actually produce.
DplSpdPack _pack({
  String no = 'SP26000411',
  String serial = 'GA2600000147',
  String partNo = '546469500102ZX',
  String? payload,
}) {
  return DplSpdPack.fromJson({
    'id': 9,
    'pallet_no': no,
    if (payload != null) 'qr_payload': payload,
    'serial_no': serial,
    'part': {'customer_part_no': partNo, 'description': '102D1'},
    'status': 'closed',
    'closed_at': '2026-09-24T10:00:00.000Z',
  });
}

void main() {
  group('the SPD pack QR', () {
    test('carries MWS and the pack number, matching the reference', () {
      // generateSpdPackQr in the reference backend is `MWS|${spdPackNumber}`.
      // Three prefixes now exist and each sends the scanner somewhere
      // different, so they must stay distinguishable: MW/GA a wheel, MWP a
      // pallet, MWS a pack.
      expect(_pack().qrPayload, 'MWS|SP26000411');
    });

    test('is derived when the server omits it, never left blank', () {
      // A label with no payload is a label nobody can scan, and the rule is
      // fixed — so it is reconstructed rather than printed empty.
      final p = DplSpdPack.fromJson({'pallet_no': 'SP26000412'});
      expect(p.qrPayload, 'MWS|SP26000412');
    });

    test('the server value wins when present', () {
      expect(_pack(payload: 'MWS|OVERRIDE').qrPayload, 'MWS|OVERRIDE');
    });

    test('a pack with no number has no payload to invent', () {
      expect(DplSpdPack.fromJson(const {}).qrPayload, '');
    });
  });

  group('the SPD label', () {
    test('prints on the 50 x 25 mm scanning die-cut, not the pallet stock', () {
      // The reference app's label_stock.dart lists exactly two die-cuts the
      // plant buys and calls the small one the "Individual wheel / SPD pack
      // scanning label". A pack is one wheel going into a box.
      expect(SpdLabelPdf.rollFormat.width, closeTo(50 * PdfPageFormat.mm, 0.01));
      expect(SpdLabelPdf.rollFormat.height, closeTo(25 * PdfPageFormat.mm, 0.01));
      expect(SpdLabelPdf.rollFormat.marginLeft, 0);
    });

    test('emits one page per pack, so a run comes off as a strip', () {
      final doc = SpdLabelPdf.buildRollDocument([
        _pack(no: 'SP26000411'),
        _pack(no: 'SP26000412'),
        _pack(no: 'SP26000413'),
      ]);
      expect(doc.document.pdfPageList.pages.length, 3);
    });

    test('it renders', () async {
      final bytes = await SpdLabelPdf.buildRoll([_pack()]);
      expect(bytes.length, greaterThan(500));
      expect(bytes.sublist(0, 5), [0x25, 0x50, 0x44, 0x46, 0x2D]);
    });

    test('a blank pack still produces a page rather than throwing', () async {
      // pdf's FittedBox asserts width > 0, so one empty string in the text
      // column throws — and the throw would land AFTER the conversion was
      // already committed on the server, reading as the conversion failing.
      final bytes = await SpdLabelPdf.buildRoll([const DplSpdPack()]);
      expect(bytes.length, greaterThan(400));
    });

    test('an empty run is still a valid one-page document', () async {
      // Some print pipelines reject a zero-page PDF outright.
      final doc = SpdLabelPdf.buildRollDocument(const []);
      expect(doc.document.pdfPageList.pages.length, 1);
    });

    test('a part number far longer than the label does not overflow it', () async {
      final bytes = await SpdLabelPdf.buildRoll([
        _pack(partNo: '546469500102ZX-EXPORT-VARIANT-WITH-EXTRA-TRIM-AND-FIXINGS'),
      ]);
      expect(bytes.length, greaterThan(500));
    });
  });

  group('DplPalletWheels', () {
    Map<String, dynamic> body() => {
          'pallet': {'id': 1, 'pallet_no': 'P26000010', 'qty': 5, 'standard_qty': 5},
          'wheels': [
            {'id': 1, 'serial_no': 'GA2600000101', 'status': 'issued'},
            {'id': 2, 'serial_no': 'GA2600000102', 'status': 'voided'},
            {'id': 3, 'serial_no': 'GA2600000103', 'status': 'issued'},
          ],
        };

    test('a voided wheel is never offered for picking', () {
      // It was spoiled and retired. The server refuses it anyway, but finding
      // that out after choosing is a wasted trip to the bench.
      final w = DplPalletWheels.fromJson(body());
      expect(w.wheels.length, 3);
      expect(w.sellable.length, 2);
      expect(w.sellable.any((x) => x.isVoided), isFalse);
    });

    test('a malformed response is an empty list, not a crash', () {
      final w = DplPalletWheels.fromJson(const {});
      expect(w.wheels, isEmpty);
      expect(w.sellable, isEmpty);
      expect(w.pallet.palletNo, '');
    });
  });

  group('DplSpdResult', () {
    test('a partial take reprints the pallet; a full take does not', () {
      // The pallet's count changed, so its master label is wrong (§5). But a
      // consumed pallet holds nothing, and a label for that is worse than
      // none — so the server decides, not the screen.
      final partial = DplSpdResult.fromJson({
        'source': {'id': 1, 'pallet_no': 'H26000010', 'qty': 2},
        'source_consumed': false,
        'packs': [
          {'id': 9, 'pallet_no': 'SP26000411'},
          {'id': 10, 'pallet_no': 'SP26000412'},
        ],
        'reprint_source': 1,
      });
      expect(partial.packs.length, 2);
      expect(partial.sourceConsumed, isFalse);
      expect(partial.reprintSource, 1);

      final full = DplSpdResult.fromJson({
        'source': {'id': 1, 'pallet_no': 'P26000010', 'qty': 0},
        'source_consumed': true,
        'packs': [
          {'id': 9, 'pallet_no': 'SP26000411'},
        ],
        'reprint_source': null,
      });
      expect(full.sourceConsumed, isTrue);
      expect(full.reprintSource, isNull);
    });
  });

  group('SPD is opt-in and correctly routed', () {
    test('an unknown permission list does not hand a plant SPD', () {
      const p = DplPermissions.unknown();
      expect(p.can(DplPermission.palletSpd), isFalse);
      expect(DplPermission.optInOnly.contains(DplPermission.palletSpd), isTrue);
    });

    test('it is separate from building, merging and putaway', () {
      // Converting stock for a customer order is a different authority from
      // packing or storing it, so a plant can grant one without the others.
      final packer = DplPermissions.of(const [
        'pallet.build',
        'pallet.close',
        'pallet.merge',
        'pallet.putaway',
      ]);
      expect(packer.can(DplPermission.palletSpd), isFalse);

      final spd = DplPermissions.of(const ['pallet.spd']);
      expect(spd.can(DplPermission.palletSpd), isTrue);
      expect(spd.can(DplPermission.palletBuild), isFalse);
    });

    test('the register is a literal path, never shadowed by a pallet id', () {
      // Express 5 dropped ':id(\\d+)', so '/qa/spd' surviving depends on
      // registration order. If this ever becomes '/qa/pallets/spd' it would be
      // matched as a pallet whose id is the word "spd".
      expect(DplPaths.qaSpdPacks, '/qa/spd');
      expect(DplPaths.qaPalletWheels(7), '/qa/pallets/7/wheels');
      expect(DplPaths.qaPalletSpd(7), '/qa/pallets/7/spd');
    });
  });
}
