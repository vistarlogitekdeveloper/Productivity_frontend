import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_constants.dart';
import '../../models/dpl_dispatch_slip.dart';
import '../../models/dpl_production_summary.dart';
import '../../models/dpl_trip_label_scan.dart';

/// Filter applied to the Plan Trip rollup banner (Today's production /
/// Total produced / Total dispatched).
///
/// `machineId == null` ⇒ aggregate across every machine in the plant.
/// `plantCode == null` ⇒ aggregate across every plant the caller can see.
/// `from == null && to == null` ⇒ all-time (till date).
class DplPlanTripRollupFilter {
  final String? plantCode;
  final int? machineId;
  final DateTime? from;
  final DateTime? to;

  const DplPlanTripRollupFilter({
    this.plantCode,
    this.machineId,
    this.from,
    this.to,
  });

  static const Object _sentinel = Object();

  DplPlanTripRollupFilter copyWith({
    Object? plantCode = _sentinel,
    Object? machineId = _sentinel,
    Object? from = _sentinel,
    Object? to = _sentinel,
  }) {
    return DplPlanTripRollupFilter(
      plantCode: identical(plantCode, _sentinel)
          ? this.plantCode
          : plantCode as String?,
      machineId: identical(machineId, _sentinel)
          ? this.machineId
          : machineId as int?,
      from: identical(from, _sentinel) ? this.from : from as DateTime?,
      to: identical(to, _sentinel) ? this.to : to as DateTime?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DplPlanTripRollupFilter &&
      other.plantCode == plantCode &&
      other.machineId == machineId &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(plantCode, machineId, from, to);
}

/// Filter state driving the rollup banner. Lives at the screen level —
/// changing plant / machine / dates re-fires the rollup providers below.
final dplPlanTripRollupFilterProvider = NotifierProvider<
    DplPlanTripRollupFilterController, DplPlanTripRollupFilter>(
  DplPlanTripRollupFilterController.new,
);

class DplPlanTripRollupFilterController
    extends Notifier<DplPlanTripRollupFilter> {
  @override
  DplPlanTripRollupFilter build() => const DplPlanTripRollupFilter();

  void set(DplPlanTripRollupFilter filter) => state = filter;

  void setPlantCode(String? code) => state = state.copyWith(plantCode: code);
  void setMachineId(int? id) => state = state.copyWith(machineId: id);
  void setRange({DateTime? from, DateTime? to}) =>
      state = state.copyWith(from: from, to: to);
  void clear() => state = const DplPlanTripRollupFilter();
}

/// Today's produced qty. Date is pinned to today regardless of the
/// banner's date range — the "Today" tile is a fixed reference point
/// the user always wants visible. Machine + plant filters still apply.
final dplPlanTripTodayProductionProvider = FutureProvider.autoDispose<
    DplApiResponse<DplProductionSummaryPage>>((ref) async {
  final f = ref.watch(dplPlanTripRollupFilterProvider);
  final today = _today();
  return ref.watch(dplApiServiceProvider).listProductionSummary(
        plantCode: f.plantCode,
        machineId: f.machineId,
        from: today,
        to: today,
        // We only consume `totals` — minimize the items[] payload.
        limit: 1,
      );
});

/// Labelled pieces per part that are still free to plan onto a trip.
///
/// Carries labelled / on-trip / free / committed / available per part, so a
/// zero allowance can be explained rather than just stated. A part ABSENT from
/// this map has nothing printed and nothing planned — a hard zero, not
/// "unknown" — so readers must default to 0 rather than to "no limit".
///
/// Advisory: `POST /dispatch/trips` re-checks the same figure under an
/// advisory lock, so a stale client value cannot over-commit labelled stock.
final dplPlanTripLabelAvailabilityProvider =
    FutureProvider.autoDispose<DplApiResponse<Map<int, DplLabelStock>>>((ref) async {
  return ref.watch(dplApiServiceProvider).getLabelAvailability();
});

/// Total produced over the selected range (defaults to all-time).
final dplPlanTripProductionRollupProvider = FutureProvider.autoDispose<
    DplApiResponse<DplProductionSummaryPage>>((ref) async {
  final f = ref.watch(dplPlanTripRollupFilterProvider);
  return ref.watch(dplApiServiceProvider).listProductionSummary(
        plantCode: f.plantCode,
        machineId: f.machineId,
        from: f.from,
        to: f.to,
        limit: 1,
      );
});

/// Total dispatched (qty) over the selected range. Opts into the
/// backend's `respect_filters=true` so the totals envelope honors the
/// machine / part / date filters instead of returning the org-wide
/// inbox-tab badge counts.
final dplPlanTripDispatchedRollupProvider = FutureProvider.autoDispose<
    DplApiResponse<DplDispatchSlipPage>>((ref) async {
  final f = ref.watch(dplPlanTripRollupFilterProvider);
  return ref.watch(dplApiServiceProvider).listDispatchSlips(
        status: DplDispatchSlipStatus.dispatched,
        machineId: f.machineId,
        from: f.from,
        to: f.to,
        limit: 1,
        respectFilters: true,
      );
});

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}
