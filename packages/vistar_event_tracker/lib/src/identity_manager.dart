import 'dart:convert';

import 'storage.dart';
import 'uuid.dart';

/// Owns the stable `anonymous_id` (persisted for the device/browser lifetime)
/// plus the current `user_id` and traits set via identify().
class IdentityManager {
  IdentityManager(this._store);
  final KeyValueStore _store;

  static const _kAnon = 'vet_anonymous_id';
  static const _kUser = 'vet_user_id';
  static const _kTraits = 'vet_traits';

  String _anonymousId = '';
  String? _userId;
  Map<String, dynamic> _traits = {};

  String get anonymousId => _anonymousId;
  String? get userId => _userId;
  Map<String, dynamic> get traits => Map.unmodifiable(_traits);

  /// Load (or lazily create) the persisted identity.
  Future<void> load() async {
    _anonymousId = await _store.getString(_kAnon) ?? '';
    if (_anonymousId.isEmpty) {
      _anonymousId = uuidV4();
      await _store.setString(_kAnon, _anonymousId);
    }
    _userId = await _store.getString(_kUser);
    final t = await _store.getString(_kTraits);
    if (t != null) {
      try {
        _traits = (jsonDecode(t) as Map).cast<String, dynamic>();
      } catch (_) {
        _traits = {};
      }
    }
  }

  Future<void> identify(String userId, [Map<String, dynamic>? traits]) async {
    _userId = userId;
    await _store.setString(_kUser, userId);
    if (traits != null) {
      _traits = {..._traits, ...traits};
      await _store.setString(_kTraits, jsonEncode(_traits));
    }
  }

  /// Logout: forget the user AND mint a fresh anonymous_id so the next
  /// anonymous session isn't linked to the previous user (privacy).
  Future<void> reset() async {
    _userId = null;
    _traits = {};
    _anonymousId = uuidV4();
    await _store.remove(_kUser);
    await _store.remove(_kTraits);
    await _store.setString(_kAnon, _anonymousId);
  }
}
