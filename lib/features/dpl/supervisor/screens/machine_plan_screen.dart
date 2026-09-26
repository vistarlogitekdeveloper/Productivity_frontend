import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../../../core/widgets/shimmer_skeleton.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_pauses_panel.dart';
import '../../core/widgets/dpl_refresh_icon_button.dart';
import '../../core/widgets/shift_chip.dart';
import '../../manager/widgets/empty_state.dart';
import '../../manager/widgets/error_retry.dart';
import '../../manager/widgets/status_badge.dart';
import '../../models/dpl_downtime_event.dart';
import '../../models/dpl_production_plan_item.dart';
import '../../models/dpl_supervisor_plan_detail.dart';
import '../providers/dpl_plan_pauses_provider.dart';
import '../providers/machine_plan_provider.dart';
import '../providers/today_plans_provider.dart';
import '../widgets/downtime_entry_sheet.dart';
import '../widgets/dpl_supervisor_footer.dart';
import '../widgets/live_timer_text.dart';
import '../widgets/plan_row_card.dart';
import '../widgets/supervisor_error_helper.dart';

class MachinePlanScreen extends ConsumerWidget {
  final int planId;

  const MachinePlanScreen({super.key, required this.planId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(machinePlanProvider(planId));

    final appBarTitle = async.maybeWhen(
      data: (res) {
        final name = res.data?.plan.machineName ?? '';
        return name.isEmpty ? 'Machine Plan' : name;
      },
      orElse: () => 'Machine Plan',
    );

    return Scaffold(
      appBar: DplAppBar(
        title: appBarTitle,
        actions: [
          DplRefreshIconButton(
            onRefresh: () async {
              ref.invalidate(machinePlanProvider(planId));
              try {
                await ref.read(machinePlanProvider(planId).future);
              } catch (_) {}
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(machinePlanProvider(planId));
          await ref.read(machinePlanProvider(planId).future);
        },
        child: async.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: SkeletonList(count: 4),
          ),
          error: (e, _) => ListView(
            children: [
              DplErrorRetry(
                message: e.toString(),
                onRetry: () => ref.invalidate(machinePlanProvider(planId)),
              ),
            ],
          ),
          data: (res) {
            if (res.isError) {
              return ListView(
                children: [
                  DplErrorRetry(
                    message: res.error ?? 'Failed to load plan.',
                    onRetry: () =>
                        ref.invalidate(machinePlanProvider(planId)),
                  ),
                ],
              );
            }
            final detail = res.data!;
            return _PlanBody(planId: planId, detail: detail);
          },
        ),
      ),
      bottomNavigationBar: DplSupervisorFooter(
        aboveNav: async.maybeWhen(
          data: (res) {
            if (res.isError || res.data == null) {
              return const SizedBox.shrink();
            }
            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.report_outlined),
                    label: const Text('Report Downtime'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: VistarPalette.warn,
                      side: BorderSide(
                        color: VistarPalette.warn,
                        width: 1.4,
                      ),
                    ),
                    onPressed: () => _openDowntimeSheet(
                      context,
                      ref,
                      res.data!,
                    ),
                  ),
                ),
              ),
            );
          },
          orElse: () => const SizedBox.shrink(),
        ),
      ),
    );
  }

  Future<void> _openDowntimeSheet(
    BuildContext context,
    WidgetRef ref,
    DplSupervisorPlanDetail detail,
  ) async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DowntimeEntrySheet(
        planId: detail.plan.id,
        machineId: detail.plan.machineId,
        machineName: detail.plan.machineName,
      ),
    );
  }
}

class _PlanBody extends ConsumerWidget {
  final int planId;
  final DplSupervisorPlanDetail detail;

  const _PlanBody({required this.planId, required this.detail});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fmt = NumberFormat.decimalPattern();
    final plan = detail.plan;
    final pct = (plan.completionPct * 100).round();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: VistarPalette.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      plan.machineName.isEmpty
                          ? 'Machine #${plan.machineId}'
                          : plan.machineName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  DplStatusBadge(status: plan.status),
                ],
              ),
              if (plan.shiftLabel.isNotEmpty) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DplShiftChip(label: plan.shiftLabel),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  _kv('Plan', fmt.format(plan.effectiveTotalPlanQty)),
                  const SizedBox(width: 16),
                  _kv('Actual', fmt.format(plan.effectiveTotalActualQty)),
                  const Spacer(),
                  _kv('Completion', '$pct%'),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: plan.completionPct,
                  minHeight: 8,
                  backgroundColor: VistarPalette.surface3,
                ),
              ),
            ],
          ),
        ),
        if (detail.activeDowntime != null) ...[
          const SizedBox(height: 12),
          _ActiveDowntimeCard(
            planId: planId,
            downtimeId: detail.activeDowntime!.id,
            reasonName: detail.activeDowntime!.reasonName,
            startTime: detail.activeDowntime!.startTime,
          ),
        ],
        const SizedBox(height: 16),
        const Text(
          'Items',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        if (plan.items.isEmpty)
          const DplEmptyState(
            icon: Icons.list_alt_outlined,
            title: 'No items',
            message: 'This plan has no items yet.',
          )
        else
          // Order: in-progress → pending (by plan_no) → completed.
          for (final item in plan.items.sortedForExecution())
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: PlanRowCard(
                item: item,
                onTap: () => context.push(
                  '/dpl/supervisor/machine/$planId/execute/${item.id}',
                ),
              ),
            ),
        if (detail.downtimeHistory.isNotEmpty) ...[
          const SizedBox(height: 16),
          _DowntimeHistoryCard(history: detail.downtimeHistory),
        ],
        const SizedBox(height: 16),
        const Text(
          'Pauses',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        _SupervisorPausesSection(planId: planId),
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _kv(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: VistarPalette.txt2,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
        ),
      ],
    );
  }
}

