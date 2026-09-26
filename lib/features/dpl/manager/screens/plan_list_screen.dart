import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../../../core/widgets/shimmer_skeleton.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_constants.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../models/dpl_production_plan.dart';
import '../providers/dpl_masters_provider.dart';
import '../providers/dpl_plan_list_provider.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_retry.dart';
import '../widgets/status_badge.dart';

class DplPlanListScreen extends ConsumerWidget {
  final bool embedded;

  const DplPlanListScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(dplPlanListFiltersProvider);
    final plans = ref.watch(dplPlanListProvider);

    final filterChips = <Widget>[
      if (filters.from != null || filters.to != null)
        InputChip(
          label: Text(_rangeLabel(filters.from, filters.to)),
          onDeleted: () => ref
              .read(dplPlanListFiltersProvider.notifier)
              .update(filters.copyWith(from: null, to: null)),
        ),
      if (filters.machineId != null)
        InputChip(
          label: Text('Machine #${filters.machineId}'),
          onDeleted: () => ref
              .read(dplPlanListFiltersProvider.notifier)
              .update(filters.copyWith(machineId: null)),
        ),
      if (filters.supervisorUserId != null)
        InputChip(
          label: Text('Supervisor #${filters.supervisorUserId}'),
          onDeleted: () => ref
              .read(dplPlanListFiltersProvider.notifier)
              .update(filters.copyWith(supervisorUserId: null)),
        ),
      if (filters.status != null && filters.status!.isNotEmpty)
        InputChip(
          label: Text(DplPlanStatus.label(filters.status!)),
          onDeleted: () => ref
              .read(dplPlanListFiltersProvider.notifier)
              .update(filters.copyWith(status: null)),
        ),
    ];

