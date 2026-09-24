import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/dpl_format.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_feature_flags.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_refresh_icon_button.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_dispatch_trip.dart';
import '../../models/dpl_part_field.dart';
import '../../models/dpl_plant.dart';
import '../../models/dpl_trip_label_scan.dart';
import '../../summary/providers/dispatch_trips_provider.dart';
import '../../summary/providers/plants_provider.dart';
import '../providers/dpl_part_field_provider.dart';
import '../providers/dpl_plan_trip_rollup_provider.dart';
import '../widgets/dpl_plan_trip_rollup_card.dart';
import '../widgets/error_retry.dart';

/// Manager-driven trip planning.
///
/// Each TRIP represents a physical truck movement from the plant to a
/// customer. A trip can carry up to [_maxPlansPerTrip] line items — one
/// per part to dispatch. For each line item the manager picks a plant
/// → machine → part triple; the suggested qty is the daily-dispatch
/// formula output `(stocking_norm + customer_today_plan) − customer_opening_stock`
/// and stays editable so the manager can override (partial loads,
/// shortage carryover, etc.).
///
/// State is kept entirely on the screen — there is no backend
/// `/trips` endpoint yet. A save action would simply POST this
/// snapshot once the API lands.
class PlanTripScreen extends ConsumerStatefulWidget {
  const PlanTripScreen({super.key});

  @override
  ConsumerState<PlanTripScreen> createState() => _PlanTripScreenState();
}

const int _maxPlansPerTrip = 8;

class _PlanTripScreenState extends ConsumerState<PlanTripScreen> {
  /// Local trips draft. Survives provider rebuilds because it lives on
  /// the State, but is *not* persisted — leaving the screen drops it.
  /// Saving to backend will need a new endpoint.
  final List<_TripDraft> _trips = [];

