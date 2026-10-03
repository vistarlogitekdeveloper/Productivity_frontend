import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/core/constants/app_constants.dart';
import 'package:productivity_tracker/data/repositories/local_storage_repository.dart';
import 'package:productivity_tracker/features/auth/auth_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The classic Productivity module is retired and its backend answers 410
/// Gone. A device upgraded while still signed in there must come up signed
/// out — not restore a session no screen can serve — while Vistar Pulse and
/// Workspace sessions restore exactly as before.
void main() {
  Future<ProviderContainer> containerWith(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final sp = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(AsyncValue.data(sp)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  for (final role in const ['ADMIN', 'SUPERVISOR', 'BRIN', 'OPERATOR']) {
    test('a stored classic Productivity $role session is signed out', () async {
      final c = await containerWith({
        AppConstants.tokenKey: 'productivity-jwt',
        AppConstants.userRoleKey: role,
        AppConstants.userIdKey: '7',
        AppConstants.usernameKey: 'op7',
        AppConstants.userNameKey: 'Operator Seven',
        // The classic module's offline queue of production entries.
        'OFFLINE_ENTRIES': '[{"id":1}]',
        // Device-scoped: must survive, like on any logout.
        AppConstants.dplDeviceIdKey: 'HHT-abc123',
        AppConstants.dplLanguageKey: 'mr',
      });

      final user = await c.read(authControllerProvider.future);
      expect(user, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConstants.tokenKey), isNull);
      expect(prefs.getString(AppConstants.userRoleKey), isNull);
      expect(prefs.getString('OFFLINE_ENTRIES'), isNull);
      expect(prefs.getString(AppConstants.dplDeviceIdKey), 'HHT-abc123');
      expect(prefs.getString(AppConstants.dplLanguageKey), 'mr');
    });
  }

  test('a stored Vistar Pulse session is restored unchanged', () async {
    final c = await containerWith({
      AppConstants.tokenKey: 'dpl-jwt',
      AppConstants.userRoleKey: AppConstants.roleDplManager,
      AppConstants.userIdKey: '42',
      AppConstants.usernameKey: 'manager@vistarlogitek.com',
      AppConstants.userNameKey: 'Plant Manager',
    });

    final user = await c.read(authControllerProvider.future);
    expect(user, isNotNull);
    expect(user!.role, AppConstants.roleDplManager);
    expect(user.id, '42');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppConstants.tokenKey), 'dpl-jwt');
  });

  test('a stored Vistar Workspace session is restored unchanged', () async {
    final c = await containerWith({
      AppConstants.tokenKey: 'vistar-workspace-local-session',
      AppConstants.userRoleKey: AppConstants.roleVistarWorkspace,
      AppConstants.userIdKey: 'vistar-workspace',
      AppConstants.usernameKey: 'someone@vistarlogitek.com',
      AppConstants.userNameKey: 'Someone',
    });

    final user = await c.read(authControllerProvider.future);
    expect(user?.role, AppConstants.roleVistarWorkspace);
  });

  test('signing out a stale session happens once, then stays signed out',
      () async {
    final c = await containerWith({
      AppConstants.tokenKey: 'productivity-jwt',
      AppConstants.userRoleKey: 'OPERATOR',
    });
    expect(await c.read(authControllerProvider.future), isNull);

    // A rebuild (e.g. the next app start) finds nothing left to restore.
    c.invalidate(authControllerProvider);
    expect(await c.read(authControllerProvider.future), isNull);
  });
}
