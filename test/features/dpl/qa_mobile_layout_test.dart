import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_api_response.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_api_service.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_organization_provider.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_permissions_provider.dart';
import 'package:productivity_tracker/features/dpl/core/widgets/dpl_scan_panel.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_machine.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_organization.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_pallet.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_part.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_shift.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_spd.dart';
import 'package:productivity_tracker/features/dpl/qa/providers/qa_production_provider.dart';
import 'package:productivity_tracker/features/dpl/qa/screens/pallet_lookup_screen.dart';
import 'package:productivity_tracker/features/dpl/qa/screens/qa_direct_print_screen.dart';
import 'package:productivity_tracker/features/dpl/qa/screens/qa_pallet_merge_screen.dart';
import 'package:productivity_tracker/features/dpl/qa/screens/qa_pallet_register_screen.dart';
import 'package:productivity_tracker/features/dpl/qa/screens/qa_putaway_screen.dart';
import 'package:productivity_tracker/features/dpl/qa/screens/qa_spd_screen.dart';

/// The Maxion QA screens at PHONE widths.
///
/// These screens are used on phones and rugged handhelds first. A layout that
/// only works on a desktop browser overflows on a 360 px phone — Flutter
/// reports that as an exception, which fails these tests. Each screen is
/// pumped at the narrowest common Android width (320), the most common (360)
/// and a large phone (412), with realistic data: the long organization name,
/// long item names, and an old Maxion label's full text.
const _widths = <double>[320, 360, 412];

const _allPerms = <String>[
  'labels.print',
  'labels.print_batch',
  'labels.print_pdf417',
  'pallet.view',
  'pallet.build',
  'pallet.close',
  'pallet.merge',
  'pallet.putaway',
  'pallet.spd',
  'pallet.scan_camera',
  'pallet.trolley',
];

class _Perms extends DplPermissionsController {
  @override
  DplPermissions build() => DplPermissions.of(_allPerms);
}

class _Org extends DplActiveOrganization {
  @override
  DplOrganization? build() => const DplOrganization(
        id: 4,
        code: 'MAXION',
        name: 'Maxion Wheels Aluminum India Pvt. Ltd.',
      );
}

final _part = DplPart.fromJson({
  'id': 7,
  'customer_part_no': '19255',
  'description': 'Al Finish Wheel 9255 Piano Black New.',
  'part_name': 'Al Finish Wheel 9255 Piano Black New.',
  'packaging_qty': 24,
});

const _palletJson = <String, dynamic>{
  'id': 10,
  'pallet_no': 'H26000021',
  'pallet_type': 'H',
  'status': 'closed',
  'qty': 15,
  'standard_qty': 24,
  'age_days': 0,
  'closed_at': '2026-10-06T07:00:00Z',
  'part': {'customer_part_no': '19255', 'description': 'Al Finish Wheel 9255 Piano Black New.'},
  'location': {'code': '0404AAA07682N'},
};

List<Override> _overrides() => [
      dplApiServiceProvider.overrideWithValue(DplApiService(Dio())),
      dplPermissionsProvider.overrideWith(_Perms.new),
      dplActiveOrganizationProvider.overrideWith(_Org.new),
      qaMachinesProvider.overrideWith((ref) async => DplApiResponse.ok([
            DplMachine.fromJson({'id': 1, 'machine_code': 'MXN-FIN', 'machine_name': 'Finishing & Packing'}),
          ])),
      // No shift master — the case that used to show two contradicting lines.
      qaShiftsProvider.overrideWith((ref) async => DplApiResponse.ok(<DplShift>[])),
      qaCurrentShiftProvider.overrideWith((ref) async =>
          DplApiResponse.ok(DplShift.fromJson({'id': 2, 'code': 'B', 'name': 'Shift B'}))),
      qaDirectPartsProvider.overrideWith((ref) async => DplApiResponse.ok([
            _part,
            DplPart.fromJson({
              'id': 8,
              'customer_part_no': '8346STBL',
              'description': '8346_Index C_6.0J X 16 SKODA AL WHEEL BL',
              'part_name': '8346_Index C_6.0J X 16 SKODA AL WHEEL BL',
              'packaging_qty': 66,
            }),
          ])),
      qaTrolleyPlansProvider.overrideWith((ref) async => const []),
      spdPacksProvider.overrideWith((ref) async => DplApiResponse.ok(
            DplSpdPage.fromJson({
              'packs': [
                {
                  'id': 1,
                  'pallet_no': 'SP26000411',
                  'serial_no': '19255/std1//13/06Oct26/12:54:33/A/13',
                  'part': {'customer_part_no': '19255', 'description': 'x'},
                  'closed_at': '2026-10-06T07:00:00Z',
                },
              ],
              'total': 1,
            }),
          )),
      palletRegisterProvider.overrideWith((ref) async => DplApiResponse.ok(
            DplPalletPage.fromJson({
              'pallets': [
                _palletJson,
              ],
              'total': 1,
            }),
          )),
    ];

