import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_format.dart';
import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../models/dpl_customer_snapshot.dart';

/// Plant currently being edited on the Morning Stock Update screen.
/// Pre-fills from whatever plant the Today's Plan screen had open so
/// the manager can flip between the two screens without re-picking.
final dplCustomerSnapshotPlantProvider =
    NotifierProvider<DplCustomerSnapshotPlantController, String?>(
  DplCustomerSnapshotPlantController.new,
);

class DplCustomerSnapshotPlantController extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? plantCode) => state = plantCode;
}

/// Date currently being edited. Defaults to today — the IST calendar
/// day, which is what the backend's "no future dates" check uses.
/// Manager can flip to yesterday for retro entry (backend allows up to
/// 7 days back).
final dplCustomerSnapshotDateProvider =
    NotifierProvider<DplCustomerSnapshotDateController, DateTime>(
  DplCustomerSnapshotDateController.new,
);

class DplCustomerSnapshotDateController extends Notifier<DateTime> {
  @override
  DateTime build() => DplFormat.calendarDay();

  void set(DateTime date) {
    state = DateTime(date.year, date.month, date.day);
  }
}

/// Raw `GET /manager/customer-snapshots?plant_code=...&date=...`
/// response. Re-fetches when plant or date changes, or after a save
/// invalidates the provider.
///
/// Returns null when no plant is picked — screen renders an empty-state
/// prompt in that case.
final dplCustomerSnapshotPageProvider = FutureProvider.autoDispose<
    DplApiResponse<DplCustomerSnapshotsPage>?>((ref) async {
  final plantCode = ref.watch(dplCustomerSnapshotPlantProvider);
  final date = ref.watch(dplCustomerSnapshotDateProvider);
  if (plantCode == null || plantCode.trim().isEmpty) return null;
  return ref
      .watch(dplApiServiceProvider)
      .listCustomerSnapshots(plantCode: plantCode, date: date);
});