class _DowntimeHistoryCard extends StatelessWidget {
  final List<DplDowntimeEvent> history;

  const _DowntimeHistoryCard({required this.history});

  @override
  Widget build(BuildContext context) {
    final timeFmt = DateFormat('dd MMM HH:mm');
    final totalMinutes = history.fold<int>(
      0,
      (sum, e) => sum + (e.durationMinutes ?? 0),
    );

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.line),
      ),
      child: ExpansionTile(
        initiallyExpanded: false,
        shape: const RoundedRectangleBorder(side: BorderSide.none),
        leading: Icon(Icons.history, color: VistarPalette.txt2),
        title: const Text(
          'Downtime history',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          '${history.length} event${history.length == 1 ? "" : "s"}'
          '  •  $totalMinutes min total',
          style: TextStyle(color: VistarPalette.txt2),
        ),
        children: [
          for (final e in history)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 6,
                    height: 36,
                    decoration: BoxDecoration(
                      color: e.isActive
                          ? VistarPalette.bad
                          : (e.category == 'planned'
                              ? VistarPalette.info
                              : VistarPalette.warn),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.reasonName.isEmpty
                              ? 'Downtime'
                              : e.reasonName,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${timeFmt.format(e.startTime.toLocal())}'
                          '${e.endTime == null ? " — ongoing" : " → ${timeFmt.format(e.endTime!.toLocal())}"}',
                          style: TextStyle(
                            color: VistarPalette.txt2,
                            fontSize: 12,
                          ),
                        ),
                        if ((e.remarks ?? '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              e.remarks!,
                              style: TextStyle(
                                color: VistarPalette.txt2,
                                fontSize: 12,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (e.durationMinutes != null)
                    Text(
                      '${e.durationMinutes} min',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: VistarPalette.txt2,
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

class _ActiveDowntimeCard extends ConsumerStatefulWidget {
  final int planId;
  final int downtimeId;
  final String reasonName;
  final DateTime startTime;

  const _ActiveDowntimeCard({
    required this.planId,
    required this.downtimeId,
    required this.reasonName,
    required this.startTime,
  });

  @override
  ConsumerState<_ActiveDowntimeCard> createState() =>
      _ActiveDowntimeCardState();
}

class _ActiveDowntimeCardState extends ConsumerState<_ActiveDowntimeCard> {
  bool _isResuming = false;

  Future<void> _resume() async {
    setState(() => _isResuming = true);
    final res = await ref
        .read(dplApiServiceProvider)
        .resumeDowntime(widget.downtimeId);
    if (!mounted) return;
    setState(() => _isResuming = false);

    if (res.isError) {
      handleSupervisorError(
        context,
        res,
        fallback: 'Failed to resume from downtime.',
      );
      return;
    }
    DplSnack.success(context, 'Resumed from downtime.');
    ref.invalidate(machinePlanProvider(widget.planId));
    ref.invalidate(todayPlansProvider);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VistarPalette.badSolid,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Colors.white, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'DOWNTIME ACTIVE',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.reasonName.isEmpty ? 'Unknown' : widget.reasonName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                LiveTimerText(
                  startTime: widget.startTime,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: _isResuming ? null : _resume,
            icon: _isResuming
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: VistarPalette.bad,
                    ),
                  )
                : const Icon(Icons.play_arrow),
            label: const Text('Resume'),
            style: FilledButton.styleFrom(
              backgroundColor: VistarPalette.surface,
              foregroundColor: VistarPalette.bad,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pauses section (supervisor)
// ---------------------------------------------------------------------------

class _SupervisorPausesSection extends ConsumerWidget {
  final int planId;
  const _SupervisorPausesSection({required this.planId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dplSupervisorPlanPausesProvider(planId));
    void retry() => ref.invalidate(dplSupervisorPlanPausesProvider(planId));

    return async.when(
      loading: () => DplPausesPanel(
        pauses: const [],
        loading: true,
        onRetry: retry,
      ),
      error: (e, _) => DplPausesPanel(
        pauses: const [],
        error: e.toString(),
        onRetry: retry,
      ),
      data: (res) {
        if (res.isError) {
          return DplPausesPanel(
            pauses: const [],
            error: res.error ?? 'Failed to load pauses.',
            onRetry: retry,
          );
        }
        return DplPausesPanel(
          pauses: res.data ?? const [],
          onRetry: retry,
        );
      },
    );
  }
}
