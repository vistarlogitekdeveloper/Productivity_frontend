import 'package:shared_preferences/shared_preferences.dart';

/// Minimal async key/value store the SDK persists through. Abstracted so tests
/// (and non-Flutter hosts) can swap in an in-memory implementation instead of
/// the platform's shared_preferences.
abstract class KeyValueStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// Default store backed by shared_preferences (localStorage on web, native
/// prefs on mobile/desktop).
class SharedPreferencesStore implements KeyValueStore {
  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async => _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<String?> getString(String key) async => (await _p).getString(key);

  @override
  Future<void> setString(String key, String value) async => (await _p).setString(key, value);

  @override
  Future<void> remove(String key) async => (await _p).remove(key);
}

/// In-memory store for tests / ephemeral use.
class InMemoryStore implements KeyValueStore {
  final Map<String, String> _m = {};

  @override
  Future<String?> getString(String key) async => _m[key];

  @override
  Future<void> setString(String key, String value) async => _m[key] = value;

  @override
  Future<void> remove(String key) async => _m.remove(key);
}