Future<void> _pump(WidgetTester tester, Widget screen, double width) async {
  tester.view.physicalSize = Size(width, 780);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(),
      child: MaterialApp(home: Scaffold(body: screen)),
    ),
  );
  // Let the overridden FutureProviders resolve.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void _noErrors(WidgetTester tester, String what) {
  final e = tester.takeException();
  expect(e, isNull, reason: '$what threw: $e');
}

void main() {
  for (final w in _widths) {
    group('at ${w.toInt()} px', () {
      testWidgets('Print labels — empty, and with an item chosen', (tester) async {
        await _pump(tester, const QaDirectPrintScreen(showAppBar: false), w);
        _noErrors(tester, 'Print labels');

        // The one machine is selected without a tap — the empty-station fix.
        final chip = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, 'Finishing & Packing'),
        );
        expect(chip.selected, isTrue);

        // No shifts set up: ONE line, and no contradicting "every label…".
        expect(find.textContaining('Every label in this run'), findsNothing);
        expect(find.textContaining('Shift B'), findsWidgets);

        // Pick the item; the pinned bar then names it and the pallet preset
        // appears.
        await tester.tap(find.text('19255').first);
        await tester.pump();
        _noErrors(tester, 'Print labels after choosing an item');
        // The pinned bar is on screen without scrolling — that is its job.
        expect(find.text('Print 1'), findsOneWidget);
        // The quantity card is further down the page.
        await tester.scrollUntilVisible(
          find.text('1 pallet · 24'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('1 pallet · 24'), findsOneWidget);

        await tester.ensureVisible(find.text('1 pallet · 24'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('1 pallet · 24'));
        await tester.pump();
        expect(find.text('Print 24'), findsOneWidget);
        _noErrors(tester, 'Print labels after the pallet preset');
      });

      testWidgets('Merge', (tester) async {
        await _pump(tester, const QaPalletMergeScreen(showAppBar: false), w);
        _noErrors(tester, 'Merge');
        expect(find.text('Scan pallet sticker'), findsOneWidget);
        expect(find.text('STEP 1 OF 3'), findsOneWidget);
      });

      testWidgets('Put away', (tester) async {
        await _pump(tester, const QaPutawayScreen(showAppBar: false), w);
        _noErrors(tester, 'Put away');
        expect(find.text('Scan pallet sticker'), findsOneWidget);
      });

      testWidgets('SPD, with a pack whose label is an old Maxion one', (tester) async {
        await _pump(tester, const QaSpdScreen(showAppBar: false), w);
        _noErrors(tester, 'SPD');
        expect(find.text('Scan pallet sticker'), findsOneWidget);
        expect(find.text('Master'), findsOneWidget);
      });

      testWidgets('Pallets built', (tester) async {
        await _pump(tester, const QaPalletRegisterScreen(showAppBar: false), w);
        _noErrors(tester, 'Pallets built');
        expect(find.text('H26000021'), findsOneWidget);
        expect(find.text('Scan'), findsOneWidget);
      });

      testWidgets('Scan to find, with the long organization name in the bar',
          (tester) async {
        await _pump(tester, const PalletLookupScreen(), w);
        _noErrors(tester, 'Scan to find');
        expect(find.text('Scan a label'), findsOneWidget);
      });
    });
  }

  testWidgets('the scan panel submits from the Go button, and ignores blanks',
      (tester) async {
    final submitted = <String>[];
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DplScanPanel(
          title: 'Scan',
          controller: ctrl,
          onSubmitted: submitted.add,
        ),
      ),
    ));

    await tester.tap(find.byTooltip('Go'));
    expect(submitted, isEmpty);

    await tester.enterText(find.byType(TextField), 'H26000021');
    await tester.tap(find.byTooltip('Go'));
    expect(submitted, ['H26000021']);

    // No camera allowed: no big button, the field is the way in.
    expect(find.byType(FilledButton), findsNothing);
  });
}