  @override
  Widget build(BuildContext context) {
    final norms = ref.watch(
      dplPartFieldPageProvider(DplPartFieldKind.stockingNorm),
    );
    final stocks = ref.watch(
      dplPartFieldPageProvider(DplPartFieldKind.customerOpeningStock),
    );
    final plans = ref.watch(
      dplPartFieldPageProvider(DplPartFieldKind.customerTodayPlan),
    );
    // Packaging qty is treated as OPTIONAL — we watch it for the
    // "Pack: N NOS" hint on each plan row, but the screen still
    // renders even if the fetch errors or is still loading. Plans
    // simply won't show the hint until the data lands.
    final packaging = ref.watch(
      dplPartFieldPageProvider(DplPartFieldKind.packagingQty),
    );
    final plantsAsync = ref.watch(dplPlantsProvider);

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Plan Trip',
        actions: [
          DplRefreshIconButton(
            onRefresh: () async {
              for (final k in DplPartFieldKind.values) {
                ref.invalidate(dplPartFieldPageProvider(k));
              }
              ref.invalidate(dplPlantsProvider);
              ref.invalidate(dplManagerPlanForDateTripsProvider);
              ref.invalidate(dplPlanTripTodayProductionProvider);
              ref.invalidate(dplPlanTripProductionRollupProvider);
              ref.invalidate(dplPlanTripDispatchedRollupProvider);
              // Labelled stock moves as QA prints and as other managers plan
              // trips, so a refresh must re-read it or the caps go stale.
              ref.invalidate(dplPlanTripLabelAvailabilityProvider);
              // Also re-resolve trip_numbers for every draft whose
              // plant is set, so a refresh re-aligns with whatever
              // other managers may have submitted in the meantime.
              await _refreshAllTripNumbers();
            },
          ),
        ],
      ),
      body: _buildBody(norms, stocks, plans, packaging, plantsAsync),
      bottomNavigationBar: _SubmitBar(
        trips: _trips,
        submitting: _submitting,
        onSubmit: _onSubmit,
      ),
    );
  }

  bool _submitting = false;

  /// Validate the draft, then POST each trip sequentially. We don't
  /// batch because the brief defines `POST /dispatch/trips` as one
  /// trip per call, and the backend assigns `trip_number` per call —
  /// firing them in parallel would race the number allocator.
  ///
  /// On a per-trip failure we stop, surface which trip broke, and
  /// LEAVE successfully-submitted trips out of the draft so the user
  /// can fix and retry only the failed ones (no double-submission).
  Future<void> _onSubmit() async {
    final validation = _validateTrips();
    if (validation != null) {
      DplSnacks.error(context, validation);
      return;
    }

    final plants =
        ref.read(dplPlantsProvider).asData?.value.data ?? const <DplPlant>[];
    final suggestedByPartId = _computeSuggestedByPartId();

    // Resolve every plan's machine_id once up-front. If any plan's
    // machineName doesn't resolve, surface that BEFORE we POST so we
    // never leave the user with a half-submitted batch.
    final byTripPlans = <_TripDraft, List<DplTripCreatePlan>>{};
    for (final t in _trips) {
      final plant = plants.firstWhere(
        (p) => p.code == t.plantCode,
        orElse: () => const DplPlant(code: '', name: ''),
      );
      if (plant.code.isEmpty) {
        DplSnacks.error(
          context,
          '${_tripLabel(t)}: plant "${t.plantCode}" not found. Refresh '
          'and try again.',
        );
        return;
      }
      final planRows = <DplTripCreatePlan>[];
      for (var i = 0; i < t.plans.length; i++) {
        final p = t.plans[i];
        final machine = plant.machines.firstWhere(
          (m) => m.name.toLowerCase() == (p.machineName ?? '').toLowerCase(),
          orElse: () => const DplPlantMachine(id: 0),
        );
        if (machine.id == 0) {
          DplSnacks.error(
            context,
            '${_tripLabel(t)} · Plan ${i + 1}: machine "${p.machineName}" '
            'no longer in plant. Re-pick and retry.',
          );
          return;
        }
        planRows.add(DplTripCreatePlan(
          machineId: machine.id,
          partId: p.partId!,
          qty: p.qty,
          suggestedQty: suggestedByPartId[p.partId!],
        ));
      }
      byTripPlans[t] = planRows;
    }

    setState(() => _submitting = true);
    final api = ref.read(dplApiServiceProvider);
    final planForDate = ref.read(dplManagerPlanForDateProvider);

    var submittedCount = 0;
    var submittedQty = 0;
    // Iterate over a copy so we can mutate _trips as each one
    // succeeds without ConcurrentModification.
    for (final t in [..._trips]) {
      final body = DplTripCreateRequest(
        plantCode: t.plantCode!,
        date: planForDate,
        plans: byTripPlans[t]!,
      );
      final res = await api.createTrip(body);
      if (!mounted) return;

      if (res.isError) {
        // Trips that succeeded earlier in this loop have already
        // been removed from _trips (per-iteration mutation). The
        // remaining ones — the current trip + the rest — stay so the
        // manager can fix and retry just those.
        setState(() => _submitting = false);
        DplSnacks.error(
          context,
          '${_tripLabel(t)} failed: ${res.error ?? "unknown error"}',
        );
        return;
      }

      submittedCount++;
      submittedQty += t.plans.fold<int>(0, (s, p) => s + p.qty);
      setState(() => _trips.remove(t));
    }

    // Block on the seed so the next "Add Trip" reflects the
    // server-of-record count BEFORE the user can click it.
    // Re-resolve the trip numbers for any drafts whose plant matches
    // a just-submitted one. The backend has incremented its per-plant
    // counter; without this, a second draft for the same plant would
    // re-use the number we showed pre-submit.
    ref.invalidate(dplManagerPlanForDateTripsProvider);
    // A submitted trip consumes labelled stock, so the caps on any remaining
    // draft rows are now stale. Without this, a second draft for the same part
    // would still show the pre-submit allowance.
    ref.invalidate(dplPlanTripLabelAvailabilityProvider);
    await _refreshAllTripNumbers();
    if (!mounted) return;
    setState(() => _submitting = false);
    DplSnacks.success(
      context,
      'Submitted $submittedCount trip${submittedCount == 1 ? "" : "s"} '
      '· $submittedQty NOS.',
    );
  }

  /// Resolve the next [trip_number] the backend will assign for
  /// [plantCode] + today's business day.
  ///
  /// Uses `GET /dispatch/trips/next-number?plant_code=…` for the
  /// backend-side preview (single SELECT — much cheaper than the
  /// listTrips paging workaround it replaced), then offsets by the
  /// count of any *other* local drafts pointing at the same plant so
  /// the second + third drafts on a plant show N+1, N+2 instead of
  /// all collapsing to N.
  ///
  /// Returns null on network failure — the caller leaves the trip
  /// number empty and shows "New Trip" until a refresh succeeds.
  /// Note: the preview is advisory; if another user submits a trip in
  /// the same plant + IST day window the actual number may differ by
  /// ±1. The POST response is still authoritative.
  Future<int?> _resolveTripNumberForPlant(
    String plantCode, {
    _TripDraft? skipTrip,
  }) async {
    final api = ref.read(dplApiServiceProvider);
    final planForDate = ref.read(dplManagerPlanForDateProvider);
    final res = await api.peekNextTripNumber(
      plantCode: plantCode,
      date: planForDate,
    );
    if (!mounted) return null;
    if (res.isError || res.data == null) return null;
    final localSamePlantBefore = _trips
        .where((t) =>
            !identical(t, skipTrip) &&
            t.plantCode == plantCode &&
            t.number != null)
        .length;
    return res.data! + localSamePlantBefore;
  }

  /// Short, user-facing label for [t] used in snacks and validation
  /// errors. Falls back to a session-ordinal when the trip hasn't yet
  /// been resolved to a backend `trip_number` (i.e. the user hasn't
  /// picked a plant or the lookup is still in flight).
  String _tripLabel(_TripDraft t) {
    if (t.number != null) return 'Trip ${t.number}';
    final idx = _trips.indexOf(t);
    return idx >= 0 ? 'Trip draft #${idx + 1}' : 'A trip';
  }

  /// User picked a new planning date from the pill at the top. Updates
  /// the provider (drives the trips-list + the next-number preview) and
  /// re-resolves the displayed `trip_number` on every draft because the
  /// backend counter is per `(plant, date)` — the number we previewed
  /// for yesterday's date is meaningless for tomorrow's.
  Future<void> _onPlanForDateChanged(DateTime date) async {
    ref.read(dplManagerPlanForDateProvider.notifier).set(date);
    await _refreshAllTripNumbers();
  }

  /// Re-resolve the [number] for every local draft that has a plant
  /// picked. Used after a successful submit so the next click on the
  /// plant picker of any remaining draft reflects the now-incremented
  /// backend counter.
  Future<void> _refreshAllTripNumbers() async {
    for (final t in _trips) {
      final code = t.plantCode;
      if (code == null) continue;
      final n = await _resolveTripNumberForPlant(code, skipTrip: t);
      if (!mounted) return;
      if (n != null) {
        setState(() => t.number = n);
      }
    }
  }

  /// Walks the three cached master-field providers (stocking norm,
  /// customer opening stock, customer today's plan) and computes the
  /// formula suggested-qty per partId. Sent as `suggested_qty` on
  /// each plan so the backend can freeze the snapshot for variance
  /// reports. Returns an empty map if any provider hasn't loaded yet
  /// — submit still succeeds, just without the snapshot.
  Map<int, int> _computeSuggestedByPartId() {
    final norms = ref
        .read(dplPartFieldPageProvider(DplPartFieldKind.stockingNorm))
        .asData
        ?.value
        .data;
    final stocks = ref
        .read(dplPartFieldPageProvider(DplPartFieldKind.customerOpeningStock))
        .asData
        ?.value
        .data;
    final plans = ref
        .read(dplPartFieldPageProvider(DplPartFieldKind.customerTodayPlan))
        .asData
        ?.value
        .data;
    if (norms == null || stocks == null || plans == null) return const {};

    final stockingByPart = <int, int>{
      for (final e in norms.entries)
        if (e.value != null) e.partId: e.value!,
    };
    final openingByPart = <int, int>{
      for (final e in stocks.entries)
        if (e.value != null) e.partId: e.value!,
    };
    final todayByPart = <int, int>{
      for (final e in plans.entries)
        if (e.value != null) e.partId: e.value!,
    };

    final allPartIds = <int>{
      ...stockingByPart.keys,
      ...openingByPart.keys,
      ...todayByPart.keys,
    };
    final out = <int, int>{};
    for (final id in allPartIds) {
      final sn = stockingByPart[id];
      final os = openingByPart[id];
      final tp = todayByPart[id];
      if (sn == null || os == null || tp == null) continue;
      final raw = sn + tp - os;
      out[id] = raw < 0 ? 0 : raw;
    }
    return out;
  }

  /// Returns the first problem found in the trip set, or null when
  /// everything is ready to submit. Order matters — the most actionable
  /// failure is reported first so the manager doesn't fix one thing and
  /// hit submit just to get blocked again.
  String? _validateTrips() {
    if (_trips.isEmpty) {
      return 'Add at least one trip before submitting.';
    }
    for (final t in _trips) {
      if (t.plantCode == null) {
        return '${_tripLabel(t)}: pick a plant.';
      }
      if (t.plans.isEmpty) {
        return '${_tripLabel(t)} has no plans. Add a part or remove '
            'the trip.';
      }
      for (var i = 0; i < t.plans.length; i++) {
        final p = t.plans[i];
        final tag = '${_tripLabel(t)} · Plan ${i + 1}';
        if (p.machineName == null || p.machineName!.isEmpty) {
          return '$tag: pick a machine.';
        }
        if (p.partId == null) return '$tag: pick a description.';
        if (p.qty <= 0) return '$tag: qty must be greater than 0.';
      }
    }

    // Labelled-stock ceiling, re-checked across the WHOLE draft.
    //
    // The per-row formatter only guards keystrokes on one row. Two rows can
    // each be under the cap individually and still exceed it together, and
    // swapping a part after typing a qty leaves a value the formatter never
    // saw. Both are caught here.
    //
    // A part missing from the map has nothing printed — treated as 0, because
    // reading "absent" as "no limit" is the hole this rule closes.
    //
    // Skipped entirely while `enforceLabelStockOnPlan` is off. The dispatch
    // scan gate still guarantees nothing unlabelled ships, so this check only
    // governs how early the system complains, not whether it is safe.
    final labelRes = DplFeatureFlags.enforceLabelStockOnPlan
        ? ref.read(dplPlanTripLabelAvailabilityProvider).asData?.value
        : null;
    if (labelRes != null && !labelRes.isError) {
      final available = labelRes.data ?? const <int, DplLabelStock>{};
      final requested = <int, int>{};
      for (final t in _trips) {
        for (final p in t.plans) {
          if (p.partId == null) continue;
          requested[p.partId!] = (requested[p.partId!] ?? 0) + p.qty;
        }
      }
      for (final entry in requested.entries) {
        final stock = available[entry.key] ?? const DplLabelStock();
        if (entry.value > stock.availableQty) {
          final name = _partLabelForId(entry.key);
          if (stock.nothingPrinted) {
            return 'No labels have been printed for $name yet, so it cannot be '
                'planned onto a trip. Ask QA to scan and print first.';
          }
          if (stock.allLoaded) {
            return 'All ${stock.labelledQty} printed labels for $name have already '
                'been loaded onto trips. Print labels for newly produced pieces '
                'before planning more.';
          }
          return 'Only ${stock.availableQty} labelled NOS of $name are free to '
              'dispatch, but the draft asks for ${entry.value} across all trips.';
        }
      }
    }

    return null;
  }

  /// Best-effort display name for a part id, for validation messages.
  String _partLabelForId(int partId) {
    for (final t in _trips) {
      for (final p in t.plans) {
        if (p.partId == partId && (p.partLabel ?? '').isNotEmpty) {
          return p.partLabel!;
        }
      }
    }
    return 'part #$partId';
  }

  Widget _buildBody(
    AsyncValue<dynamic> norms,
    AsyncValue<dynamic> stocks,
    AsyncValue<dynamic> plans,
    AsyncValue<dynamic> packaging,
    AsyncValue<dynamic> plantsAsync,
  ) {
    if (norms.isLoading ||
        stocks.isLoading ||
        plans.isLoading ||
        plantsAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final err =
        norms.error ?? stocks.error ?? plans.error ?? plantsAsync.error;
    if (err != null) {
      return DplErrorRetry(
        message: err.toString(),
        onRetry: () {
          for (final k in DplPartFieldKind.values) {
            ref.invalidate(dplPartFieldPageProvider(k));
          }
          ref.invalidate(dplPlantsProvider);
        },
      );
    }

    final normsRes = (norms as AsyncData).value;
    final stocksRes = (stocks as AsyncData).value;
    final plansRes = (plans as AsyncData).value;
    final plantsRes = (plantsAsync as AsyncData).value;
    if (normsRes.isError ||
        stocksRes.isError ||
        plansRes.isError ||
        plantsRes.isError) {
      return DplErrorRetry(
        message: normsRes.error ??
            stocksRes.error ??
            plansRes.error ??
            plantsRes.error ??
            'Failed to load.',
        onRetry: () {
          for (final k in DplPartFieldKind.values) {
            ref.invalidate(dplPartFieldPageProvider(k));
          }
          ref.invalidate(dplPlantsProvider);
        },
      );
    }

    final DplPartFieldPage normsPage = normsRes.data!;
    final DplPartFieldPage stocksPage = stocksRes.data!;
    final DplPartFieldPage plansPage = plansRes.data!;
    final List<DplPlant> plants = plantsRes.data ?? const <DplPlant>[];

    // Packaging-qty lookup. Read defensively — the screen renders
    // even if the packaging fetch errored or is mid-flight; the hint
    // simply won't surface until the data arrives.
    final packagingPage = packaging.asData?.value;
    final packagingByPartId = <int, int>{};
    if (packagingPage != null && !packagingPage.isError) {
      for (final e in packagingPage.data?.entries ?? const []) {
        if (e.value != null) packagingByPartId[e.partId] = e.value!;
      }
    }

    // Labelled stock per part.
    //
    // THREE states, not two. "Loaded, part absent" means nothing printed and
    // is a hard zero. "Still loading" and "fetch failed" are NOT zero — they
    // are unknown, and capping the input at zero on an unknown would tell the
    // manager no labels exist when the request simply had not landed yet.
    // `labelStockLoaded` is what separates them; when it is false the row
    // leaves the qty uncapped and says so, and the server still enforces the
    // real limit on submit.
    final labelAvailAsync = ref.watch(dplPlanTripLabelAvailabilityProvider);
    final labelAvailRes = labelAvailAsync.asData?.value;
    final labelStockLoaded = labelAvailRes != null && !labelAvailRes.isError;
    final labelAvailableByPartId = labelStockLoaded
        ? (labelAvailRes.data ?? const <int, DplLabelStock>{})
        : const <int, DplLabelStock>{};

    final byPart = _joinByPart(normsPage, stocksPage, plansPage);
    final readyRows = byPart.values.where((r) => r.isReady).toList()
      ..sort((a, b) =>
          (b.dispatchQty ?? 0).compareTo(a.dispatchQty ?? 0));

    // Per-part dispatch lookup the trip rows consult when the manager
    // picks a description — drives the auto-fill.
    final dispatchByPartId = <int, int>{
      for (final r in readyRows) r.partId: r.dispatchQty ?? 0,
    };
    final partsByPartId = <int, _PartLookup>{
      for (final r in byPart.values)
        r.partId: _PartLookup(
          partId: r.partId,
          customerPn: r.customerPn,
          description: r.description,
          partName: r.partName,
          machineName: r.machineName,
        ),
    };

    final allocatedByPartId = _aggregateAllocations();
    final totalDispatch =
        readyRows.fold<int>(0, (s, r) => s + (r.dispatchQty ?? 0));
    final totalAllocated =
        allocatedByPartId.values.fold<int>(0, (s, v) => s + v);

    void addTrip() => setState(() {
          // No number until the plant is picked — at that point
          // _resolveTripNumberForPlant fires and assigns the
          // backend-aligned trip_number.
          _trips.add(_TripDraft());
        });

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 100),
      children: [
        _PlanForDatePicker(
          onDateChanged: _onPlanForDateChanged,
        ),
        const SizedBox(height: 12),
        DplPlanTripRollupCard(plants: plants),
        const SizedBox(height: 12),
        _ProductionSummaryCard(
          totalDispatch: totalDispatch,
          totalAllocated: totalAllocated,
          readyCount: readyRows.length,
          tripCount: _trips.length,
        ),
        const SizedBox(height: 12),
        const _TodaysTripsCard(),
        const SizedBox(height: 16),
        if (_trips.isEmpty)
          _NoTripsCard(onAddTrip: addTrip)
        else ...[
          Row(
            children: [
              const _SectionLabel(label: 'TRIPS'),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: DplColors.primaryTint,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${_trips.length}',
                  style: const TextStyle(
                    color: DplColors.primaryDark,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                  ),
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: addTrip,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add Trip'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final trip in _trips) ...[
            _TripCard(
              trip: trip,
              plants: plants,
              partsByPartId: partsByPartId,
              dispatchByPartId: dispatchByPartId,
              packagingByPartId: packagingByPartId,
              labelAvailableByPartId: labelAvailableByPartId,
              labelStockLoaded: labelStockLoaded,
              allocatedByPartId: allocatedByPartId,
              readyPartIds: readyRows.map((r) => r.partId).toSet(),
              onAddPlan: () => setState(() {
                if (trip.plans.length < _maxPlansPerTrip) {
                  trip.plans.add(_TripPlanDraft());
                }
              }),
              onRemoveTrip: () => setState(() => _trips.remove(trip)),
              onRemovePlan: (p) => setState(() => trip.plans.remove(p)),
              onPlanChanged: () => setState(() {}),
              onResolveTripNumber: (plantCode) async {
                final n = await _resolveTripNumberForPlant(
                  plantCode,
                  skipTrip: trip,
                );
                if (!mounted) return;
                if (n != null) setState(() => trip.number = n);
              },
            ),
            const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }

  Map<int, _JoinedRow> _joinByPart(
    DplPartFieldPage norms,
    DplPartFieldPage stocks,
    DplPartFieldPage plans,
  ) {
    final out = <int, _JoinedRow>{};
    void merge(
      DplPartFieldPage page,
      _JoinedRow Function(_JoinedRow current, int? value) update,
    ) {
      for (final e in page.entries) {
        final cur = out[e.partId] ??
            _JoinedRow(
              partId: e.partId,
              customerPn: e.customerPn,
              description: e.description,
              partName: e.partName,
              machineName: e.machineName,
            );
        out[e.partId] = update(cur, e.value);
      }
    }

    merge(norms, (c, v) => c.copyWith(stockingNorm: v));
    merge(stocks, (c, v) => c.copyWith(customerOpeningStock: v));
    merge(plans, (c, v) => c.copyWith(customerTodayPlan: v));
    return out;
  }

  /// How many NOS the manager has already allocated for each part
  /// across every trip. Drives the "X of Y allocated" hints on the
  /// availability list.
  Map<int, int> _aggregateAllocations() {
    final out = <int, int>{};
    for (final t in _trips) {
      for (final p in t.plans) {
        final pid = p.partId;
        if (pid == null) continue;
        out[pid] = (out[pid] ?? 0) + p.qty;
      }
    }
    return out;
  }
}

// ────────────── Today's trips overview ──────────────

/// Live overview of every trip the manager (and any other manager on
/// the same org) has filed under today's business day — read from
/// `dplManagerPlanForDateTripsProvider`, which calls
/// `GET /dispatch/trips?date=<businessDay>&statuses=all`. Auto-refreshes
/// on submit (the screen invalidates the provider in `_onSubmit`).
class _TodaysTripsCard extends ConsumerWidget {
  const _TodaysTripsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dplManagerPlanForDateTripsProvider);
    final mineOnly = ref.watch(dplManagerTripsMineOnlyProvider);
    final planForDate = ref.watch(dplManagerPlanForDateProvider);
    return Container(
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TodaysTripsHeader(
            mineOnly: mineOnly,
            onMineOnlyChanged: (v) => ref
                .read(dplManagerTripsMineOnlyProvider.notifier)
                .set(v),
          ),
          const SizedBox(height: 10),
          async.when(
            loading: () => const SizedBox(
              height: 80,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
            error: (e, _) => const Text(
              'Could not load today\'s trips. Pull to refresh.',
              style: TextStyle(
                color: DplColors.textSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
            data: (res) {
              if (res.isError) {
                return Text(
                  res.error ?? 'Could not load today\'s trips.',
                  style: const TextStyle(
                    color: DplColors.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                  ),
                );
              }
              final trips = res.data?.trips ?? const <DplTrip>[];
              return _TodaysTripsBody(
                trips: trips,
                mineOnly: mineOnly,
                planForDate: planForDate,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _TodaysTripsHeader extends ConsumerWidget {
  final bool mineOnly;
  final ValueChanged<bool> onMineOnlyChanged;
  const _TodaysTripsHeader({
    required this.mineOnly,
    required this.onMineOnlyChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final planForDate = ref.watch(dplManagerPlanForDateProvider);
    return Row(
      children: [
        const Icon(Icons.local_shipping_outlined,
            size: 18, color: DplColors.primaryDark),
        const SizedBox(width: 6),
        Text(_titleFor(planForDate), style: DplText.h3()),
        const Spacer(),
        // "My trips only" — flips `dplManagerTripsMineOnlyProvider`,
        // which retriggers `dplManagerPlanForDateTripsProvider` with
        // `?submitted_by=me`. Default OFF (org-wide), since the screen
        // doubles as a coordination view for multi-manager orgs.
        Text(
          'My trips only',
          style: const TextStyle(
            color: DplColors.textSecondary,
            fontWeight: FontWeight.w700,
            fontSize: 11.5,
          ),
        ),
        const SizedBox(width: 4),
        Transform.scale(
          scale: 0.75,
          child: Switch.adaptive(
            value: mineOnly,
            onChanged: onMineOnlyChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
  }

  /// Heading label that adapts to the planning date — "Today's trips"
  /// when planning for today, "Tomorrow's trips" for D+1, and an
  /// explicit "Trips for 25 Jun" for further-out dates.
  static String _titleFor(DateTime planForDate) {
    final today = DplFormat.businessDay();
    final diff = planForDate.difference(today).inDays;
    if (diff == 0) return "Today's trips";
    if (diff == 1) return "Tomorrow's trips";
    return 'Trips for ${DateFormat('d MMM').format(planForDate)}';
  }
}

class _TodaysTripsBody extends StatelessWidget {
  final List<DplTrip> trips;
  final bool mineOnly;
  final DateTime planForDate;
  const _TodaysTripsBody({
    required this.trips,
    required this.mineOnly,
    required this.planForDate,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final total = trips.length;
    final active = trips
        .where((t) =>
            t.status == DplTripStatus.open ||
            t.status == DplTripStatus.partial)
        .length;
    final fulfilled =
        trips.where((t) => t.status == DplTripStatus.fulfilled).length;
    final cancelled =
        trips.where((t) => t.status == DplTripStatus.cancelled).length;
    // Server-side rollups (backend 2026-06-18). Each trip object now
    // carries SUM(plan.qty) per status so the manager card can read
    // dispatched / slipped totals straight off without a client-side
    // walk of the plans array. Fall back to 0 if an older payload
    // omits a field.
    final totalNos =
        trips.fold<int>(0, (s, t) => s + (t.totalQty ?? 0));
    final dispatchedNos =
        trips.fold<int>(0, (s, t) => s + (t.dispatchedQty ?? 0));

    // Per-plant breakdown — count distinct plant_code → trip count.
    final byPlant = <String, _PlantTripStat>{};
    for (final t in trips) {
      final key = t.plantCode;
      final cur = byPlant[key] ??
          _PlantTripStat(plantCode: key, plantName: t.plantName);
      byPlant[key] = cur.copyAdding(t.totalQty ?? 0);
    }
    final plantRows = byPlant.values.toList()
      ..sort((a, b) => b.tripCount.compareTo(a.tripCount));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              DateFormat('EEE, dd MMM').format(planForDate),
              style: const TextStyle(
                color: DplColors.textSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (total == 0)
          Text(
            mineOnly
                ? 'You haven\'t submitted any trips yet for this date. '
                    'Switch off "My trips only" to see other managers\' '
                    'trips.'
                : 'No trips submitted yet for this date. The first '
                    'trip you submit will land here.',
            style: const TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
            ),
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: _TripStatTile(
                  label: 'Submitted',
                  value: '$total',
                  unit: total == 1 ? 'trip' : 'trips',
                  accent: DplColors.primaryDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _TripStatTile(
                  label: 'In progress',
                  value: '$active',
                  unit: active == 1 ? 'trip' : 'trips',
                  accent: DplColors.warning,
                  background: DplColors.warningBg,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _TripStatTile(
                  label: 'Fulfilled',
                  value: '$fulfilled',
                  unit: fulfilled == 1 ? 'trip' : 'trips',
                  accent: DplColors.success,
                  background: DplColors.successBg,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: DplColors.primaryTint,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${fmt.format(totalNos)} NOS planned today',
                  style: const TextStyle(
                    color: DplColors.primaryDark,
                    fontWeight: FontWeight.w800,
                    fontSize: 11.5,
                  ),
                ),
              ),
              // Server-computed `dispatched_qty` rollup — single
              // source of truth for "how much actually shipped today"
              // across every status on the trip. Hidden when 0 so the
              // chip row stays tight pre-dispatch.
              if (dispatchedNos > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: DplColors.successBg,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${fmt.format(dispatchedNos)} NOS dispatched',
                    style: const TextStyle(
                      color: DplColors.success,
                      fontWeight: FontWeight.w800,
                      fontSize: 11.5,
                    ),
                  ),
                ),
              if (cancelled > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: DplColors.errorBg,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$cancelled cancelled',
                    style: const TextStyle(
                      color: DplColors.error,
                      fontWeight: FontWeight.w800,
                      fontSize: 11.5,
                    ),
                  ),
                ),
            ],
          ),
          if (plantRows.length > 1) ...[
            const SizedBox(height: 10),
            const Divider(color: DplColors.divider, height: 1),
            const SizedBox(height: 10),
            const Text(
              'PER PLANT',
              style: TextStyle(
                color: DplColors.textSecondary,
                fontWeight: FontWeight.w800,
                fontSize: 10,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in plantRows)
                  _PlantChip(stat: p, fmt: fmt),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

class _TripStatTile extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color? accent;
  final Color? background;
  const _TripStatTile({
    required this.label,
    required this.value,
    required this.unit,
    this.accent,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: background ?? DplColors.neutralBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 4),
          RichText(
            text: TextSpan(
              style: TextStyle(
                color: accent ?? DplColors.textPrimary,
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
              children: [
                TextSpan(text: value),
                TextSpan(
                  text: '  $unit',
                  style: const TextStyle(
                    color: DplColors.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlantTripStat {
  final String plantCode;
  final String plantName;
  final int tripCount;
  final int totalQty;
  const _PlantTripStat({
    required this.plantCode,
    this.plantName = '',
    this.tripCount = 0,
    this.totalQty = 0,
  });

  _PlantTripStat copyAdding(int qty) => _PlantTripStat(
        plantCode: plantCode,
        plantName: plantName,
        tripCount: tripCount + 1,
        totalQty: totalQty + qty,
      );
}

class _PlantChip extends StatelessWidget {
  final _PlantTripStat stat;
  final NumberFormat fmt;
  const _PlantChip({required this.stat, required this.fmt});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: DplColors.neutralBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: DplColors.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.factory_rounded,
              size: 12, color: DplColors.textSecondary),
          const SizedBox(width: 5),
          Text(
            stat.plantName.isEmpty ? stat.plantCode : stat.plantName,
            style: const TextStyle(
              color: DplColors.textPrimary,
              fontWeight: FontWeight.w800,
              fontSize: 11.5,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${stat.tripCount}× · ${fmt.format(stat.totalQty)} NOS',
            style: const TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────── Production-summary header ──────────────

/// Date pill at the top of the Plan Trip body — surfaces which IST
/// business day the manager is planning for and lets them shift it via
/// the system date picker.
///
/// Defaults to tomorrow (handled in `dplManagerPlanForDateProvider`).
/// Forward window matches the backend cap: today → today+14 (mig.
/// 052's `TRIP_DATE_MAX_DAYS_AHEAD`). Past dates are blocked since the
/// backend rejects them with 400.
class _PlanForDatePicker extends ConsumerWidget {
  final ValueChanged<DateTime> onDateChanged;
  const _PlanForDatePicker({required this.onDateChanged});

  static const int _maxDaysAhead = 14;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final planForDate = ref.watch(dplManagerPlanForDateProvider);
    final today = DplFormat.businessDay();
    final diff = planForDate.difference(today).inDays;
    final relative = switch (diff) {
      0 => 'Today',
      1 => 'Tomorrow',
      -1 => 'Yesterday',
      _ => null,
    };
    final dateLabel = DateFormat('EEE, d MMM').format(planForDate);

    return Material(
      color: DplColors.primaryTint,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () => _pickDate(context, ref, today),
        borderRadius: BorderRadius.circular(14),
        splashColor: DplColors.primary.withValues(alpha: 0.08),
        highlightColor: DplColors.primary.withValues(alpha: 0.04),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: DplColors.primary, width: 1.5),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: DplColors.primary.withValues(alpha: 0.10),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: DplColors.primary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.event_outlined,
                  size: 16,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'PLANNING FOR',
                style: TextStyle(
                  color: DplColors.primaryDark,
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: 10),
              if (relative != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: DplColors.primary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    relative,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  dateLabel,
                  style: const TextStyle(
                    color: DplColors.primaryDark,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 22,
                color: DplColors.primaryDark,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickDate(
    BuildContext context,
    WidgetRef ref,
    DateTime today,
  ) async {
    final current = ref.read(dplManagerPlanForDateProvider);
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: today,
      lastDate: today.add(const Duration(days: _maxDaysAhead)),
    );
    if (picked == null) return;
    onDateChanged(DateTime(picked.year, picked.month, picked.day));
  }
}

class _ProductionSummaryCard extends StatelessWidget {
  final int totalDispatch;
  final int totalAllocated;
  final int readyCount;
  final int tripCount;
  const _ProductionSummaryCard({
    required this.totalDispatch,
    required this.totalAllocated,
    required this.readyCount,
    required this.tripCount,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final remaining = totalDispatch - totalAllocated;
    return Container(
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Today\'s production', style: DplText.h3()),
              const Spacer(),
              Text(
                DateFormat('EEE, dd MMM').format(DateTime.now()),
                style: const TextStyle(
                  color: DplColors.textSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _SummaryTile(
                  label: 'Dispatch qty',
                  value: fmt.format(totalDispatch),
                  unit: 'NOS',
                  accent: DplColors.primaryDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SummaryTile(
                  label: 'Allocated',
                  value: fmt.format(totalAllocated),
                  unit: '$tripCount trip${tripCount == 1 ? "" : "s"}',
                  accent: DplColors.info,
                  background: DplColors.infoBg,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SummaryTile(
                  label: remaining < 0 ? 'Over' : 'Remaining',
                  value: fmt.format(remaining.abs()),
                  unit: '$readyCount parts',
                  accent: remaining < 0
                      ? DplColors.error
                      : (remaining == 0
                          ? DplColors.success
                          : DplColors.warning),
                  background: remaining < 0
                      ? DplColors.errorBg
                      : (remaining == 0
                          ? DplColors.successBg
                          : DplColors.warningBg),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ────────────── Sticky submit bar ──────────────

class _SubmitBar extends StatelessWidget {
  final List<_TripDraft> trips;
  final bool submitting;
  final VoidCallback onSubmit;
  const _SubmitBar({
    required this.trips,
    required this.submitting,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final tripCount = trips.length;
    final planCount =
        trips.fold<int>(0, (s, t) => s + t.plans.length);
    final totalQty = trips.fold<int>(
      0,
      (s, t) => s + t.plans.fold<int>(0, (ss, p) => ss + p.qty),
    );

    final canSubmit = !submitting &&
        tripCount > 0 &&
        trips.every((t) =>
            t.plantCode != null &&
            t.plans.isNotEmpty &&
            t.plans.every((p) =>
                (p.machineName ?? '').isNotEmpty &&
                p.partId != null &&
                p.qty > 0));

    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: DplColors.cardBg,
          border: Border(
            top: BorderSide(color: DplColors.divider),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tripCount == 0
                        ? 'No trips yet'
                        : '$tripCount trip${tripCount == 1 ? "" : "s"} '
                            '· $planCount plan${planCount == 1 ? "" : "s"}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    canSubmit
                        ? '$totalQty NOS ready to dispatch'
                        : (tripCount == 0
                            ? 'Add a trip to submit'
                            : 'Complete every plan to submit'),
                    style: TextStyle(
                      color: canSubmit
                          ? DplColors.textSecondary
                          : DplColors.warning,
                      fontWeight: FontWeight.w700,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.icon(
              onPressed: canSubmit ? onSubmit : null,
              icon: submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.local_shipping_rounded, size: 18),
              label: Text(submitting ? 'Submitting…' : 'Submit Trip'
                  '${tripCount == 1 ? "" : "s"}'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryTile extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color? accent;
  final Color? background;
  const _SummaryTile({
    required this.label,
    required this.value,
    required this.unit,
    this.accent,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: background ?? DplColors.neutralBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 4),
          RichText(
            text: TextSpan(
              style: TextStyle(
                color: accent ?? DplColors.textPrimary,
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
              children: [
                TextSpan(text: value),
                if (unit.isNotEmpty)
                  TextSpan(
                    text: '  $unit',
                    style: const TextStyle(
                      color: DplColors.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.1,
        color: DplColors.textSecondary,
      ),
    );
  }
}

/// Replaces the old `DplEmptyState` + small "Add Trip" pill when the
/// manager hasn't started a draft yet. Renders as a tappable hero card
/// so they can hit "Start a Trip" without scrolling to find the
/// button — the previous layout pushed it below the per-part list.
class _NoTripsCard extends StatelessWidget {
  final VoidCallback onAddTrip;
  const _NoTripsCard({required this.onAddTrip});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: DplColors.cardBg,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onAddTrip,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: DplColors.primary.withValues(alpha: 0.35),
              width: 1.2,
              strokeAlign: BorderSide.strokeAlignInside,
            ),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                DplColors.primaryTint,
                Colors.white,
              ],
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: DplColors.primary.withValues(alpha: 0.25),
                  ),
                ),
                child: const Icon(
                  Icons.local_shipping_rounded,
                  color: DplColors.primaryDark,
                  size: 26,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Ready to plan a trip?', style: DplText.h3()),
                    const SizedBox(height: 4),
                    const Text(
                      'Tap here to add Trip 1. You can carry up to '
                      '$_maxPlansPerTrip parts per trip and submit '
                      'multiple trips at once.',
                      style: TextStyle(
                        color: DplColors.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: DplColors.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.add_rounded,
                        size: 18, color: Colors.white),
                    SizedBox(width: 4),
                    Text(
                      'Add Trip',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ────────────── Trip card ──────────────

class _TripCard extends StatelessWidget {
  final _TripDraft trip;
  final List<DplPlant> plants;
  final Map<int, _PartLookup> partsByPartId;
  final Map<int, int> dispatchByPartId;

  /// Per-part qty already allocated across every trip (including this
  /// one). Used by the description picker to compute the remaining
  /// suggested qty when the manager picks a part that's already
  /// partially booked.
  final Map<int, int> allocatedByPartId;

  /// Customer-supplied units per pack (e.g. 14 NOS / pack). When set
  /// for the plan's part, the row renders a "Pack: N NOS" hint next
  /// to the suggested qty and a soft amber warning if the typed qty
  /// isn't a multiple of the pack. Backend doesn't enforce — partial
  /// packs are valid for stock-short / pilot cases.
  final Map<int, int> packagingByPartId;

  /// Labelled stock per part. A part MISSING from this map has nothing
  /// printed — a hard zero, not "no limit".
  final Map<int, DplLabelStock> labelAvailableByPartId;

  /// False while the label-stock fetch is in flight or failed. Distinct from
  /// an empty map: unknown is not the same as zero.
  final bool labelStockLoaded;

  final Set<int> readyPartIds;
  final VoidCallback onAddPlan;
  final VoidCallback onRemoveTrip;
  final void Function(_TripPlanDraft) onRemovePlan;
  final VoidCallback onPlanChanged;

  /// Fires after the user picks a plant — the parent runs the
  /// per-(plant, business-day) lookup and assigns the trip's
  /// backend-aligned `trip_number`.
  final Future<void> Function(String plantCode) onResolveTripNumber;
  const _TripCard({
    required this.trip,
    required this.plants,
    required this.partsByPartId,
    required this.dispatchByPartId,
    required this.packagingByPartId,
    required this.labelAvailableByPartId,
    required this.labelStockLoaded,
    required this.allocatedByPartId,
    required this.readyPartIds,
    required this.onAddPlan,
    required this.onRemoveTrip,
    required this.onRemovePlan,
    required this.onPlanChanged,
    required this.onResolveTripNumber,
  });

  DplPlant? _resolvePlant(String? code) {
    if (code == null) return null;
    for (final p in plants) {
      if (p.code == code) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final tripTotal = trip.plans.fold<int>(0, (s, p) => s + p.qty);
    final canAdd = trip.plans.length < _maxPlansPerTrip;
    final tripPlant = _resolvePlant(trip.plantCode);
    return Container(
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
      ),
      child: Column(
        children: [
          // Header
          Container(
            decoration: const BoxDecoration(
              color: DplColors.primaryTint,
              borderRadius: BorderRadius.vertical(top: Radius.circular(13)),
            ),
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            child: Row(
              children: [
                const Icon(
                  Icons.local_shipping_rounded,
                  color: DplColors.primaryDark,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  trip.number == null ? 'New Trip' : 'Trip ${trip.number}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: DplColors.primaryDark,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${trip.plans.length}/$_maxPlansPerTrip plans · '
                    '$tripTotal NOS',
                    style: const TextStyle(
                      color: DplColors.primaryDark,
                      fontWeight: FontWeight.w700,
                      fontSize: 10.5,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Remove trip',
                  icon: const Icon(
                    Icons.close_rounded,
                    color: DplColors.primaryDark,
                  ),
                  onPressed: onRemoveTrip,
                ),
              ],
            ),
          ),
          // Trip-level plant picker — every plan in this trip inherits
          // this. Changing it after plans exist invalidates their
          // machine + part picks, so we reset those fields and tell the
          // user what just happened.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: _PickerField<String>(
              label: 'Plant',
              icon: Icons.factory_rounded,
              value: trip.plantCode,
              items: [
                for (final p in plants)
                  DropdownMenuItem<String>(
                    value: p.code,
                    child: Text(p.name.isEmpty ? p.code : p.name),
                  ),
              ],
              hint: 'Select plant',
              onChanged: (v) {
                trip.plantCode = v;
                // Plant changed → the trip's prior `number` was for
                // the OLD plant. Clear it so the header reads "New
                // Trip" until the new lookup resolves.
                trip.number = null;
                // Reset every plan's machine/part/qty — the previous
                // picks were rooted in the old plant's machines.
                for (final p in trip.plans) {
                  p.machineName = null;
                  p.partId = null;
                  p.qty = 0;
                }
                onPlanChanged();
                if (v != null) {
                  // Fire-and-forget; the parent setState fires when
                  // the number lands.
                  onResolveTripNumber(v);
                }
              },
            ),
          ),
          // Plans
          if (trip.plans.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
              child: Text(
                tripPlant == null
                    ? 'Pick a plant above, then add plans below.'
                    : 'No plans yet. Tap "Add Plan" below to add a part.',
                style: TextStyle(
                  color: DplColors.textSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
            )
          else
            for (var i = 0; i < trip.plans.length; i++) ...[
              if (i > 0)
                const Divider(height: 1, color: DplColors.divider),
              _PlanRow(
                index: i + 1,
                plan: trip.plans[i],
                tripPlant: tripPlant,
                partsByPartId: partsByPartId,
                dispatchByPartId: dispatchByPartId,
                packagingByPartId: packagingByPartId,
                labelAvailableByPartId: labelAvailableByPartId,
                labelStockLoaded: labelStockLoaded,
                allocatedByPartId: allocatedByPartId,
                readyPartIds: readyPartIds,
                onRemove: () => onRemovePlan(trip.plans[i]),
                onChanged: onPlanChanged,
              ),
            ],
          // Add plan footer
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: canAdd ? onAddPlan : null,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(
                  canAdd
                      ? 'Add Plan  (${trip.plans.length}/$_maxPlansPerTrip)'
                      : 'Trip is full ($_maxPlansPerTrip plans)',
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanRow extends StatefulWidget {
  final int index;
  final _TripPlanDraft plan;

  /// The trip's selected plant (null until the trip header picker
  /// chooses one). All plans in a trip share this plant — the machine
  /// dropdown is scoped to its `machines[]`.
  final DplPlant? tripPlant;
  final Map<int, _PartLookup> partsByPartId;
  final Map<int, int> dispatchByPartId;

  /// Per-part qty already allocated across every trip (including this
  /// plan's own contribution). The description picker subtracts this
  /// plan's existing qty before computing the remaining suggested.
  final Map<int, int> allocatedByPartId;

  /// Units per pack for each part (when configured). Drives the
  /// "Pack: N NOS" hint + multiple-of-pack warning under the qty
  /// input. Missing entries → hint is hidden for that row.
  final Map<int, int> packagingByPartId;

  /// Labelled stock per part. Missing = nothing printed.
  final Map<int, DplLabelStock> labelAvailableByPartId;

  /// False while the label-stock fetch is in flight or failed.
  final bool labelStockLoaded;

  final Set<int> readyPartIds;
  final VoidCallback onRemove;
  final VoidCallback onChanged;
  const _PlanRow({
    required this.index,
    required this.plan,
    required this.tripPlant,
    required this.partsByPartId,
    required this.dispatchByPartId,
    required this.packagingByPartId,
    required this.labelAvailableByPartId,
    required this.labelStockLoaded,
    required this.allocatedByPartId,
    required this.readyPartIds,
    required this.onRemove,
    required this.onChanged,
  });

  @override
  State<_PlanRow> createState() => _PlanRowState();
}

class _PlanRowState extends State<_PlanRow> {
  late final TextEditingController _qtyCtrl;

  @override
  void initState() {
    super.initState();
    _qtyCtrl = TextEditingController(
      text: widget.plan.qty == 0 ? '' : '${widget.plan.qty}',
    );
    _qtyCtrl.addListener(() {
      final v = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
      if (v != widget.plan.qty) {
        widget.plan.qty = v;
        widget.onChanged();
      }
    });
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    super.dispose();
  }

  void _setQtyText(int qty) {
    final s = qty == 0 ? '' : '$qty';
    if (_qtyCtrl.text != s) {
      _qtyCtrl.text = s;
      _qtyCtrl.selection =
          TextSelection.collapsed(offset: _qtyCtrl.text.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Machines: scoped to the trip's plant (resolved upstream in
    // _TripCard) — no per-plan plant picker any more.
    final tripPlant = widget.tripPlant;
    final machineNames = tripPlant?.machines
            .map((m) => m.name)
            .where((n) => n.isNotEmpty)
            .toSet() ??
        const <String>{};
    final machineItems = [
      for (final n in machineNames)
        DropdownMenuItem<String>(value: n, child: Text(n)),
    ];

    // Parts on the selected machine — both "ready" (all 3 master
    // fields set, so we have a suggested qty) and "needs setup"
    // (master data incomplete). The manager can pick either; the
    // ready ones auto-fill qty, the others require manual entry but
    // are still bookable on a trip.
    final partsOnMachine = widget.partsByPartId.values.where((p) {
      if (widget.plan.machineName != null &&
          widget.plan.machineName!.isNotEmpty &&
          p.machineName.toLowerCase() !=
              widget.plan.machineName!.toLowerCase()) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        // Ready first, then by description so the suggested-qty
        // candidates surface at the top of the dropdown.
        final ar = widget.readyPartIds.contains(a.partId) ? 0 : 1;
        final br = widget.readyPartIds.contains(b.partId) ? 0 : 1;
        if (ar != br) return ar - br;
        return a.description.compareTo(b.description);
      });
    // When the machine has zero parts at all, fall back to the full
    // catalogue so the manager can still pick something and type a
    // qty — the in-banner note above the picker explains why.
    final usingMachineFallback =
        widget.plan.machineName != null && partsOnMachine.isEmpty;
    final partOptions = usingMachineFallback
        ? (widget.partsByPartId.values.toList()
          ..sort((a, b) => a.description.compareTo(b.description)))
        : partsOnMachine;
    final readyCount =
        partsOnMachine.where((p) => widget.readyPartIds.contains(p.partId))
            .length;
    final partItems = [
      for (final p in partOptions)
        DropdownMenuItem<int>(
          value: p.partId,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  p.description.isEmpty
                      ? p.customerPn
                      : '${p.description} — ${p.partName.isEmpty ? p.customerPn : p.partName}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!widget.readyPartIds.contains(p.partId))
                Container(
                  margin: const EdgeInsets.only(left: 6),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: DplColors.warningBg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'Needs setup',
                    style: TextStyle(
                      color: DplColors.warning,
                      fontWeight: FontWeight.w800,
                      fontSize: 10,
                    ),
                  ),
                ),
            ],
          ),
        ),
    ];

    final suggested = widget.plan.partId == null
        ? null
        : widget.dispatchByPartId[widget.plan.partId];
    final pack = widget.plan.partId == null
        ? null
        : widget.packagingByPartId[widget.plan.partId];

    // Labelled stock for this part.
    //
    // `stock` is null in two distinct situations and they must not be
    // conflated: the fetch has not landed (unknown — leave the input
    // uncapped and say so, the server still enforces), or it has landed and
    // this part simply has nothing printed (a hard zero).
    final DplLabelStock? stock = (widget.plan.partId == null || !widget.labelStockLoaded)
        ? null
        : (widget.labelAvailableByPartId[widget.plan.partId] ??
            const DplLabelStock());

    // The cap only exists when the flag is on. With it off, `labelCap` is null
    // everywhere it is consumed, so the input formatter is not installed, the
    // one-tap shortcuts are unrestricted and Submit is not gated — planning
    // behaves exactly as it did before the rule was introduced.
    final labelCap =
        DplFeatureFlags.enforceLabelStockOnPlan ? stock?.availableQty : null;
    final overLabelCap = labelCap != null && widget.plan.qty > labelCap;

    // Advisory note shown directly under the Description label when
    // the selected machine has nothing pre-configured for a clean
    // auto-fill. The picker stays usable either way.
    String? descriptionNote;
    if (widget.plan.machineName != null) {
      if (usingMachineFallback) {
        descriptionNote =
            'No parts on this machine — showing every part. Pick one '
            'and enter qty manually.';
      } else if (readyCount == 0) {
        descriptionNote =
            'No parts ready on this machine. You can still pick one '
            'and enter qty manually.';
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Plan ${widget.index}',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                  color: DplColors.textPrimary,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Remove plan',
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: DplColors.textSecondary,
                ),
                onPressed: widget.onRemove,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 6),
          _PickerField<String>(
            label: 'Machine',
            icon: Icons.precision_manufacturing_rounded,
            value: machineNames.contains(widget.plan.machineName)
                ? widget.plan.machineName
                : null,
            items: machineItems,
            hint: tripPlant == null
                ? 'Pick the trip\'s plant first'
                : (machineItems.isEmpty
                    ? 'No machines in this plant'
                    : 'Select machine'),
            enabled: tripPlant != null && machineItems.isNotEmpty,
            onChanged: (v) {
              setState(() {
                widget.plan.machineName = v;
                widget.plan.partId = null;
                widget.plan.partLabel = null;
                widget.plan.qty = 0;
                _setQtyText(0);
              });
              widget.onChanged();
            },
          ),
          const SizedBox(height: 6),
          _PickerField<int>(
            label: 'Description',
            icon: Icons.inventory_2_outlined,
            value: partItems.any((m) => m.value == widget.plan.partId)
                ? widget.plan.partId
                : null,
            items: partItems,
            hint: widget.plan.machineName == null
                ? 'Pick a machine first'
                : (partItems.isEmpty
                    ? 'No parts available'
                    : 'Select description'),
            enabled: widget.plan.machineName != null && partItems.isNotEmpty,
            onChanged: (v) {
              setState(() {
                // Capture whether the same part was already pinned to
                // this plan before mutating. Determines whether this
                // plan's own qty must be excluded from "other plans'
                // allocations" below.
                final wasSamePart = widget.plan.partId == v;
                widget.plan.partId = v;
                widget.plan.partLabel = v == null
                    ? null
                    : (widget.partsByPartId[v]?.customerPn.isNotEmpty == true
                        ? widget.partsByPartId[v]!.customerPn
                        : widget.partsByPartId[v]?.description);

                // Auto-fill with the formula result when the part is
                // ready, MINUS whatever is already allocated to this
                // part in OTHER plans across every trip. So if 102ZX
                // suggests 79 and Plan 1 already took 16, picking it
                // again in Plan 2 fills 63 — not 79.
                int auto;
                if (v == null) {
                  auto = 0;
                } else {
                  final suggested = widget.dispatchByPartId[v] ?? 0;
                  final otherAllocated = (widget.allocatedByPartId[v] ?? 0) -
                      (wasSamePart ? widget.plan.qty : 0);
                  final remaining = suggested - otherAllocated;
                  auto = remaining < 0 ? 0 : remaining;
                }
                widget.plan.qty = auto;
                _setQtyText(auto);
              });
              widget.onChanged();
            },
          ),
          if (descriptionNote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    size: 13,
                    color: DplColors.warning,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      descriptionNote,
                      style: const TextStyle(
                        color: DplColors.warning,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.calculate_outlined,
                  size: 18, color: DplColors.textSecondary),
              const SizedBox(width: 6),
              const Text(
                'Qty',
                style: TextStyle(
                  color: DplColors.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 11.5,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _qtyCtrl,
                  textAlign: TextAlign.center,
                  keyboardType:
                      const TextInputType.numberWithOptions(),
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(7),
                    // Hard cap at the labelled stock. Rejecting the keystroke
                    // beats accepting it and complaining on submit: the
                    // manager never types a number the backend will refuse.
                    if (labelCap != null) _MaxValueFormatter(labelCap),
                  ],
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                  decoration: InputDecoration(
                    hintText: 'NOS',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (suggested != null ||
                  pack != null ||
                  stock != null ||
                  widget.plan.partId != null) ...[
                Expanded(
                  child: Text(
                    _suggestedAndPackLabel(
                      suggested,
                      pack,
                      stock,
                      widget.plan.partId != null,
                      widget.labelStockLoaded,
                    ),
                    style: TextStyle(
                      // Amber only when a zero actually stops something. With
                      // the cap off it is just a fact, and colouring it as a
                      // warning beside a field that accepts any value reads as
                      // a malfunction.
                      color: (DplFeatureFlags.enforceLabelStockOnPlan &&
                              stock != null &&
                              stock.availableQty == 0)
                          ? DplColors.warning
                          : DplColors.textSecondary,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Only offer "Reset to suggested" when the suggestion is
                // actually dispatchable. Otherwise the one-tap shortcut hands
                // the manager a number the backend will refuse.
                if (suggested != null &&
                    widget.plan.qty != suggested &&
                    (labelCap == null || suggested <= labelCap))
                  TextButton(
                    onPressed: () {
                      setState(() {
                        widget.plan.qty = suggested;
                        _setQtyText(suggested);
                      });
                      widget.onChanged();
                      DplSnacks.success(
                          context, 'Reset to suggested qty.');
                    },
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Reset',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ],
          ),
          // Multiple-of-pack warning. Soft, non-blocking — partial
          // packs are valid for stock-short / pilot scenarios per the
          // backend contract. We show suggested nearest multiples so
          // the manager can one-tap to align if they want to.
          if (pack != null && widget.plan.qty > 0 && widget.plan.qty % pack != 0)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 6),
              child: _MultipleOfPackHint(
                pack: pack,
                qty: widget.plan.qty,
                // The pack-rounding shortcut must not step over the label
                // ceiling either — rounding 12 up to 14 when only 12 are
                // labelled would hand back a number the backend refuses.
                maxQty: labelCap,
                onApply: (newQty) {
                  setState(() {
                    widget.plan.qty = newQty;
                    _setQtyText(newQty);
                  });
                  widget.onChanged();
                },
              ),
            ),
          // Reachable when a part is swapped after a qty was typed: the
          // formatter only guards keystrokes, not a later change of part.
          if (overLabelCap && stock != null)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 6),
              child: Text(
                stock.nothingPrinted
                    ? 'No labels have been printed for this part yet — ask QA to '
                        'scan and print before planning it.'
                    : stock.allLoaded
                        // The case that produced the misleading message. Say
                        // where the stock went, not that it never existed.
                        ? 'All ${stock.labelledQty} printed labels for this part have '
                            'already been loaded onto trips. Print labels for newly '
                            'produced pieces before planning more.'
                        : 'Only ${stock.availableQty} labelled NOS are free to dispatch. '
                            'Reduce the qty.',
                style: const TextStyle(
                  color: DplColors.error,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Builds the right-hand label next to the qty input. Combines the
  /// formula's suggested qty, the customer's pack size and the labelled stock
  /// into a middot-separated string
  /// ("Labels: 12 NOS · Suggested: 79 NOS · Pack: 14 NOS").
  /// Any piece may be null — surface only what's available.
  ///
  /// The label figure leads: it is the only one of the three that is a hard
  /// ceiling, so it is what the manager needs to read first.
  String _suggestedAndPackLabel(
    int? suggested,
    int? pack,
    DplLabelStock? stock,
    bool partChosen,
    bool stockLoaded,
  ) {
    final parts = <String>[];
    if (partChosen && !stockLoaded) {
      // Unknown, not zero. Saying "No labels printed" here was the bug: a part
      // with 28 printed labels read as having none simply because the fetch
      // had not landed — or, worse, because every piece was already claimed by
      // another trip, which is a different problem with a different fix.
      parts.add('Checking labels…');
    } else if (stock != null) {
      parts.add(
        stock.hintFor(enforced: DplFeatureFlags.enforceLabelStockOnPlan),
      );
    }
    if (suggested != null) parts.add('Suggested: $suggested NOS');
    if (pack != null) parts.add('Pack: $pack NOS');
    return parts.join(' · ');
  }
}

/// Rejects any edit that would push the numeric value above [max].
///
/// Used to cap trip qty at the labelled stock. Deliberately REJECTS rather
/// than silently rewriting to [max]: a field that changes the digits out from
/// under someone mid-type is worse than one that simply will not accept them,
/// and the hint beside it already says what the ceiling is.
///
/// An empty field is always allowed through, otherwise the value could never
/// be cleared and retyped.
class _MaxValueFormatter extends TextInputFormatter {
  final int max;

  const _MaxValueFormatter(this.max);

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text.trim();
    if (text.isEmpty) return newValue;
    final parsed = int.tryParse(text);
    // Non-numeric cannot happen behind digitsOnly, but fall through rather
    // than throwing if the formatter order ever changes.
    if (parsed == null) return newValue;
    return parsed > max ? oldValue : newValue;
  }
}

/// Soft warning shown when the typed qty isn't a multiple of the
/// part's pack size. Renders two TextButton chips for the nearest
/// multiples below + above — one-tap correction without typing.
class _MultipleOfPackHint extends StatelessWidget {
  final int pack;
  final int qty;

  /// Labelled stock ceiling, when known. The "round up" chip is withheld when
  /// it would exceed this — offering a one-tap value the backend refuses is
  /// worse than offering nothing.
  final int? maxQty;

  final ValueChanged<int> onApply;
  const _MultipleOfPackHint({
    required this.pack,
    required this.qty,
    required this.onApply,
    this.maxQty,
  });

  @override
  Widget build(BuildContext context) {
    final lower = (qty ~/ pack) * pack;
    final upperRaw = lower + pack;
    final upper = (maxQty != null && upperRaw > maxQty!) ? null : upperRaw;
    return Row(
      children: [
        const Icon(Icons.warning_amber_rounded,
            size: 14, color: DplColors.warning),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            'Not a multiple of $pack — try',
            style: const TextStyle(
              color: DplColors.warning,
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
        ),
        const SizedBox(width: 4),
        // The "lower" suggestion is hidden when qty is below one full
        // pack — there's no meaningful lower multiple to offer.
        if (lower > 0)
          _PackSuggestionChip(value: lower, onTap: () => onApply(lower)),
        if (lower > 0 && upper != null) const SizedBox(width: 4),
        if (upper != null)
          _PackSuggestionChip(value: upper, onTap: () => onApply(upper)),
      ],
    );
  }
}

class _PackSuggestionChip extends StatelessWidget {
  final int value;
  final VoidCallback onTap;
  const _PackSuggestionChip({required this.value, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: DplColors.warningBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: DplColors.warning, width: 0.8),
        ),
        child: Text(
          '$value',
          style: const TextStyle(
            color: DplColors.warning,
            fontWeight: FontWeight.w800,
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}

class _PickerField<T> extends StatelessWidget {
  final String label;
  final IconData icon;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final String hint;
  final bool enabled;
  final ValueChanged<T?> onChanged;
  const _PickerField({
    required this.label,
    required this.icon,
    required this.value,
    required this.items,
    required this.hint,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        prefixIcon: Icon(icon, size: 18, color: DplColors.textSecondary),
        labelText: label,
        labelStyle: const TextStyle(
          color: DplColors.textSecondary,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 4,
        ),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: DplColors.divider),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          hint: Text(
            hint,
            style: const TextStyle(
              color: DplColors.textTertiary,
              fontSize: 13,
            ),
          ),
          items: items,
          onChanged: enabled ? onChanged : null,
        ),
      ),
    );
  }
}

// ────────────── Local draft models ──────────────

class _TripDraft {
  /// Backend-aligned `trip_number` for the chosen plant + business
  /// day. `null` until the user picks a plant — at which point the
  /// screen calls `listTrips(plant_code, date)` and sets this to the
  /// count of today's trips for that plant + 1 (server-side will
  /// assign the exact same number at POST time).
  int? number;

  /// The whole trip is scoped to a single plant — matches the slip
  /// model downstream. Set once at the trip header; every plan in the
  /// trip inherits it.
  String? plantCode;
  final List<_TripPlanDraft> plans;
  _TripDraft({List<_TripPlanDraft>? plans}) : plans = plans ?? [];
}

class _TripPlanDraft {
  String? machineName;
  int? partId;
  int qty = 0;

  /// Human label for [partId], captured when the part is picked.
  ///
  /// Held on the draft because validation runs outside the build scope where
  /// the parts lookup lives, and a submit error that says "part #42" instead
  /// of "546469500102ZX" is not something a manager can act on.
  String? partLabel;

  _TripPlanDraft();
}

class _PartLookup {
  final int partId;
  final String customerPn;
  final String description;
  final String partName;
  final String machineName;
  const _PartLookup({
    required this.partId,
    required this.customerPn,
    required this.description,
    required this.partName,
    required this.machineName,
  });
}

class _JoinedRow {
  final int partId;
  final String customerPn;
  final String description;
  final String partName;
  final String machineName;
  final int? stockingNorm;
  final int? customerOpeningStock;
  final int? customerTodayPlan;

  const _JoinedRow({
    required this.partId,
    this.customerPn = '',
    this.description = '',
    this.partName = '',
    this.machineName = '',
    this.stockingNorm,
    this.customerOpeningStock,
    this.customerTodayPlan,
  });

  _JoinedRow copyWith({
    int? stockingNorm,
    int? customerOpeningStock,
    int? customerTodayPlan,
  }) {
    return _JoinedRow(
      partId: partId,
      customerPn: customerPn,
      description: description,
      partName: partName,
      machineName: machineName,
      stockingNorm: stockingNorm ?? this.stockingNorm,
      customerOpeningStock:
          customerOpeningStock ?? this.customerOpeningStock,
      customerTodayPlan: customerTodayPlan ?? this.customerTodayPlan,
    );
  }

  bool get isReady =>
      stockingNorm != null &&
      customerOpeningStock != null &&
      customerTodayPlan != null;

  int? get dispatchQty {
    if (!isReady) return null;
    final raw = stockingNorm! + customerTodayPlan! - customerOpeningStock!;
    return raw < 0 ? 0 : raw;
  }
}
