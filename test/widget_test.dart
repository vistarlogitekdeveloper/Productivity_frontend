import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:productivity_tracker/core/constants/app_constants.dart';
import 'package:productivity_tracker/data/repositories/local_storage_repository.dart';
import 'package:productivity_tracker/features/auth/login_screen.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_organization_provider.dart';
import 'package:productivity_tracker/main.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester, Map<String, Object> prefs) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues(prefs);
    final sp = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Same override main() installs.
          sharedPreferencesProvider.overrideWithValue(AsyncValue.data(sp)),
          // Keep the login org selector off the network.
          dplOrganizationListProvider.overrideWith((ref) async => const []),
        ],
        child: const ProductionMonitoringApp(),
      ),
    );
    // Let the auth controller's async build and the router settle without
    // waiting on the splash / ambient animations, which never settle.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a fresh install lands on the Vistar Pulse login', (
    tester,
  ) async {
    await pumpApp(tester, {});

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Sign in to Vistar Pulse'), findsOneWidget);
  });

  testWidgets(
    'a stored classic Productivity session lands on login, signed out',
    (tester) async {
      await pumpApp(tester, {
        AppConstants.tokenKey: 'productivity-jwt',
        AppConstants.userRoleKey: 'OPERATOR',
        AppConstants.userIdKey: '7',
        AppConstants.usernameKey: 'op7',
        AppConstants.userNameKey: 'Operator Seven',
      });

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(tester.takeException(), isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConstants.tokenKey), isNull);
    },
  );
}
