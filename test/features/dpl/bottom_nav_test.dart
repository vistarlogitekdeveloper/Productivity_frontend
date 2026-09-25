import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:productivity_tracker/features/dpl/core/widgets/dpl_bottom_nav.dart';

/// The QA shell at full stretch — every tab an administrator can switch on.
/// This is the case that overflowed: seven cells, and the longest label in the
/// app sitting in one of them.
const _qaTabs = <DplNavItem>[
  DplNavItem(
    icon: Icons.print_outlined,
    selectedIcon: Icons.print,
    label: 'Print labels',
  ),
  DplNavItem(
    icon: Icons.inventory_2_outlined,
    selectedIcon: Icons.inventory_2,
    label: 'Pallet',
  ),
  DplNavItem(
    icon: Icons.merge_outlined,
    selectedIcon: Icons.merge,
    label: 'Merge',
  ),
  DplNavItem(
    icon: Icons.warehouse_outlined,
    selectedIcon: Icons.warehouse,
    label: 'Put away',
  ),
  DplNavItem(
    icon: Icons.call_split_outlined,
    selectedIcon: Icons.call_split,
    label: 'SPD',
  ),
  DplNavItem(
    icon: Icons.grid_view_outlined,
    selectedIcon: Icons.grid_view,
    label: 'Pallets built',
  ),
  DplNavItem(
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long,
    label: 'Slips',
  ),
];

Future<void> _pumpNav(
  WidgetTester tester, {
  required Size size,
  required double textScale,
  List<DplNavItem> items = _qaTabs,
  int index = 0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(textScale),
      ),
      child: MaterialApp(
        home: Scaffold(
          bottomNavigationBar: DplBottomNav(
            currentIndex: index,
            onTap: (_) {},
            items: items,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // Real devices this has to survive: a small budget Android phone, the
  // handhelds the pack point actually uses, and a tablet.
  const widths = <String, double>{
    'small phone (320)': 320,
    'handheld (360)': 360,
    'common phone (390)': 390,
    'the screenshot (468)': 468,
    'large phone (430)': 430,
    'small tablet (600)': 600,
    'tablet (800)': 800,
  };

  // Android's font size slider runs well past 1.0. 1.3 is "Large", 2.0 is the
  // accessibility maximum, and a warehouse in a bright building turns it up.
  const scales = <double>[1.0, 1.15, 1.3, 1.6, 2.0];

  group('the bar never overflows', () {
    for (final entry in widths.entries) {
      for (final scale in scales) {
        testWidgets('${entry.key} at ${scale}x text', (tester) async {
          await _pumpNav(
            tester,
            size: Size(entry.value, 800),
            textScale: scale,
          );
          // A RenderFlex overflow is reported as an exception by the test
          // framework, which is exactly the red stripe seen on the device.
          expect(
            tester.takeException(),
            isNull,
            reason: 'overflowed at ${entry.value}px, ${scale}x text',
          );
        });
      }
    }
  });

  group('what it draws as space runs out', () {
    testWidgets('seven tabs on a wide screen keep their labels',
        (tester) async {
      await _pumpNav(tester, size: const Size(800, 800), textScale: 1.0);
      expect(find.text('Pallets built'), findsOneWidget);
      expect(find.text('Print labels'), findsOneWidget);
    });

    testWidgets('on a narrow screen labels give way to icons, not to mush',
        (tester) async {
      // 320 / 7 = 45dp a cell. A label squeezed into that is unreadable at
      // arm's length, so it is dropped rather than rendered as decoration.
      await _pumpNav(tester, size: const Size(320, 800), textScale: 1.0);
      expect(find.text('Pallets built'), findsNothing);
      // The meaning survives for the screen reader and on a long press.
      expect(
        find.byTooltip('Pallets built'),
        findsOneWidget,
        reason: 'an icon-only tab must still say what it is',
      );
    });

    testWidgets('a four-tab bar keeps labels even on a small phone',
        (tester) async {
      // The Manager shell. 320 / 4 = 80dp, comfortably above the floor, so
      // dropping labels there would be a regression for a shell that was fine.
      await _pumpNav(
        tester,
        size: const Size(320, 800),
        textScale: 1.0,
        items: dplManagerNavItems,
      );
      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });
  });

  group('the bar stays usable', () {
    testWidgets('every tab is still tappable at the tightest size',
        (tester) async {
      final tapped = <int>[];
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: DplBottomNav(
              currentIndex: 0,
              onTap: tapped.add,
              items: _qaTabs,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The last tab is the one a squeezed row would push off the edge.
      await tester.tap(find.byIcon(Icons.receipt_long_outlined));
      await tester.pumpAndSettle();
      expect(tapped, [6]);
    });

    testWidgets('the selected tab is the one that is marked', (tester) async {
      await _pumpNav(
        tester,
        size: const Size(430, 800),
        textScale: 1.0,
        index: 3,
      );
      // Selected uses the FILLED icon; the others keep the outline.
      expect(find.byIcon(Icons.warehouse), findsOneWidget);
      expect(find.byIcon(Icons.warehouse_outlined), findsNothing);
      expect(find.byIcon(Icons.print_outlined), findsOneWidget);
    });

    testWidgets('an empty item list does not divide by zero', (tester) async {
      await _pumpNav(
        tester,
        size: const Size(390, 800),
        textScale: 1.0,
        items: const <DplNavItem>[],
      );
      expect(tester.takeException(), isNull);
    });
  });
}
