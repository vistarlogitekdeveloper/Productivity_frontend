import 'package:shared_preferences/shared_preferences.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../core/constants/app_constants.dart';

part 'local_storage_repository.g.dart';

class LocalStorageRepository {
  final SharedPreferences _prefs;

  LocalStorageRepository(this._prefs);

  Future<void> saveToken(String token) async {
    await _prefs.setString(AppConstants.tokenKey, token);
  }

  String? getToken() {
    return _prefs.getString(AppConstants.tokenKey);
  }

  Future<void> removeToken() async {
    await _prefs.remove(AppConstants.tokenKey);
  }
  
  Future<void> saveUserRole(String role) async {
    await _prefs.setString(AppConstants.userRoleKey, role);
  }
  
  String? getUserRole() {
    return _prefs.getString(AppConstants.userRoleKey);
  }

  Future<void> saveUserId(String userId) async {
    await _prefs.setString(AppConstants.userIdKey, userId);
  }

  String? getUserId() {
    return _prefs.getString(AppConstants.userIdKey);
  }

  Future<void> saveUsername(String username) async {
    await _prefs.setString(AppConstants.usernameKey, username);
  }

  String? getUsername() {
    return _prefs.getString(AppConstants.usernameKey);
  }

  Future<void> saveUserName(String name) async {
    await _prefs.setString(AppConstants.userNameKey, name);
  }

  String? getUserName() {
    return _prefs.getString(AppConstants.userNameKey);
  }

  Future<void> saveUserSession({
    required String userId,
    required String username,
    required String name,
    required String role,
  }) async {
    await Future.wait([
      saveUserId(userId),
      saveUsername(username),
      saveUserName(name),
      saveUserRole(role),
    ]);
  }

  // ------------------------------------------------------------
  // DPL active-organization snapshot
  // ------------------------------------------------------------

  Future<void> saveDplOrganization({
    required int id,
    required String code,
    required String name,
  }) async {
    await Future.wait([
      _prefs.setInt(AppConstants.dplOrgIdKey, id),
      _prefs.setString(AppConstants.dplOrgCodeKey, code),
      _prefs.setString(AppConstants.dplOrgNameKey, name),
    ]);
  }

  /// `(id, code, name)` of the active DPL org if one is stored, else
  /// `null`. Used to re-hydrate the AppBar tenant pill on app start.
  ({int id, String code, String name})? getDplOrganization() {
    final id = _prefs.getInt(AppConstants.dplOrgIdKey);
    if (id == null) return null;
    return (
      id: id,
      code: _prefs.getString(AppConstants.dplOrgCodeKey) ?? '',
      name: _prefs.getString(AppConstants.dplOrgNameKey) ?? '',
    );
  }

  Future<void> clearDplOrganization() async {
    await Future.wait([
      _prefs.remove(AppConstants.dplOrgIdKey),
      _prefs.remove(AppConstants.dplOrgCodeKey),
      _prefs.remove(AppConstants.dplOrgNameKey),
    ]);
  }

  // ------------------------------------------------------------
  // DPL permission snapshot (backend migration 148)
  //
  // What the logged-in user is allowed to do, as granted permission keys.
  // Cached so a screen can decide what to show on the first frame instead of
  // flashing a control and then withdrawing it. The server re-checks every
  // request, so a stale snapshot can only ever hide something.
  // ------------------------------------------------------------

  Future<void> saveDplPermissions(List<String> keys) async {
    await _prefs.setStringList(AppConstants.dplPermissionsKey, keys);
  }

  /// The cached permission keys, or `null` when none were ever stored.
  ///
  /// `null` and `[]` mean different things and the caller must not conflate
  /// them: `null` is "this session predates permissions, fall back to the
  /// role checks", `[]` is "the server said this person may do nothing".
  List<String>? getDplPermissions() =>
      _prefs.getStringList(AppConstants.dplPermissionsKey);

  Future<void> clearDplPermissions() async {
    await _prefs.remove(AppConstants.dplPermissionsKey);
  }

  // ------------------------------------------------------------
  // "This account is still on a password somebody else chose"
  //
  // Persisted so a page refresh cannot walk past the forced change. It is a
  // convenience, not the guarantee — the backend re-reports the flag on every
  // /auth/me, so clearing local storage only costs the user one round trip.
  // ------------------------------------------------------------

  Future<void> saveDplMustChangePassword(bool value) async {
    await _prefs.setBool(AppConstants.dplMustChangePasswordKey, value);
  }

  bool getDplMustChangePassword() =>
      _prefs.getBool(AppConstants.dplMustChangePasswordKey) ?? false;

  Future<void> clearDplMustChangePassword() async {
    await _prefs.remove(AppConstants.dplMustChangePasswordKey);
  }

  Future<void> clearAll() async {
    await _prefs.clear();
  }
}

@riverpod
Future<SharedPreferences> sharedPreferences(Ref ref) async {
  return await SharedPreferences.getInstance();
}

@riverpod
LocalStorageRepository localStorageRepository(Ref ref) {
  final prefs = ref.watch(sharedPreferencesProvider).requireValue;
  return LocalStorageRepository(prefs);
}
