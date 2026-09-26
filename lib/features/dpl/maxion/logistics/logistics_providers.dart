import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../models/dpl_customer_return.dart';
import '../../models/dpl_logistics.dart';

/// Providers for the Maxion logistics screens (backend API.md §8.1–8.5).
///
/// Every provider yields the raw [DplApiResponse] rather than throwing, so the
/// screens can tell a refusal with a code (NOTHING_TO_SHIP, FORBIDDEN) apart
/// from a network failure and show each the way the floor needs it.

/// Shipment details for one trip (§8.2).
final tripShipmentProvider =
    FutureProvider.autoDispose.family<DplApiResponse<DplTripShipment>, int>(
  (ref, tripId) => ref.watch(dplApiServiceProvider).getTripShipment(tripId),
);

/// Active transporters for the shipment form's dropdown (§8.1).
final logisticsTransportersProvider =
    FutureProvider.autoDispose<DplApiResponse<List<DplTransporter>>>(
  (ref) => ref.watch(dplApiServiceProvider).listTransporters(),
);

/// Active consignees for the shipment form and new-return dialog (§8.1).
final logisticsConsigneesProvider =
    FutureProvider.autoDispose<DplApiResponse<List<DplConsignee>>>(
  (ref) => ref.watch(dplApiServiceProvider).listConsignees(),
);

/// The gate pass / delivery challan for one trip (§8.3).
final gatePassProvider =
    FutureProvider.autoDispose.family<DplApiResponse<DplGatePass>, int>(
  (ref, tripId) => ref.watch(dplApiServiceProvider).getGatePass(tripId),
);

/// Reversal requests waiting for a manager (§8.4).
final pendingReversalsProvider =
    FutureProvider.autoDispose<DplApiResponse<List<DplSlipReversal>>>(
  (ref) => ref.watch(dplApiServiceProvider).listPendingReversals(),
);

/// Which returns the list shows: `open` or `closed`.
final customerReturnsStatusProvider =
    NotifierProvider.autoDispose<CustomerReturnsStatus, String>(
  CustomerReturnsStatus.new,
);

class CustomerReturnsStatus extends Notifier<String> {
  @override
  String build() => 'open';

  void set(String status) => state = status;
}

/// Customer returns in the chosen status (§8.5).
final customerReturnsProvider =
    FutureProvider.autoDispose<DplApiResponse<List<DplCustomerReturn>>>((ref) {
  final status = ref.watch(customerReturnsStatusProvider);
  return ref.watch(dplApiServiceProvider).listReturns(status: status);
});

/// One return with its lines and totals (§8.5).
final customerReturnProvider =
    FutureProvider.autoDispose.family<DplApiResponse<DplCustomerReturn>, int>(
  (ref, id) => ref.watch(dplApiServiceProvider).getReturn(id),
);
