import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../../../core/widgets/shimmer_skeleton.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_dashboard_switcher.dart';
import '../../models/dpl_dashboard_summary.dart';
import '../providers/dpl_dashboard_provider.dart';
import '../providers/dpl_viewer_only_provider.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_retry.dart';
import '../widgets/machine_downtime_banner.dart';
import '../widgets/machine_summary_card.dart';
import '../widgets/status_badge.dart';

/// How often the dashboard re-pulls totals + per-machine state. Picked
/// to be slow enough to not hammer the API (a manager glancing at the
/// screen doesn't need sub-second freshness) but fast enough that an
/// active downtime started by a supervisor shows up within half a
/// minute. The ticker pauses when the app is backgrounded so it
/// doesn't burn battery / quota.
const _kDashboardRefreshInterval = Duration(seconds: 30);

class DplManagerDashboardScreen extends ConsumerStatefulWidget {
  const DplManagerDashboardScreen({super.key});

  @override
  ConsumerState<DplManagerDashboardScreen> createState() =>
      _DplManagerDashboardScreenState();
}

class _DplManagerDashboardScreenState
    extends ConsumerState<DplManagerDashboardScreen>
    with WidgetsBindingObserver {
  Timer? _ticker;
  DateTime? _lastTick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTicker();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopTicker();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause polling when the app drops to the background. Resume +
    // do an immediate refresh on the way back so the screen catches
    // up to whatever happened while it was hidden.
    if (state == AppLifecycleState.resumed) {
      _refreshOnce();
      _startTicker();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _stopTicker();
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(_kDashboardRefreshInterval, (_) => _refreshOnce());
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _refreshOnce() {
    if (!mounted) return;
    ref.invalidate(dplDashboardSummaryProvider);
    ref.invalidate(dplDashboardMtdProvider);
    setState(() => _lastTick = DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    final date = ref.watch(dplDashboardDateProvider);
    final summary = ref.watch(dplDashboardSummaryProvider);
    final viewerOnly = ref.watch(dplViewerOnlyProvider);

    final isPhone = MediaQuery.of(context).size.width < 600;

    return Scaffold(
      appBar: DplAppBar(
        title: 'Daily Production',
        subtitle: _LiveIndicator(lastTick: _lastTick),
        // Full-width Production⇄Dispatch toggle band directly under the
        // nav bar. Manager-only — hidden for the read-only Customer viewer.
        bottom: viewerOnly
            ? null
            : const DplDashboardSwitcher(current: DplDashboardMode.production),
        actions: [
          // DPL Customer is read-only — Upload Plan is a write action so
          // it's stripped from the app bar entirely. The calendar picker
          // stays because it only changes which date the user is viewing.
          if (!viewerOnly) ...[
            if (isPhone)
              IconButton(
                tooltip: 'Dispatch Planning',
                icon: Icon(
                  Icons.local_shipping_outlined,
                  color: DplColors.primary,
                ),
                onPressed: () =>
                    context.push('/dpl/manager/dispatch-planning'),
              )
            else
              Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: OutlinedButton.icon(
                  onPressed: () =>
                      context.push('/dpl/manager/dispatch-planning'),
                  icon: const Icon(Icons.local_shipping_outlined, size: 18),
                  label: const Text(
                    'Dispatch Planning',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: DplColors.primary,
                    side: BorderSide(color: DplColors.primary, width: 1.4),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            if (isPhone)
              IconButton(
                tooltip: 'Upload Plan',
                icon: Icon(
                  Icons.upload_file_outlined,
                  color: DplColors.primary,
                ),
                onPressed: () => context.push('/dpl/manager/upload-plan'),
              )
            else
              Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: FilledButton.icon(
                  onPressed: () => context.push('/dpl/manager/upload-plan'),
                  icon: const Icon(Icons.upload_file_outlined, size: 18),
                  label: const Text(
                    'Upload Plan',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: DplColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
          ],
          IconButton(
            tooltip: 'Pick date',
            icon: const Icon(Icons.calendar_today_outlined),
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: date,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) {
                ref.read(dplDashboardDateProvider.notifier).set(picked);
              }
            },
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [VistarPalette.bg, VistarPalette.bg2, VistarPalette.bg],
          ),
        ),
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(dplDashboardSummaryProvider);
            await ref.read(dplDashboardSummaryProvider.future);
          },
          child: summary.when(
            loading: () => const _DashboardSkeleton(),
            error: (e, _) => ListView(
              children: [
                DplErrorRetry(
                  message: e.toString(),
                  onRetry: () =>
                      ref.invalidate(dplDashboardSummaryProvider),
                ),
              ],
            ),
            data: (res) {
              if (res.isError) {
                return ListView(
                  children: [
                    DplErrorRetry(
                      message: res.error ?? 'Failed to load dashboard.',
                      onRetry: () =>
                          ref.invalidate(dplDashboardSummaryProvider),
                    ),
                  ],
                );
              }
              final data = res.data ?? DplDashboardSummary.empty(date);
              return _DashboardBody(summary: data);
            },
          ),
        ),
      ),
    );
  }
}

/// Tiny "Live • updated 12s ago" badge under the app-bar title so the
/// manager can see the screen is polling and roughly when it last did.
class _LiveIndicator extends StatelessWidget {
  final DateTime? lastTick;
  const _LiveIndicator({required this.lastTick});

  String _label() {
    if (lastTick == null) return 'Live';
    final delta = DateTime.now().difference(lastTick!);
    if (delta.inSeconds < 5) return 'Live • just now';
    if (delta.inSeconds < 60) return 'Live • ${delta.inSeconds}s ago';
    return 'Live • ${delta.inMinutes}m ago';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: VistarPalette.ok,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          _label(),
          style: TextStyle(
            fontSize: 11,
            color: DplColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// One bucket per machine after `_mergeByMachine` has folded the backend's
/// per-(plan, shift) rows together. Carries every distinct shift label that
/// touched the machine plus combined Plan/Actual totals AND a per-plan
/// breakdown that drives the tap-through picker when the machine has more
/// than one plan on the selected date.
class _MergedMachineRow {
  final int machineId;
  final String machineName;
  final List<String> shiftLabels;
  final String status;
  final int planQty;
  final int actualQty;
  final double completionPct;
  final String supervisorName;
  /// Distinct plans on this machine for the selected date, in backend
  /// order. Length 1 = direct tap-through; length >1 = picker sheet.
  final List<_PlanRef> plans;

  const _MergedMachineRow({
    required this.machineId,
    required this.machineName,
    required this.shiftLabels,
    required this.status,
    required this.planQty,
    required this.actualQty,
    required this.completionPct,
    required this.supervisorName,
    required this.plans,
  });
}

/// Per-plan summary shown inside the multi-plan picker sheet (and used
/// internally to drive the tap target). One per distinct plan_id within
/// a machine group.
class _PlanRef {
  final int planId;
  final List<String> shiftLabels;
  final String status;
  final int planQty;
  final int actualQty;
  final String supervisorName;

  const _PlanRef({
    required this.planId,
    required this.shiftLabels,
    required this.status,
    required this.planQty,
    required this.actualQty,
    required this.supervisorName,
  });

  double get completionPct => planQty <= 0 ? 0 : actualQty / planQty;
}

/// Highest-priority status wins when a machine has plans across several
/// shifts (e.g. one shift in_progress, one pending → show in_progress).
const Map<String, int> _statusPriority = {
  'in_progress': 5,
  'running': 5,
  'pending': 4,
  'published': 3,
  'completed': 2,
  'locked': 1,
};

int _statusRank(String status) =>
    _statusPriority[status.trim().toLowerCase()] ?? 0;

/// Helper: derive the sorted distinct shift labels for a slice of rows.
/// Pills always read "A → B → C" regardless of backend order.
List<String> _shiftLabelsOf(List<DplMachineSummary> rows) {
  final labelByCode = <String, String>{};
  for (final r in rows) {
    final code = r.shiftCode.trim();
    final label = r.shiftLabel.trim();
    if (label.isEmpty) continue;
    labelByCode.putIfAbsent(code.isEmpty ? label : code, () => label);
  }
  final sortedKeys = labelByCode.keys.toList()..sort();
  return sortedKeys.map((k) => labelByCode[k]!).toList();
}

/// Helper: highest-priority status across a slice of rows.
String _topStatusOf(List<DplMachineSummary> rows) {
  var status = rows.first.status;
  for (final r in rows.skip(1)) {
    if (_statusRank(r.status) > _statusRank(status)) status = r.status;
  }
  return status;
}

/// Helper: distinct, ` · `-joined supervisor names for a slice of rows.
String _supervisorsOf(List<DplMachineSummary> rows) {
  final supervisors = <String>{};
  for (final r in rows) {
    final n = r.supervisorName.trim();
    if (n.isNotEmpty) supervisors.add(n);
  }
  return supervisors.join(' · ');
}

/// Groups the backend's per-(plan, shift) rows by `machineId` so each
/// physical machine renders as exactly one dashboard card. Totals are
/// summed across every plan + shift on the machine; a per-plan breakdown
/// is kept so the tap target can resolve to the right plan (direct push
/// for single-plan machines, picker sheet for multi-plan machines —
/// otherwise a "card shows 92, detail shows 24" mismatch is possible).
List<_MergedMachineRow> _mergeByMachine(List<DplMachineSummary> rows) {
  final order = <int>[];
  final byMachine = <int, List<DplMachineSummary>>{};
  for (final r in rows) {
    if (!byMachine.containsKey(r.machineId)) {
      order.add(r.machineId);
      byMachine[r.machineId] = <DplMachineSummary>[];
    }
    byMachine[r.machineId]!.add(r);
  }

  return order.map((id) {
    final group = byMachine[id]!;
    final first = group.first;

    var planQty = 0;
    var actualQty = 0;
    for (final r in group) {
      planQty += r.planQty;
      actualQty += r.actualQty;
    }
    // No upper clamp — over-achievement is real data the card should
    // surface. The progress bar clamps `value` to [0,1] at render time.
    final pct = planQty == 0 ? 0.0 : (actualQty / planQty);

    // Second-level group: by plan_id within this machine. Drives the
    // picker sheet so each plan's detail is one tap away when the
    // machine has more than one.
    final planOrder = <int>[];
    final byPlan = <int, List<DplMachineSummary>>{};
    for (final r in group) {
      final pid = r.planId;
      if (pid == null) continue;
      if (!byPlan.containsKey(pid)) {
        planOrder.add(pid);
        byPlan[pid] = <DplMachineSummary>[];
      }
      byPlan[pid]!.add(r);
    }
    final plans = planOrder.map((pid) {
      final pGroup = byPlan[pid]!;
      var pPlan = 0;
      var pActual = 0;
      for (final r in pGroup) {
        pPlan += r.planQty;
        pActual += r.actualQty;
      }
      return _PlanRef(
        planId: pid,
        shiftLabels: _shiftLabelsOf(pGroup),
        status: _topStatusOf(pGroup),
        planQty: pPlan,
        actualQty: pActual,
        supervisorName: _supervisorsOf(pGroup),
      );
    }).toList();

    return _MergedMachineRow(
      machineId: id,
      machineName: first.machineName,
      shiftLabels: _shiftLabelsOf(group),
      status: _topStatusOf(group),
      planQty: planQty,
      actualQty: actualQty,
      completionPct: pct.toDouble(),
      supervisorName: _supervisorsOf(group),
      plans: plans,
    );
  }).toList();
}

class _DashboardBody extends StatelessWidget {
  final DplDashboardSummary summary;

  const _DashboardBody({required this.summary});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final isPhone = MediaQuery.of(context).size.width < 600;
    final dateFmt = isPhone
        ? DateFormat('EEE, dd MMM yyyy')
        : DateFormat('EEEE, dd MMM yyyy');
    final outerPad = isPhone ? 12.0 : 16.0;
    final cardGap = isPhone ? 8.0 : 10.0;

    return ListView(
      padding: EdgeInsets.all(outerPad),
      children: [
        Text(
          dateFmt.format(summary.date),
          style: TextStyle(
            color: DplColors.textSecondary,
            fontWeight: FontWeight.w600,
            fontSize: isPhone ? 12 : 14,
          ),
        ),
        SizedBox(height: isPhone ? 8 : 10),
        _KpiStrip(summary: summary),
        if (summary.shifts.isNotEmpty) ...[
          SizedBox(height: isPhone ? 12 : 16),
          Text(
            'Shifts',
            style: TextStyle(
              fontSize: isPhone ? 13 : 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: isPhone ? 8 : 10),
          _ShiftRollupStrip(shifts: summary.shifts, fmt: fmt),
        ],
        SizedBox(height: isPhone ? 12 : 16),
        Text(
          'Machines',
          style: TextStyle(
            fontSize: isPhone ? 13 : 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        SizedBox(height: isPhone ? 8 : 10),
        if (summary.machines.isEmpty)
          const DplEmptyState(
            icon: Icons.precision_manufacturing_outlined,
            title: 'No machines configured',
            message: 'Upload a plan or set up machines from the Settings tab.',
          )
        else
          ..._mergeByMachine(summary.machines).map(
            (m) => Padding(
              padding: EdgeInsets.only(bottom: cardGap),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DplMachineSummaryCard(
                    machineId: m.machineId,
                    machineName: m.machineName,
                    shiftLabels: m.shiftLabels,
                    status: m.status,
                    planQty: m.planQty,
                    actualQty: m.actualQty,
                    completionPct: m.completionPct,
                    supervisorName: m.supervisorName,
                    planCount: m.plans.length,
                    onTap: m.plans.isEmpty
                        ? null
                        : m.plans.length == 1
                            ? () => context.push(
                                  '/dpl/manager/plans/${m.plans.first.planId}',
                                )
                            : () => _showMachinePlanPicker(context, m),
                  ),
                  // Per-machine downtime strip — only renders when this
                  // machine has an open downtime, so cards without one
                  // collapse back to their normal height.
                  MachineDowntimeBanner(
                    machineId: m.machineId,
                    planId: m.plans.isEmpty ? null : m.plans.first.planId,
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 32),
      ],
    );
  }
}

/// Bottom-sheet picker shown when a machine has more than one plan on
/// the selected date — keeps the dashboard at one card per machine while
/// still routing each tap to the correct plan detail.
Future<void> _showMachinePlanPicker(
  BuildContext context,
  _MergedMachineRow m,
) async {
  final fmt = NumberFormat.decimalPattern();
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.machineName.isEmpty
                              ? 'Machine #${m.machineId}'
                              : m.machineName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${m.plans.length} plans on this date',
                          style: TextStyle(
                            fontSize: 12,
                            color: DplColors.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final p in m.plans)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _PlanPickerTile(plan: p, fmt: fmt),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _PlanPickerTile extends StatelessWidget {
  final _PlanRef plan;
  final NumberFormat fmt;

  const _PlanPickerTile({required this.plan, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final pct = (plan.completionPct * 100).round();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(context).pop();
          context.push('/dpl/manager/plans/${plan.planId}');
        },
        child: Ink(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: DplColors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Plan #${plan.planId}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final label in plan.shiftLabels)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: VistarPalette.infoBg,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: VistarPalette.infoLine),
                          ),
                          child: Text(
                            label,
                            style: TextStyle(
                              color: VistarPalette.infoInk,
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      DplStatusBadge(status: plan.status),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _PlanPickerKv(
                      label: 'Plan',
                      value: fmt.format(plan.planQty),
                    ),
                  ),
                  Expanded(
                    child: _PlanPickerKv(
                      label: 'Actual',
                      value: fmt.format(plan.actualQty),
                    ),
                  ),
                  Expanded(
                    child: _PlanPickerKv(
                      label: 'Completion',
                      value: plan.planQty <= 0 ? '—' : '$pct%',
                    ),
                  ),
                ],
              ),
              if (plan.supervisorName.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.person_outline,
                      size: 14,
                      color: DplColors.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        plan.supervisorName,
                        style: TextStyle(
                          color: DplColors.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 12,
                      color: DplColors.textSecondary,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanPickerKv extends StatelessWidget {
  final String label;
  final String value;

  const _PlanPickerKv({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: DplColors.textSecondary,
            fontWeight: FontWeight.w600,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

/// Horizontally-scrollable strip of compact KPI cards shown at the top
/// of the Manager Dashboard. All three cards now come from the single
/// `/manager/dashboard` response — `summary.totals` for Today,
/// `summary.mtd` for the MTD card, `summary.totalDowntimeMinutes` for
/// the Downtime card. One round-trip serves the strip.
class _KpiStrip extends ConsumerWidget {
  final DplDashboardSummary summary;

  const _KpiStrip({required this.summary});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fmt = NumberFormat.decimalPattern();

    // ---- Today (selected date) ----
    final todayCard = _KpiCard(
      label: 'TODAY',
      sublabel: DateFormat('dd MMM').format(summary.date),
      ratioActual: summary.totalActualQty,
      ratioPlan: summary.totalPlanQty,
      pct: summary.completionPct,
      color: VistarPalette.info,
      icon: Icons.today_outlined,
      fmt: fmt,
    );

    // ---- MTD (bundled inside the dashboard response) ----
    final mtd = summary.mtd;
    final mtdCard = mtd == null
        ? _KpiCard(
            label: 'MTD',
            sublabel: 'Cumulative till date',
            ratioActual: 0,
            ratioPlan: 0,
            pct: 0,
            color: VistarPalette.ok,
            icon: Icons.calendar_month_outlined,
            fmt: fmt,
          )
        : _KpiCard(
            label: 'MTD',
            sublabel: 'Cumulative till date',
            ratioActual: mtd.actualQty,
            ratioPlan: mtd.planQty,
            pct: mtd.completionPct,
            color: VistarPalette.ok,
            icon: Icons.calendar_month_outlined,
            fmt: fmt,
          );

    // ---- Downtime today (from the bundled totals block) ----
    final downtimeCard = _KpiCardSimple(
      label: 'DOWNTIME',
      sublabel: 'Today',
      value: _formatHrsMin(summary.totalDowntimeMinutes),
      icon: Icons.timer_off_outlined,
      color: VistarPalette.warn,
    );

    final cards = <Widget>[todayCard, mtdCard, downtimeCard];
    final mobile = MediaQuery.of(context).size.width < 600;

    if (!mobile) {
      // Tablet / desktop — 3-up grid (or wrap on narrow tablet).
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: cards
            .map((c) => SizedBox(width: 200, child: c))
            .toList(),
      );
    }

    // Phones — fit all three KPIs in one row so nothing scrolls
    // off-screen. IntrinsicHeight equalises card heights regardless
    // of which one has the tallest content, Expanded splits the
    // available width evenly. Card internals are tuned to render
    // legibly at ~110dp width (see _KpiCard / _KpiCardSimple).
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            Expanded(child: cards[i]),
            if (i < cards.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  static String _formatHrsMin(int totalMinutes) {
    if (totalMinutes <= 0) return '0m';
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }
}

/// KPI card with an actual / plan ratio + completion % + tiny progress bar.
class _KpiCard extends StatelessWidget {
  final String label;
  final String sublabel;
  final int ratioActual;
  final int ratioPlan;
  final double pct;
  final Color color;
  final IconData icon;
  final NumberFormat fmt;

  const _KpiCard({
    required this.label,
    required this.sublabel,
    required this.ratioActual,
    required this.ratioPlan,
    required this.pct,
    required this.color,
    required this.icon,
    required this.fmt,
  });

  Color _achColor(double p) {
    if (ratioPlan == 0) return DplColors.textSecondary;
    if (p >= 1.0) return VistarPalette.info;
    if (p >= 0.9) return VistarPalette.ok;
    if (p >= 0.7) return VistarPalette.warn;
    return VistarPalette.bad;
  }

  @override
  Widget build(BuildContext context) {
    final pctRounded = (pct * 100).round();
    final achColor = _achColor(pct);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: DplColors.divider),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(icon, color: color, size: 14),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w900,
                        fontSize: 10,
                        letterSpacing: 0.4,
                        height: 1.1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      sublabel,
                      style: TextStyle(
                        color: DplColors.textSecondary,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  ratioPlan == 0 ? '—' : '$pctRounded%',
                  style: TextStyle(
                    color: achColor,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Big number scales to whatever width is available so the
          // card never overflows on narrow viewports.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: RichText(
              text: TextSpan(
                style: TextStyle(color: DplColors.textPrimary),
                children: [
                  TextSpan(
                    text: fmt.format(ratioActual),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  TextSpan(
                    text: ' / ${fmt.format(ratioPlan)}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      color: DplColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: pct.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: VistarPalette.surface3,
              valueColor: AlwaysStoppedAnimation(achColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// Simpler KPI card — single big value (no ratio).
class _KpiCardSimple extends StatelessWidget {
  final String label;
  final String sublabel;
  final String value;
  final IconData icon;
  final Color color;

  const _KpiCardSimple({
    required this.label,
    required this.sublabel,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: DplColors.divider),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(icon, color: color, size: 14),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w900,
                        fontSize: 10,
                        letterSpacing: 0.4,
                        height: 1.1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      sublabel,
                      style: TextStyle(
                        color: DplColors.textSecondary,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w900,
                fontSize: 20,
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Matches the progress-bar row of the ratio card so all
          // three cards in the row line up to the same height.
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

/// Horizontal strip of per-shift KPI tiles powered by the `shifts[]`
/// block on the dashboard response. Each tile shows the shift label,
/// plan count, actual/plan ratio, and completion %. Falls back to
/// "Unassigned" for the legacy `shift_id=null` bucket.
class _ShiftRollupStrip extends StatelessWidget {
  final List<DplDashboardShiftRollup> shifts;
  final NumberFormat fmt;

  const _ShiftRollupStrip({required this.shifts, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final isPhone = MediaQuery.of(context).size.width < 600;
    final gap = isPhone ? 8.0 : 10.0;

    final tiles = shifts.map((s) => _ShiftTile(shift: s, fmt: fmt)).toList();

    if (!isPhone) {
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: tiles
            .map((t) => SizedBox(width: 220, child: t))
            .toList(),
      );
    }

    // Phones — horizontal scroll so the strip never overflows even
    // when several shifts are active on the selected date.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            SizedBox(width: 180, child: tiles[i]),
            if (i < tiles.length - 1) SizedBox(width: gap),
          ],
        ],
      ),
    );
  }
}

class _ShiftTile extends StatelessWidget {
  final DplDashboardShiftRollup shift;
  final NumberFormat fmt;

  const _ShiftTile({required this.shift, required this.fmt});

  Color _achColor(double p) {
    if (shift.planQty == 0) return DplColors.textSecondary;
    if (p >= 1.0) return VistarPalette.info;
    if (p >= 0.9) return VistarPalette.ok;
    if (p >= 0.7) return VistarPalette.warn;
    return VistarPalette.bad;
  }

  @override
  Widget build(BuildContext context) {
    final pct = (shift.completionPct * 100).round();
    final achColor = _achColor(shift.completionPct);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: DplColors.divider),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: VistarPalette.infoBg,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(
                  Icons.schedule_outlined,
                  color: VistarPalette.infoInk,
                  size: 14,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shift.displayLabel,
                      style: TextStyle(
                        color: VistarPalette.infoInk,
                        fontWeight: FontWeight.w900,
                        fontSize: 11,
                        letterSpacing: 0.3,
                        height: 1.1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${shift.planCount} plan${shift.planCount == 1 ? '' : 's'}',
                      style: TextStyle(
                        color: DplColors.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  shift.planQty == 0 ? '—' : '$pct%',
                  style: TextStyle(
                    color: achColor,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: RichText(
              text: TextSpan(
                style: TextStyle(color: DplColors.textPrimary),
                children: [
                  TextSpan(
                    text: fmt.format(shift.actualQty),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  TextSpan(
                    text: ' / ${fmt.format(shift.planQty)}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      color: DplColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: shift.completionPct.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: VistarPalette.surface3,
              valueColor: AlwaysStoppedAnimation(achColor),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardSkeleton extends StatelessWidget {
  const _DashboardSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: const [
        SkeletonBox(height: 14, width: 180),
        SizedBox(height: 14),
        SkeletonCard(),
        SizedBox(height: 14),
        SkeletonBox(height: 14, width: 100),
        SizedBox(height: 10),
        SkeletonList(count: 3),
      ],
    );
  }
}
