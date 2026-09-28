import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_format.dart';
import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_dispatch_calculator.dart';
import '../../models/dpl_dispatch_plan_inputs.dart';

/// Plant currently selected on the Today's Dispatch Plan screen.
/// Pre-filled to the first plant the user has access to once the
/// plants list lands.
final dplDispatchPlanPlantProvider =
    NotifierProvider<DplDispatchPlanPlantController, String?>(
  DplDispatchPlanPlantController.new,
);

class DplDispatchPlanPlantController extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? plantCode) => state = plantCode;
}

/// Date currently shown on the Today's Dispatch Plan screen.
/// Defaults to today — the IST calendar day, matching the customer
/// snapshots it reads. Manager can flip to yesterday for retro view.
final dplDispatchPlanDateProvider =
    NotifierProvider<DplDispatchPlanDateController, DateTime>(
  DplDispatchPlanDateController.new,
);

class DplDispatchPlanDateController extends Notifier<DateTime> {
  @override
  DateTime build() => DplFormat.calendarDay();

  void set(DateTime date) {
    state = DateTime(date.year, date.month, date.day);
  }
}

/// Raw `GET /manager/dispatch-plan/inputs` response for the selected
/// plant + date. Re-fetches whenever either changes.
///
/// Returns null when the plant isn't picked yet (screen renders an
/// empty-state prompt in that case).
final dplDispatchPlanInputsProvider = FutureProvider.autoDispose<
    DplApiResponse<DplDispatchPlanInputsPage>?>((ref) async {
  final plantCode = ref.watch(dplDispatchPlanPlantProvider);
  final date = ref.watch(dplDispatchPlanDateProvider);
  if (plantCode == null || plantCode.trim().isEmpty) return null;
  return ref
      .watch(dplApiServiceProvider)
      .getDispatchPlanInputs(plantCode: plantCode, date: date);
});

/// Roll-up holder for the Today's Plan screen: the calculator batch
/// (run only on rows that are ready) plus the raw inputs page so the
/// UI can surface blocked-row warnings alongside the calculated rows.
class DispatchPlanComputed {
  final DplDispatchPlanInputsPage page;
  final DispatchCalcBatch batch;

  const DispatchPlanComputed({required this.page, required this.batch});

  /// True when at least one part is blocked by a missing-input warning.
  bool get hasBlockedParts => page.blockedParts.isNotEmpty;
}

/// Final computed plan = response.parts → calculator. Surfaces both the
/// raw page and the calculated batch in one type so consumers don't
/// have to thread two providers.
final dplDispatchPlanComputedProvider =
    Provider.autoDispose<AsyncValue<DispatchPlanComputed?>>((ref) {
  final asyncRes = ref.watch(dplDispatchPlanInputsProvider);
  return asyncRes.whenData<DispatchPlanComputed?>((res) {
    if (res == null) return null;
    final page = res.data;
    if (page == null) return null;
    final readyInputs =
        page.readyParts.map((p) => p.toCalcInput()).toList(growable: false);
    final batch = DplDispatchCalculator.calculateBatch(
      planDate: page.date,
      inputs: readyInputs,
    );
    return DispatchPlanComputed(page: page, batch: batch);
  });
});
