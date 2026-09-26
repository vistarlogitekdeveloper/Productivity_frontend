import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../models/dpl_stock_control.dart';

/// Data for the stock-control screens (backend API.md §10.2, §10.3).
///
/// Every provider returns the [DplApiResponse] itself rather than throwing, so
/// a screen branches on `res.isError` and keeps the server's message (and its
/// Marathi / Hindi line) intact.

/// Rack counts, newest first; null status means all.
final dplRackCountsProvider =
    FutureProvider.autoDispose.family<DplApiResponse<List<Map<String, dynamic>>>, String?>((ref, status) {
  return ref.watch(dplApiServiceProvider).listRackCounts(status: status);
});

/// One rack count. Blind (found pallets only) while open.
final dplRackCountProvider = FutureProvider.autoDispose.family<DplApiResponse<DplRackCount>, int>((ref, id) {
  return ref.watch(dplApiServiceProvider).getRackCount(id);
});

/// Stock adjustments; null status means all.
final dplStockAdjustmentsProvider =
    FutureProvider.autoDispose.family<DplApiResponse<List<DplStockAdjustment>>, String?>((ref, status) {
  return ref.watch(dplApiServiceProvider).listStockAdjustments(status: status);
});

/// Unlabelled lot stock with something left.
final dplStockLotsProvider = FutureProvider.autoDispose<DplApiResponse<List<DplStockLot>>>((ref) {
  return ref.watch(dplApiServiceProvider).listStockLots();
});

/// The adjustment reason codes.
final dplStockReasonsProvider = FutureProvider.autoDispose<DplApiResponse<List<({String code, String label})>>>((ref) {
  return ref.watch(dplApiServiceProvider).listStockReasons();
});

/// Builds the body of `POST /stock/adjustments` for a lot (API.md §10.2).
Map<String, dynamic> dplLotAdjustmentBody({
  required int lotId,
  required String direction,
  required int qty,
  required String reasonCode,
  required String note,
}) =>
    {
      'kind': 'lot',
      'lot_id': lotId,
      'direction': direction,
      'qty': qty,
      'reason_code': reasonCode,
      'note': note.trim(),
    };

/// Builds the body of `POST /stock/adjustments` writing off labelled wheels.
Map<String, dynamic> dplWheelWriteOffBody({
  required List<String> codes,
  required String reasonCode,
  required String note,
}) =>
    {
      'kind': 'wheels',
      'codes': codes.map((c) => c.trim()).where((c) => c.isNotEmpty).toSet().toList(),
      'reason_code': reasonCode,
      'note': note.trim(),
    };
