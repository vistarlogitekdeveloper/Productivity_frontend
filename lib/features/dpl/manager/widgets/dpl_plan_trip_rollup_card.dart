import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/dpl_theme.dart';
import '../../models/dpl_plant.dart';
import '../providers/dpl_plan_trip_rollup_provider.dart';

/// Header card on the Plan Trip screen that surfaces three lifetime /
/// windowed rollups — Today produced, Total produced (range), Total
/// dispatched (range) — with a machine + date-range filter row on top.
///
/// Reads its filter state from [dplPlanTripRollupFilterProvider] and the
/// three rollup providers in the same file. The machine dropdown is
/// populated from the passed-in plant list to avoid a second `/plants`
/// fetch — the parent screen already watches `dplPlantsProvider`.
class DplPlanTripRollupCard extends ConsumerWidget {
  final List<DplPlant> plants;

  const DplPlanTripRollupCard({super.key, required this.plants});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(dplPlanTripRollupFilterProvider);
    final todayRes = ref.watch(dplPlanTripTodayProductionProvider);
    final totalRes = ref.watch(dplPlanTripProductionRollupProvider);
    final dispRes = ref.watch(dplPlanTripDispatchedRollupProvider);

    final fmt = NumberFormat.decimalPattern();

    int? todayProduced;
    final todayData = todayRes.asData?.value;
    if (todayData != null && !todayData.isError) {
      todayProduced = todayData.data?.totals.totalActualQty;
    }

    int? totalProduced;
    final totalData = totalRes.asData?.value;
    if (totalData != null && !totalData.isError) {
      totalProduced = totalData.data?.totals.totalActualQty;
    }

    int? totalDispatched;
    final dispData = dispRes.asData?.value;
    if (dispData != null && !dispData.isError) {
      totalDispatched = dispData.data?.totals.dispatchedQty;
    }

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
              Text('Production rollup', style: DplText.h3()),
              const Spacer(),
              Text(
                _rangeLabel(filter),
                style: TextStyle(
                  color: DplColors.textSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _FilterRow(plants: plants),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _RollupTile(
                  label: 'Today produced',
                  value: _formatOrPlaceholder(todayProduced, fmt),
                  unit: 'NOS',
                  loading: todayRes.isLoading,
                  error: _errorOf(todayRes.asData?.value.error),
                  accent: DplColors.primaryDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _RollupTile(
                  label: 'Total produced',
                  value: _formatOrPlaceholder(totalProduced, fmt),
                  unit: 'NOS',
                  loading: totalRes.isLoading,
                  error: _errorOf(totalRes.asData?.value.error),
                  accent: DplColors.success,
                  background: DplColors.successBg,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _RollupTile(
                  label: 'Total dispatched',
                  value: _formatOrPlaceholder(totalDispatched, fmt),
                  unit: 'NOS',
                  loading: dispRes.isLoading,
                  error: _errorOf(dispRes.asData?.value.error),
                  accent: DplColors.info,
                  background: DplColors.infoBg,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String? _errorOf(String? envelopeError) => envelopeError;

  static String _formatOrPlaceholder(int? value, NumberFormat fmt) =>
      value == null ? '—' : fmt.format(value);

  static String _rangeLabel(DplPlanTripRollupFilter f) {
    if (f.from == null && f.to == null) return 'Till date';
    final df = DateFormat('dd MMM');
    if (f.from != null && f.to != null) {
      return '${df.format(f.from!)} – ${df.format(f.to!)}';
    }
    if (f.from != null) return 'From ${df.format(f.from!)}';
    return 'Until ${df.format(f.to!)}';
  }
}

class _FilterRow extends ConsumerWidget {
  final List<DplPlant> plants;
  const _FilterRow({required this.plants});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(dplPlanTripRollupFilterProvider);
    final ctrl = ref.read(dplPlanTripRollupFilterProvider.notifier);

    // Flatten every plant's machines into one dropdown so the user can
    // pick across plants. Each entry carries its plant code so we can
    // set both filters in one tap (machine implies plant).
    final entries = <_MachineEntry>[
      const _MachineEntry(plantCode: null, machineId: null, label: 'All machines'),
      for (final p in plants)
        for (final m in p.machines)
          _MachineEntry(
            plantCode: p.code,
            machineId: m.id,
            label: '${m.label} · ${p.name}',
          ),
    ];

    final selected = entries.firstWhere(
      (e) => e.machineId == filter.machineId && e.plantCode == filter.plantCode,
      orElse: () => entries.first,
    );

    return Row(
      children: [
        Expanded(
          flex: 3,
          child: _DropdownField(
            icon: Icons.precision_manufacturing_outlined,
            child: DropdownButton<_MachineEntry>(
              isExpanded: true,
              isDense: true,
              underline: const SizedBox.shrink(),
              value: selected,
              items: [
                for (final e in entries)
                  DropdownMenuItem(value: e, child: Text(e.label)),
              ],
              onChanged: (e) {
                if (e == null) return;
                ctrl.set(filter.copyWith(
                  plantCode: e.plantCode,
                  machineId: e.machineId,
                ));
              },
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: _DropdownField(
            icon: Icons.event_outlined,
            child: InkWell(
              onTap: () => _pickRange(context, ref),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        filter.from == null && filter.to == null
                            ? 'Till date'
                            : _shortRange(filter),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: DplColors.textPrimary,
                        ),
                      ),
                    ),
                    if (filter.from != null || filter.to != null)
                      GestureDetector(
                        onTap: () => ctrl.set(
                          filter.copyWith(from: null, to: null),
                        ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: DplColors.textSecondary,
                          ),
                        ),
                      )
                    else
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: DplColors.textSecondary,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _shortRange(DplPlanTripRollupFilter f) {
    final df = DateFormat('dd MMM');
    if (f.from != null && f.to != null) {
      return '${df.format(f.from!)} – ${df.format(f.to!)}';
    }
    if (f.from != null) return 'From ${df.format(f.from!)}';
    return 'Until ${df.format(f.to!)}';
  }

  Future<void> _pickRange(BuildContext context, WidgetRef ref) async {
    final filter = ref.read(dplPlanTripRollupFilterProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final result = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: today,
      initialDateRange: filter.from != null && filter.to != null
          ? DateTimeRange(start: filter.from!, end: filter.to!)
          : null,
    );
    if (result == null) return;
    ref.read(dplPlanTripRollupFilterProvider.notifier).set(
          filter.copyWith(from: result.start, to: result.end),
        );
  }
}

class _MachineEntry {
  final String? plantCode;
  final int? machineId;
  final String label;
  const _MachineEntry({
    required this.plantCode,
    required this.machineId,
    required this.label,
  });

  @override
  bool operator ==(Object other) =>
      other is _MachineEntry &&
      other.plantCode == plantCode &&
      other.machineId == machineId;

  @override
  int get hashCode => Object.hash(plantCode, machineId);
}

class _DropdownField extends StatelessWidget {
  final IconData icon;
  final Widget child;
  const _DropdownField({required this.icon, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: DplColors.neutralBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DplColors.divider),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: DplColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _RollupTile extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final bool loading;
  final String? error;
  final Color? accent;
  final Color? background;
  const _RollupTile({
    required this.label,
    required this.value,
    required this.unit,
    this.loading = false,
    this.error,
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
            style: TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 4),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (error != null)
            Tooltip(
              message: error!,
              child: Row(
                children: [
                  Icon(Icons.error_outline,
                      size: 16, color: DplColors.error),
                  SizedBox(width: 4),
                  Text(
                    'Error',
                    style: TextStyle(
                      color: DplColors.error,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            )
          else
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
                      style: TextStyle(
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
