import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../models/dpl_pallet.dart';
import '../../models/dpl_sync.dart';
import '../../models/dpl_trip_label_scan.dart';
import 'offline_outbox.dart';

/// Scan helpers that work through a dead zone.
///
/// Each one tries the live endpoint first. Only when that fails for
/// CONNECTIVITY (`NETWORK` or `TIMEOUT`) does the scan go into the offline
/// outbox, to be replayed by the server through the very same service later
/// (API.md §12). A business refusal — wrong part, already scanned, count
/// closed — is returned to the caller as it is: queuing it would only block
/// the device on replay with the same refusal, minutes later and out of the
/// operator's sight.
///
/// Two further rules:
///   * **Order.** While anything is already queued, a new scan is queued behind
///     it (and a flush is kicked off) rather than sent live, so the server sees
///     this device's actions in the order the operator did them.
///   * **Permission.** Scans are only queued for a user holding `sync.push`.
///     Without it the push would be refused and the scan stranded on the
///     device, so the connectivity error is returned instead.

enum OfflineScanStatus {
  /// The live endpoint accepted it.
  online,

  /// Recorded in the outbox; the server will apply it on the next push.
  queued,

  /// Refused (a business rule), or offline with no way to queue it.
  refused,
}

class OfflineScanResult<T> {
  final OfflineScanStatus status;

  /// The live answer: the data on success, the refusal otherwise. For a
  /// queued scan, the connectivity error that caused the fallback (null when
  /// it was queued behind an existing backlog without being tried).
  final DplApiResponse<T>? response;

  /// The queued transaction, for [OfflineScanStatus.queued].
  final DplSyncTxn? txn;

  const OfflineScanResult._(this.status, {this.response, this.txn});

  const OfflineScanResult.online(DplApiResponse<T> res) : this._(OfflineScanStatus.online, response: res);
  const OfflineScanResult.queued(DplSyncTxn txn, {DplApiResponse<T>? cause})
      : this._(OfflineScanStatus.queued, response: cause, txn: txn);
  const OfflineScanResult.refused(DplApiResponse<T> res) : this._(OfflineScanStatus.refused, response: res);

  bool get isOnline => status == OfflineScanStatus.online;
  bool get isQueued => status == OfflineScanStatus.queued;
  bool get isRefused => status == OfflineScanStatus.refused;

  T? get data => response?.data;
}

/// True when [res] failed for connectivity, not because the server said no.
bool isOfflineResponse(DplApiResponse<dynamic> res) =>
    res.isError && (res.code == 'NETWORK' || res.code == 'TIMEOUT');

/// The rule itself, free of widgets so it can be tested with a container.
Future<OfflineScanResult<T>> runOnlineOrQueue<T>({
  required DplOfflineOutbox outbox,
  required bool canQueue,
  required String type,
  required Map<String, dynamic> payload,
  required int userId,
  required Future<DplApiResponse<T>> Function() online,
}) async {
  if (canQueue) {
    await outbox.ready();
    if (outbox.pending > 0) {
      final txn = await outbox.enqueue(type, payload, userId: userId);
      unawaited(outbox.flush());
      return OfflineScanResult<T>.queued(txn);
    }
  }
  final res = await online();
  if (res.isOk) return OfflineScanResult<T>.online(res);
  if (!canQueue || !isOfflineResponse(res)) return OfflineScanResult<T>.refused(res);
  final txn = await outbox.enqueue(type, payload, userId: userId);
  return OfflineScanResult<T>.queued(txn, cause: res);
}

Future<OfflineScanResult<T>> _viaRef<T>(
  WidgetRef ref, {
  required String type,
  required Map<String, dynamic> payload,
  required int userId,
  required Future<DplApiResponse<T>> Function(DplApiService api) online,
}) {
  final api = ref.read(dplApiServiceProvider);
  return runOnlineOrQueue<T>(
    outbox: ref.read(dplOfflineOutboxProvider.notifier),
    canQueue: ref.read(dplPermissionsProvider).can(DplPermission.syncPush),
    type: type,
    payload: payload,
    userId: userId,
    online: () => online(api),
  );
}

/// Load one label onto a trip (`trip.scan`).
Future<OfflineScanResult<DplTripScanProgress>> scanToTripOrQueue(
  WidgetRef ref, {
  required int tripId,
  required String code,
  required int userId,
}) =>
    _viaRef(ref,
        type: 'trip.scan',
        payload: {'trip_id': tripId, 'code': code},
        userId: userId,
        online: (api) => api.scanLabelToTrip(tripId: tripId, code: code));

/// Put one wheel on an open pallet (`pallet.scan`).
Future<OfflineScanResult<DplPallet>> scanToPalletOrQueue(
  WidgetRef ref, {
  required int palletId,
  required String code,
  required int userId,
}) =>
    _viaRef(ref,
        type: 'pallet.scan',
        payload: {'pallet_id': palletId, 'code': code},
        userId: userId,
        online: (api) => api.scanWheelOntoPallet(palletId: palletId, code: code));

/// Record a pallet found on a rack during a blind count (`count.scan`).
Future<OfflineScanResult<Map<String, dynamic>>> scanCountOrQueue(
  WidgetRef ref, {
  required int countId,
  required int locationId,
  required String code,
  required int userId,
}) =>
    _viaRef(ref,
        type: 'count.scan',
        payload: {'count_id': countId, 'code': code, 'location_id': locationId},
        userId: userId,
        online: (api) => api.scanRackCount(countId, code: code, locationId: locationId));
