import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_empty_state.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_refresh_icon_button.dart';
import '../../core/widgets/dpl_shimmer.dart';
import '../../core/widgets/dpl_stat_tile.dart';
import '../../manager/widgets/dpl_date_picker_field.dart';
import '../../manager/widgets/machine_summary_card.dart';
import '../../models/dpl_dashboard_summary.dart';
import '../providers/qa_production_provider.dart';

/// What QA lands on: machine-wise plan vs actual for a date, defaulted to
/// whatever shift is running right now.
///
/// This renders the SAME `/manager/dashboard` payload and the SAME
/// [DplMachineSummaryCard] the DPL Manager dashboard uses — the requirement
/// was explicitly "give the same view". Reusing the endpoint and the widget is
/// what keeps that true as either side changes.
///
/// Unlike the Manager dashboard, this one does not merge a machine's several
/// shifts into one card: QA is filtered to a single shift by default, so each
/// machine already has exactly one row and a tap can go straight to the plan
/// instead of opening a picker.
class QaProductionScreen extends ConsumerWidget {
  final bool showAppBar;

  const QaProductionScreen({super.key, this.showAppBar = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final date = ref.watch(qaDateProvider);
    final async = ref.watch(qaDashboardProvider);
    final shiftCode = effectiveShiftCode(ref);

    final body = RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(qaDashboardProvider);
        ref.invalidate(qaCurrentShiftProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
        children: [
          _DateAndShiftBar(date: date, shiftCode: shiftCode),
          const SizedBox(height: 14),
          ...async.when(
            loading: () => const [DplDashboardShimmer()],
            error: (e, _) => [
              DplInlineErrorRetry(
                message: e.toString(),
                onRetry: () => ref.invalidate(qaDashboardProvider),
              ),
            ],
            data: (res) {
              if (res.isError || res.data == null) {
                return [
                  DplInlineErrorRetry(
                    message: res.error ?? 'Failed to load production.',
                    onRetry: () => ref.invalidate(qaDashboardProvider),
                  ),
                ];
              }
              return _content(context, ref, res.data!, shiftCode);
            },
          ),
        ],
      ),
    );

    if (!showAppBar) return body;

    return Scaffold(
      appBar: DplAppBar(
        title: 'QA — Production',
        subtitle: _ShiftSubtitle(shiftCode: shiftCode),
        actions: [
          DplRefreshIconButton(
            onRefresh: () async {
              ref.invalidate(qaDashboardProvider);
              ref.invalidate(qaCurrentShiftProvider);
            },
          ),
        ],
      ),
      body: body,
    );
  }

  List<Widget> _content(
    BuildContext context,
    WidgetRef ref,
    DplDashboardSummary summary,
    String? shiftCode,
  ) {
    final rows = filterMachines(summary.machines, shiftCode);
    final fmt = NumberFormat.decimalPattern();

    // Totals follow the filter, so the numbers on screen always describe the
    // rows underneath them rather than the whole day.
    final planQty = rows.fold<int>(0, (s, m) => s + m.planQty);
    final actualQty = rows.fold<int>(0, (s, m) => s + m.actualQty);
    final pct = planQty <= 0 ? 0 : ((actualQty / planQty) * 100).round();

    return [
      DplCard(
        child: Row(
          children: [
            Expanded(
              child: DplStatTile(
                label: 'Plan Qty',
                value: fmt.format(planQty),
              ),
            ),
            Expanded(
              child: DplStatTile(
                label: 'Actual',
                value: fmt.format(actualQty),
              ),
            ),
            Expanded(
              child: DplStatTile(
                label: 'Completion',
                value: '$pct%',
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _ShiftFilterRow(shifts: summary.shifts, selected: shiftCode),
      const SizedBox(height: 14),
      const Text(
        'Machines',
        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
      ),
      const SizedBox(height: 8),
      if (rows.isEmpty)
        DplEmptyView(
          title: shiftCode == null
              ? 'No production planned'
              : 'Nothing planned for Shift $shiftCode',
          message: shiftCode == null
              ? 'There is no plan for the selected date.'
              : 'Try another shift, or switch to All shifts to see the whole day.',
          icon: Icons.inbox_outlined,
        )
      else
        ...rows.map(
          (m) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DplMachineSummaryCard(
              machineName: m.machineName,
              machineId: m.machineId,
              shiftLabels: [
                if (m.shiftCode.trim().isNotEmpty) 'Shift ${m.shiftCode}',
              ],
              status: m.status,
              planQty: m.planQty,
              actualQty: m.actualQty,
              completionPct: m.completionPct,
              supervisorName: m.supervisorName,
              onTap: m.planId == null
                  ? null
                  : () => context.push('/dpl/qa/plans/${m.planId}'),
            ),
          ),
        ),
    ];
  }
}

/// Date picker plus a plain-language note about which shift is on screen.
class _DateAndShiftBar extends ConsumerWidget {
  final DateTime date;
  final String? shiftCode;

  const _DateAndShiftBar({required this.date, required this.shiftCode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DplDatePickerField(
      label: 'Production date',
      value: date,
      onChanged: (d) => ref.read(qaDateProvider.notifier).set(d),
      // A plan cannot exist before the module did, and looking a day ahead is
      // legitimate (plans are published in advance).
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
  }
}

/// Shift chips: every configured shift plus "All shifts".
///
/// The chip matching the running shift carries a dot so the operator can tell
/// "this is live" from "I am looking at an earlier shift".
class _ShiftFilterRow extends ConsumerWidget {
  final List<DplDashboardShiftRollup> shifts;
  final String? selected;

  const _ShiftFilterRow({required this.shifts, required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liveShift =
        ref.watch(qaCurrentShiftProvider).asData?.value.data?.code;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final s in shifts)
          _Chip(
            label: s.shiftCode.trim().isEmpty
                ? s.shiftName
                : 'Shift ${s.shiftCode}',
            isLive: liveShift != null &&
                liveShift.trim().toUpperCase() ==
                    s.shiftCode.trim().toUpperCase(),
            selected: selected != null &&
                selected!.trim().toUpperCase() ==
                    s.shiftCode.trim().toUpperCase(),
            onTap: () =>
                ref.read(qaShiftFilterProvider.notifier).pick(s.shiftCode),
          ),
        _Chip(
          label: 'All shifts',
          isLive: false,
          selected: selected == null,
          onTap: () => ref.read(qaShiftFilterProvider.notifier).all(),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool isLive;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.selected,
    required this.isLive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? VistarPalette.infoBg : VistarPalette.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? VistarPalette.info
                  : VistarPalette.line,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLive) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: VistarPalette.ok,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: selected
                      ? VistarPalette.infoInk
                      : VistarPalette.txt,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Shift A • live" under the app-bar title.
class _ShiftSubtitle extends ConsumerWidget {
  final String? shiftCode;

  const _ShiftSubtitle({required this.shiftCode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(qaShiftFilterProvider);
    final live = ref.watch(qaCurrentShiftProvider).asData?.value.data;

    String text;
    if (shiftCode == null) {
      text = 'All shifts';
    } else if (filter.auto && live != null) {
      text = 'Shift ${live.code} • running now';
    } else {
      text = 'Shift $shiftCode';
    }

    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: VistarPalette.txt2,
      ),
    );
  }
}
