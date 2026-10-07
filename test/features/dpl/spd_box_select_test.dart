import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_api_response.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_api_service.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_permissions_provider.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_spd.dart';
import 'package:productivity_tracker/features/dpl/qa/screens/qa_spd_screen.dart';
import 'package:productivity_tracker/features/dpl/qa/services/spd_master_sticker_pdf.dart';

/// One master sticker for packs the operator picks — whichever conversions
/// they came from. The plant's case: SP26000011–13, made one at a time, all
/// going in one box.
class _Perms extends DplPermissionsController {
  @override
  DplPermissions build() => DplPermissions.of(const ['pallet.spd', 'pallet.scan_camera']);
}

Map<String, dynamic> _pack(int id, String no, String item) => {
      'id': id,
      'pallet_no': no,
      'serial_no': '9313BM/std 2//5$id/26Sep2~b05117$id',
      // Each its own conversion, as on the floor.
      'spd_batch_no': no,
      'part': {'customer_part_no': item, 'description': '9313_19x8J_Stardust GREY BM'},
      'closed_at': '2026-09-26T07:00:00Z',
    };

DplSpdPack _p(int id, String no, String item) => DplSpdPack.fromJson(_pack(id, no, item));

void main() {
  group('one box from picked packs', () {
    test('packs from separate conversions go on ONE sticker when picked together', () {
      final picked = [
        _p(13, 'SP26000013', '9313BM'),
        _p(11, 'SP26000011', '9313BM'),
        _p(12, 'SP26000012', '9313BM'),
      ];
      // By batch they would be three stickers...
      expect(SpdMasterStickerPdf.sheets(picked).length, 3);
      // ...picked for one box, they are one, in number order.
      final one = SpdMasterStickerPdf.sheets(picked, oneBox: true);
      expect(one.length, 1);
      expect(one.single.map((p) => p.packNo), ['SP26000011', 'SP26000012', 'SP26000013']);
      expect(SpdMasterStickerPdf.qtyFor(one.single.length), 'QTY - 03 NOS');
      expect(
        SpdMasterStickerPdf.buildRollDocument(picked, oneBox: true).document.pdfPageList.pages.length,
        1,
      );
    });

    test('long serials print one full-width column, eight to a sticker', () {
      final ten = [for (var i = 10; i < 20; i++) _p(i, 'SP260000$i', '9313BM')];
      expect(SpdMasterStickerPdf.capacityFor(ten), SpdMasterStickerPdf.perStickerLong);
      expect(SpdMasterStickerPdf.sheets(ten, oneBox: true).map((s) => s.length), [8, 2]);
    });

    test('a different item never shares a part code', () {
      final mixed = [_p(1, 'SP26000001', '9313BM'), _p(2, 'SP26000002', '19255')];
      expect(SpdMasterStickerPdf.sheets(mixed, oneBox: true).length, 2);
    });
  });

  testWidgets('Select, tick three packs, print one master', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        dplApiServiceProvider.overrideWithValue(DplApiService(Dio())),
        dplPermissionsProvider.overrideWith(_Perms.new),
        spdPacksProvider.overrideWith((ref) async => DplApiResponse.ok(DplSpdPage.fromJson({
              'packs': [
                _pack(13, 'SP26000013', '9313BM'),
                _pack(12, 'SP26000012', '9313BM'),
                _pack(11, 'SP26000011', '9313BM'),
                _pack(9, 'SP26000009', '19255'),
              ],
              'total': 4,
            }))),
      ],
      child: const MaterialApp(home: Scaffold(body: QaSpdScreen(showAppBar: false))),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(Checkbox), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Select'));
    await tester.pump();

    expect(find.byType(Checkbox), findsNWidgets(4));
    // Per-pack buttons step aside while picking.
    expect(find.widgetWithText(TextButton, 'Master'), findsNothing);
    expect(find.text('Tick at least one pack'), findsOneWidget);

    for (final no in ['SP26000013', 'SP26000012', 'SP26000011']) {
      await tester.tap(find.text(no));
      await tester.pump();
    }
    expect(find.text('Print one master for 3 packs'), findsOneWidget);

    // Another item is refused, not mixed in.
    await tester.ensureVisible(find.text('SP26000009'));
    await tester.tap(find.text('SP26000009'));
    await tester.pump();
    expect(find.textContaining('One master sticker holds one item'), findsOneWidget);
    expect(find.text('Print one master for 3 packs'), findsOneWidget);

    // Unticking works, and Cancel clears the lot.
    await tester.tap(find.text('SP26000012'));
    await tester.pump();
    expect(find.text('Print one master for 2 packs'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump();
    expect(find.byType(Checkbox), findsNothing);
    expect(find.widgetWithText(TextButton, 'Master'), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });
}
