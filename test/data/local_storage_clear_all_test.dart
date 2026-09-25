import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/core/constants/app_constants.dart';
import 'package:productivity_tracker/data/repositories/local_storage_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Logout calls clearAll(). It must wipe the person, never the device: the
// offline outbox holds floor scans not yet synced, and losing them on a shift
// change would silently drop real work.
void main() {
  test('clearAll wipes the session but keeps the offline outbox, device id and language', () async {
    SharedPreferences.setMockInitialValues({
      AppConstants.tokenKey: 'jwt',
      AppConstants.dplPermissionsKey: <String>['pallet.build'],
      AppConstants.dplSyncOutboxKey: '[{"txn_id":"HHT-1-7","seq":7}]',
      AppConstants.dplSyncNextSeqKey: 8,
      AppConstants.dplDeviceIdKey: 'HHT-abc123',
      AppConstants.dplLanguageKey: 'mr',
    });
    final prefs = await SharedPreferences.getInstance();
    await LocalStorageRepository(prefs).clearAll();

    expect(prefs.getString(AppConstants.tokenKey), isNull);
    expect(prefs.getStringList(AppConstants.dplPermissionsKey), isNull);
    expect(prefs.getString(AppConstants.dplSyncOutboxKey), '[{"txn_id":"HHT-1-7","seq":7}]');
    expect(prefs.getInt(AppConstants.dplSyncNextSeqKey), 8);
    expect(prefs.getString(AppConstants.dplDeviceIdKey), 'HHT-abc123');
    expect(prefs.getString(AppConstants.dplLanguageKey), 'mr');
  });
}
