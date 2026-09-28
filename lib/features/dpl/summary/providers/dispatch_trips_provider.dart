import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_format.dart';
import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../models/dpl_dispatch_trip.dart';

/// Open + partial trips for today, optionally narrowed by plant code.
///
/// Used by the dispatch landing screen to surface "ready to slip"
/// work to dispatchers. The `family` parameter lets the same provider
/// serve both the global landing (no plant filter) and per-plant
/// drill-ins.
///
/// "Today" is the IST calendar day, passed explicitly: the backend's
/// default is the 07:00 business day, which hid a trip planned for
/// today after midnight until 07:00. Before 07:00 yesterday's trips are
/// fetched too — Shift C may still be loading them, and they stay open
/// until the 04:00 expiry job cancels them.
final dplOpenTripsProvider = FutureProvider.autoDispose
    .family<DplApiResponse<DplTripListResponse>, String?>(
  (ref, plantCode) async {
    final svc = ref.watch(dplApiServiceProvider);
    Future<DplApiResponse<DplTripListResponse>> load(DateTime date) =>
        svc.listTrips(
          statuses: const [DplTripStatus.open, DplTripStatus.partial],
          plantCode: plantCode,
          date: date,
        );

    final now = DateTime.now();
    final today = DplFormat.calendarDay(now);
    if (!DplFormat.isBeforeBusinessDayCutover(now)) return load(today);

    final res = await Future.wait([
      load(DateTime(today.year, today.month, today.day - 1)),
      load(today),
    ]);
    final failed = res.where((r) => r.isError);
    if (failed.isNotEmpty) return failed.first;
    // Yesterday's first: they expire at 04:00, today's can wait.
    final trips = [for (final r in res) ...?r.data?.trips];
    return DplApiResponse.ok(DplTripListResponse(
      trips: trips,
      total: res.fold<int>(0, (s, r) => s + (r.data?.total ?? 0)),
      limit: trips.length,
    ));
  },
);

/// Toggle that drives the "My trips only" switch on the manager's
/// Today's trips card. `false` (default) loads every trip on the org
/// for today's business day; `true` adds `?submitted_by=me` so the
/// list narrows to what the calling manager submitted.
class DplManagerTripsMineOnlyNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
  void toggle() => state = !state;
}

final dplManagerTripsMineOnlyProvider = NotifierProvider.autoDispose<
    DplManagerTripsMineOnlyNotifier, bool>(
  DplManagerTripsMineOnlyNotifier.new,
);

/// IST calendar day the manager is currently *planning for* on the
/// Plan Trip screen (migration 052). Defaults to tomorrow — the
/// common case is filing tomorrow's trips today. The screen's date
/// picker writes back to this provider; the trip-list provider and
/// the `peekNextTripNumber` call both read it.
///
/// Calendar day, not business day: the day rolls over at midnight, so
/// at 01:00 on the 28th "today" is the 28th — matching the backend's
/// trip-date validation.
class DplManagerPlanForDateNotifier extends Notifier<DateTime> {
  @override
  DateTime build() {
    final today = DplFormat.calendarDay();
    return DateTime(today.year, today.month, today.day + 1);
  }

  void set(DateTime date) {
    state = DateTime(date.year, date.month, date.day);
  }
}

final dplManagerPlanForDateProvider =
    NotifierProvider<DplManagerPlanForDateNotifier, DateTime>(
  DplManagerPlanForDateNotifier.new,
);

/// EVERY trip filed under the planning date (see
/// [dplManagerPlanForDateProvider]), across every plant + every
/// status. Drives the manager's "Trips for {date}" summary card on
/// the Plan Trip screen — totals, status breakdown, and per-plant
/// chips all derive from this single payload so we don't hit the
/// backend N times.
///
/// Re-fetches whenever either the planning date or the
/// `dplManagerTripsMineOnlyProvider` flips so both are reactive.
/// `autoDispose` so the screen unmounting drops the cache; reseed via
/// `ref.invalidate(dplManagerPlanForDateTripsProvider)` after submit /
/// on refresh.
final dplManagerPlanForDateTripsProvider = FutureProvider.autoDispose<
    DplApiResponse<DplTripListResponse>>((ref) async {
  final svc = ref.watch(dplApiServiceProvider);
  final mineOnly = ref.watch(dplManagerTripsMineOnlyProvider);
  final date = ref.watch(dplManagerPlanForDateProvider);
  return svc.listTrips(
    statuses: DplTripStatus.all,
    date: date,
    submittedBy: mineOnly ? 'me' : null,
    limit: 1000,
  );
});
