import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/auth/login_screen.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_organization_provider.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_organization.dart';

/// The landing flow is a product decision, not an implementation detail —
/// these lock it in so a refactor can't quietly flip it back.
void main() {
  Future<void> pumpLogin(
    WidgetTester tester, {
    List<DplOrganization> orgs = const [],
  }) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Keep the org selector off the network.
          dplOrganizationListProvider.overrideWith((ref) async => orgs),
        ],
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pump();
  }

  testWidgets('signs in to Vistar Pulse only', (tester) async {
    await pumpLogin(tester);

    expect(find.text('Vistar Pulse'), findsWidgets);
    expect(find.text('Sign in to Vistar Pulse'), findsOneWidget);
  });

  testWidgets('shows the Pulse fields on first paint', (tester) async {
    await pumpLogin(tester);

    // Email (not Username) and the org selector are Pulse-only.
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Username'), findsNothing);
    expect(find.text('Organization'), findsWidgets);
  });

  testWidgets('offers no classic Productivity flow or flow picker', (
    tester,
  ) async {
    await pumpLogin(tester);

    // The classic Productivity module is retired: no chip to switch to it,
    // and no picker at all now that only one flow remains.
    expect(find.text('Productivity'), findsNothing);
    expect(find.text('Sign in to Productivity'), findsNothing);
    expect(find.text('SIGN IN WITH'), findsNothing);
  });
}
