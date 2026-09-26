import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/local_storage_repository.dart';
import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../models/dpl_sync.dart';

/// The signed-in DPL user's id, for stamping offline transactions.
///
/// Read from local storage, where `AuthNotifier.loginDpl` saves the profile id
/// at sign-in, so it is available with no network — which is the only time
/// the outbox needs it. Null when nobody is signed in or the stored value is
/// not a number (the Vistar Workspace account); the outbox then sends 0 and
/// the server attributes the transaction to whoever pushes it.
final dplCurrentUserIdProvider = Provider<int?>((ref) {
  try {
    final raw = ref.watch(localStorageRepositoryProvider).getUserId();
    return raw == null ? null : int.tryParse(raw);
  } catch (_) {
    // Preferences not loaded yet (only possible outside the app's normal
    // start-up, which overrides them before the first frame).
    return null;
  }
});

/// Transactions the server refused on replay, waiting on a supervisor.
final dplSyncConflictsProvider = FutureProvider.autoDispose<DplApiResponse<List<DplSyncConflict>>>((ref) {
  return ref.watch(dplApiServiceProvider).listSyncConflicts();
});

/// Every handheld that has pushed, with its queue counts.
final dplSyncDevicesProvider = FutureProvider.autoDispose<DplApiResponse<List<Map<String, dynamic>>>>((ref) {
  return ref.watch(dplApiServiceProvider).listSyncDevices();
});
