import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../models/dpl_logistics.dart';
import '../../models/dpl_oem_dashboard.dart';
import '../../models/dpl_report_subscription.dart';
import '../../models/dpl_report_table.dart';
import '../../models/dpl_stock_control.dart';

/// Data for the manager's Maxion screens (backend phases 1–4).
///
/// Every provider returns the [DplApiResponse] itself rather than throwing, so
/// a screen branches on `res.isError` and keeps the server's message (and its
/// Marathi / Hindi line) intact.

/// Which tabular report to load and for which window. A record so Riverpod's
/// family sees two requests for the same report and dates as the same key.
typedef DplReportRequest = ({String key, String rowsKey, String? from, String? to});

final dplReportTableProvider =
    FutureProvider.autoDispose.family<DplApiResponse<DplReportTable>, DplReportRequest>((ref, req) {
  return ref.watch(dplApiServiceProvider).getReportTable(
        req.key,
        req.rowsKey,
        query: {'from': req.from, 'to': req.to},
      );
});

final dplOemDashboardProvider = FutureProvider.autoDispose<DplApiResponse<DplOemDashboard>>((ref) {
  return ref.watch(dplApiServiceProvider).getOemDashboard();
});

final dplReportSubscriptionsProvider =
    FutureProvider.autoDispose<DplApiResponse<List<DplReportSubscription>>>((ref) {
  return ref.watch(dplApiServiceProvider).listReportSubscriptions();
});

final dplTransportersProvider = FutureProvider.autoDispose<DplApiResponse<List<DplTransporter>>>((ref) {
  return ref.watch(dplApiServiceProvider).listTransporters(includeInactive: true);
});

final dplConsigneesProvider = FutureProvider.autoDispose<DplApiResponse<List<DplConsignee>>>((ref) {
  return ref.watch(dplApiServiceProvider).listConsignees(includeInactive: true);
});

final dplLanesProvider = FutureProvider.autoDispose<DplApiResponse<List<DplLane>>>((ref) {
  return ref.watch(dplApiServiceProvider).listLanes();
});

final dplStockLotsProvider = FutureProvider.autoDispose<DplApiResponse<List<DplStockLot>>>((ref) {
  return ref.watch(dplApiServiceProvider).listStockLots();
});