    final body = RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(dplPlanListProvider);
        await ref.read(dplPlanListProvider.future);
      },
      child: plans.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: SkeletonList(count: 5),
        ),
        error: (e, _) => ListView(
          children: [
            DplErrorRetry(
              message: e.toString(),
              onRetry: () => ref.invalidate(dplPlanListProvider),
            ),
          ],
        ),
        data: (res) {
          if (res.isError) {
            return ListView(
              children: [
                DplErrorRetry(
                  message: res.error ?? 'Failed to load plans.',
                  onRetry: () => ref.invalidate(dplPlanListProvider),
                ),
              ],
            );
          }
          final list = res.data ?? const <DplProductionPlan>[];
          if (list.isEmpty) {
            return ListView(
              children: [
                const SizedBox(height: 60),
                const DplEmptyState(
                  icon: Icons.assignment_outlined,
                  title: 'No plans found',
                  message: 'Try adjusting the filters or upload a new plan.',
                ),
              ],
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) => _PlanRow(
              plan: list[i],
              onTap: () =>
                  context.push('/dpl/manager/plans/${list[i].id}'),
            ),
          );
        },
      ),
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (filterChips.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: filterChips,
            ),
          ),
        Expanded(child: body),
      ],
    );

    if (embedded) return content;

    return Scaffold(
      appBar: DplAppBar(
        title: 'Production Plans',
        actions: [
          IconButton(
            tooltip: 'Filter',
            icon: const Icon(Icons.filter_alt_outlined),
            onPressed: () => _openFilterSheet(context, ref),
          ),
        ],
      ),
      body: content,
    );
  }

  String _rangeLabel(DateTime? from, DateTime? to) {
    final f = DateFormat('dd MMM');
    if (from != null && to != null) {
      return '${f.format(from)} – ${f.format(to)}';
    }
    if (from != null) return 'From ${f.format(from)}';
    if (to != null) return 'Until ${f.format(to)}';
    return '';
  }

  Future<void> _openFilterSheet(BuildContext context, WidgetRef ref) async {
    final filters = ref.read(dplPlanListFiltersProvider);
    final machinesAsync = ref.read(dplMachinesProvider);
    final supervisorsAsync = ref.read(dplSupervisorsProvider);

    DateTime? from = filters.from;
    DateTime? to = filters.to;
    int? machineId = filters.machineId;
    int? supervisorId = filters.supervisorUserId;
    String? status = filters.status;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) {
        return StatefulBuilder(builder: (ctx, setSheet) {
          Future<void> pickDate(bool isFrom) async {
            final picked = await showDatePicker(
              context: ctx,
              initialDate: (isFrom ? from : to) ?? DateTime.now(),
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
            );
            if (picked != null) {
              setSheet(() {
                if (isFrom) {
                  from = picked;
                } else {
                  to = picked;
                }
              });
            }
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              16 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Filter Plans',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => pickDate(true),
                        icon: const Icon(Icons.date_range_outlined),
                        label: Text(
                          from == null
                              ? 'From'
                              : DateFormat('dd MMM yyyy').format(from!),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => pickDate(false),
                        icon: const Icon(Icons.event_outlined),
                        label: Text(
                          to == null
                              ? 'To'
                              : DateFormat('dd MMM yyyy').format(to!),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                machinesAsync.when(
                  loading: () => const SizedBox(
                    height: 56,
                    child: Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (res) {
                    if (res.isError) return const SizedBox.shrink();
                    final items = res.data ?? const [];
                    return DropdownButtonFormField<int?>(
                      initialValue: machineId,
                      decoration:
                          const InputDecoration(labelText: 'Machine'),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('All machines'),
                        ),
                        ...items.map(
                          (m) => DropdownMenuItem<int?>(
                            value: m.id,
                            child: Text(m.name),
                          ),
                        ),
                      ],
                      onChanged: (v) => setSheet(() => machineId = v),
                    );
                  },
                ),
                const SizedBox(height: 12),
                supervisorsAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (res) {
                    if (res.isError) return const SizedBox.shrink();
                    final items = res.data ?? const [];
                    return DropdownButtonFormField<int?>(
                      initialValue: supervisorId,
                      decoration:
                          const InputDecoration(labelText: 'Supervisor'),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('All supervisors'),
                        ),
                        ...items.map(
                          (s) => DropdownMenuItem<int?>(
                            value: s.userId,
                            child: Text(s.name),
                          ),
                        ),
                      ],
                      onChanged: (v) => setSheet(() => supervisorId = v),
                    );
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('All statuses'),
                    ),
                    ...DplPlanStatus.all.map(
                      (s) => DropdownMenuItem<String?>(
                        value: s,
                        child: Text(DplPlanStatus.label(s)),
                      ),
                    ),
                  ],
                  onChanged: (v) => setSheet(() => status = v),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          ref
                              .read(dplPlanListFiltersProvider.notifier)
                              .clear();
                          Navigator.of(ctx).pop();
                        },
                        child: const Text('Clear'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          ref
                              .read(dplPlanListFiltersProvider.notifier)
                              .update(DplPlanListFilters(
                                from: from,
                                to: to,
                                machineId: machineId,
                                supervisorUserId: supervisorId,
                                status: status,
                              ));
                          Navigator.of(ctx).pop();
                        },
                        child: const Text('Apply'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        });
      },
    );
  }
}

class _PlanRow extends StatelessWidget {
  final DplProductionPlan plan;
  final VoidCallback onTap;

  const _PlanRow({required this.plan, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final dateFmt = DateFormat('dd MMM yyyy');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(color: DplColors.divider),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 52,
                decoration: BoxDecoration(
                  color: VistarPalette.info,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${dateFmt.format(plan.planDate)} • ${plan.machineName.isEmpty ? "Machine #${plan.machineId}" : plan.machineName}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Supervisor: ${plan.supervisorName.isEmpty ? "—" : plan.supervisorName}',
                      style: TextStyle(color: DplColors.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Plan: ${fmt.format(plan.totalPlanQty)}  •  Actual: ${fmt.format(plan.totalActualQty)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              DplStatusBadge(status: plan.status),
            ],
          ),
        ),
      ),
    );
  }
}
