import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../models/dpl_dashboard_summary.dart';
import '../../models/dpl_location.dart';
import '../../models/dpl_part_sticker.dart';
import '../../models/dpl_shift.dart';

/// Date QA is looking at. Defaults to today.
final qaDateProvider = NotifierProvider<QaDateController, DateTime>(
  QaDateController.new,
);

class QaDateController extends Notifier<DateTime> {
  @override
  DateTime build() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  void set(DateTime date) => state = DateTime(date.year, date.month, date.day);
}

/// Which shift QA is filtered to.
///
/// The requirement is "by default he sees the production going on in THIS
/// shift", but he must still be able to look at another shift or the whole
/// day. Modelling that as a nullable shift code alone cannot distinguish
/// "follow the clock" from "the user deliberately chose All shifts", so the
/// auto flag is explicit.
class QaShiftFilter {
  /// True while the filter is still tracking whatever shift is running now.
  final bool auto;

  /// Shift code to show. `null` with [auto] false means "All shifts".
  final String? code;

  const QaShiftFilter({required this.auto, this.code});

  const QaShiftFilter.auto() : auto = true, code = null;
}

final qaShiftFilterProvider =
    NotifierProvider<QaShiftFilterController, QaShiftFilter>(
  QaShiftFilterController.new,
);

class QaShiftFilterController extends Notifier<QaShiftFilter> {
  @override
  QaShiftFilter build() => const QaShiftFilter.auto();

  /// User picked a specific shift.
  void pick(String code) => state = QaShiftFilter(auto: false, code: code);

  /// User asked for the whole day.
  void all() => state = const QaShiftFilter(auto: false, code: null);

  /// Back to following the clock.
  void followClock() => state = const QaShiftFilter.auto();
}

/// `GET /qa/current-shift` — which shift is running right now.
///
/// Resolves to `null` when the clock falls in a gap between configured shifts,
/// which is a real possibility (the backend matches an active shift window and
/// returns nothing if none covers the instant). The UI must not assume a shift
/// is always live.
final qaCurrentShiftProvider =
    FutureProvider.autoDispose<DplApiResponse<DplShift?>>((ref) async {
  return ref.watch(dplApiServiceProvider).getQaCurrentShift();
});

/// Machine-wise plan vs actual for the selected date.
///
/// This is the same `/manager/dashboard` endpoint the DPL Manager dashboard
/// renders — `dpl_qa` was added to its read-only role guard rather than given
/// a parallel endpoint, so the two views cannot drift apart.
final qaDashboardProvider =
    FutureProvider.autoDispose<DplApiResponse<DplDashboardSummary>>((ref) async {
  final date = ref.watch(qaDateProvider);
  return ref.watch(dplApiServiceProvider).getDashboard(date);
});

/// How many stickers a plan item may still have printed.
///
/// Kept `autoDispose` and invalidated after every issue so the remaining count
/// on screen is never a stale number the operator could act on.
final qaStickerSummaryProvider = FutureProvider.autoDispose
    .family<DplApiResponse<DplStickerSummary>, int>((ref, planItemId) async {
  return ref.watch(dplApiServiceProvider).getQaStickerSummary(planItemId);
});

/// Where a plan item's produced batch is stored, or `null` when nowhere.
///
/// Invalidated after every assign/release so the card never shows a rack the
/// batch has already been taken off.
final qaPlanItemLocationProvider = FutureProvider.autoDispose
    .family<DplApiResponse<DplLocationAssignment?>, int>((ref, planItemId) async {
  return ref.watch(dplApiServiceProvider).getPlanItemLocation(planItemId);
});

/// The shift code actually in effect on screen, resolving [QaShiftFilter.auto]
/// against the live shift. `null` means "show every shift".
String? effectiveShiftCode(WidgetRef ref) {
  final filter = ref.watch(qaShiftFilterProvider);
  if (!filter.auto) return filter.code;
  final current = ref.watch(qaCurrentShiftProvider).asData?.value;
  final shift = current?.data;
  return shift?.code;
}

/// Machine rows for the selected date, filtered to [shiftCode] when given.
///
/// The dashboard returns one bucket per (plan, effective shift), so filtering
/// to a single shift already yields one row per machine — no multi-shift
/// merging is needed here, unlike the Manager dashboard which shows the whole
/// day at once.
List<DplMachineSummary> filterMachines(
  List<DplMachineSummary> rows,
  String? shiftCode,
) {
  if (shiftCode == null || shiftCode.isEmpty) return rows;
  final want = shiftCode.trim().toUpperCase();
  return rows
      .where((m) => m.shiftCode.trim().toUpperCase() == want)
      .toList(growable: false);
}
