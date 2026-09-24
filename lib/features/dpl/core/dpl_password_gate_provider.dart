import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/local_storage_repository.dart';
import 'dpl_api_service.dart';

/// Whether this account is still signed in on a password somebody else chose.
///
/// The backend sets `must_change_password` when an administrator creates an
/// account or resets its password, and clears it the moment the user sets
/// their own (see authController.changePassword). While it is true the router
/// pins the user to `/dpl/change-password`.
///
/// This is what makes the bootstrap and admin-set passwords safe to use at
/// all. Without the gate the flag is decoration, and a password an
/// administrator typed — or the built-in bootstrap value — keeps working for
/// as long as the account exists.
class DplMustChangePassword extends Notifier<bool> {
  @override
  bool build() =>
      ref.read(localStorageRepositoryProvider).getDplMustChangePassword();

  Future<void> set(bool value) async {
    state = value;
    await ref
        .read(localStorageRepositoryProvider)
        .saveDplMustChangePassword(value);
  }

  Future<void> clear() async {
    state = false;
    await ref.read(localStorageRepositoryProvider).clearDplMustChangePassword();
  }

  /// Re-read from `/auth/me`.
  ///
  /// On a network error the flag is left exactly as it was rather than being
  /// cleared. Clearing on failure would let an unreachable backend unlock the
  /// gate, which is the one outcome that must not be possible.
  Future<void> refresh() async {
    final res = await ref.read(dplApiServiceProvider).me();
    if (res.isError) return;
    await set(res.data?.mustChangePassword ?? false);
  }
}

final dplMustChangePasswordProvider =
    NotifierProvider<DplMustChangePassword, bool>(DplMustChangePassword.new);
