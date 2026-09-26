import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_refresh_icon_button.dart';
import '../../manager/widgets/dpl_part_filter_bar.dart';
import '../../manager/widgets/empty_state.dart';
import '../../manager/widgets/error_retry.dart';
import '../../models/dpl_dispatch_plan_actual.dart';
import '../providers/dispatch_plan_actual_provider.dart';

/// How the breakdown rows are ordered.
enum _SortKey {
  description('Description'),
  today('Today actual'),
  mtd('MTD actual'),
  till('Till-date actual'),
  variance('Till variance');

  final String label;
  const _SortKey(this.label);
}

/// Dispatch **Plan vs Actual** report screen.
///
/// Top: three period cards (Today / MTD / Till-date) showing planned vs
/// actual dispatch — re-aggregated from whatever rows the active filter
/// keeps, so the cards always match the list below. Then a reusable
/// plant / machine / description filter bar, a sort control, and the
/// per-(plant, machine, part) breakdown.
class DispatchPlanActualScreen extends ConsumerStatefulWidget {
  const DispatchPlanActualScreen({super.key});

  @override
  ConsumerState<DispatchPlanActualScreen> createState() =>
      _DispatchPlanActualScreenState();
}

class _DispatchPlanActualScreenState
    extends ConsumerState<DispatchPlanActualScreen> {
  DplPartFilter _filter = const DplPartFilter();
  _SortKey _sortKey = _SortKey.till;
  bool _descending = true;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(dplDispatchPlanActualProvider);

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Dispatch — Plan vs Actual',
        actions: [
          DplRefreshIconButton(
            onRefresh: () async {
              ref.invalidate(dplDispatchPlanActualProvider);
              try {
                await ref.read(dplDispatchPlanActualProvider.future);
              } catch (_) {}
            },
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => DplErrorRetry(
          message: e.toString(),
          onRetry: () => ref.invalidate(dplDispatchPlanActualProvider),
        ),
        data: (res) {
          if (res.isError) {
            return DplErrorRetry(
              message: res.error ?? 'Failed to load the report.',
              onRetry: () => ref.invalidate(dplDispatchPlanActualProvider),
            );
          }
          final report = res.data ?? const DplDispatchPlanActualReport();
          return _buildBody(report);
        },
      ),
    );
  }

  Widget _buildBody(DplDispatchPlanActualReport report) {
    // Machine roster for the filter bar chips.
    final machineRoster = <String>{
      for (final r in report.rows)
        if (r.machineName.trim().isNotEmpty) r.machineName.trim(),
    };

    // Client-side filter → sort. Cards below are computed from `filtered`
    // so they always match the visible list.
    final filtered = report.rows.where(_accepts).toList();
    final sorted = _sort(filtered);

    return Column(
      children: [
        Expanded(
          child: CustomScrollView(
            slivers: [
              // ── Period cards (Today / MTD / Till-date) ──
              SliverToBoxAdapter(
                child: _PeriodCards(rows: filtered),
              ),
              // ── Filter bar (plant / machine / description) ──
              SliverToBoxAdapter(
                child: DplPartFilterBar(
                  filter: _filter,
                  onChanged: (f) => setState(() => _filter = f),
                  availableMachineNames: machineRoster,
                  totalCount: report.rows.length,
                  matchedCount: filtered.length,
                  searchHint: 'Search description / part / customer PN',
                ),
              ),
              // ── Sort control ──
              SliverToBoxAdapter(
                child: _SortBar(
                  sortKey: _sortKey,
                  descending: _descending,
                  onKey: (k) => setState(() => _sortKey = k),
                  onToggleDir: () =>
                      setState(() => _descending = !_descending),
                ),
              ),
              // ── Breakdown list ──
              if (sorted.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 40),
                    child: DplEmptyState(
                      icon: report.rows.isEmpty
                          ? Icons.assessment_outlined
                          : Icons.filter_alt_off_rounded,
                      title: report.rows.isEmpty
                          ? 'No dispatch data yet'
                          : 'No parts match the filters',
                      message: report.rows.isEmpty
                          ? 'Plan vs actual will appear once trips are '
                              'planned and slips are dispatched.'
                          : 'Try a different search, plant or machine.',
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
                  sliver: SliverList.separated(
                    itemCount: sorted.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _BreakdownRowCard(row: sorted[i]),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Client-side filter for one row. Plant is matched on the row's
  /// explicit `plantCode` (exact), machine on a case-insensitive contains,
  /// and the free-text query across description / part / customer PN /
  /// machine.
  bool _accepts(DplDispatchPlanActualRow r) {
    final f = _filter;
    if (f.plantCode != null && r.plantCode != f.plantCode) return false;
    if (f.machineName != null &&
        !r.machineName.toLowerCase().contains(f.machineName!.toLowerCase())) {
      return false;
    }
    final q = f.query.trim().toLowerCase();
    if (q.isEmpty) return true;
    bool has(String s) => s.toLowerCase().contains(q);
    return has(r.customerPn) ||
        has(r.description) ||
        has(r.partName) ||
        has(r.machineName);
  }

  List<DplDispatchPlanActualRow> _sort(List<DplDispatchPlanActualRow> rows) {
    int cmp(DplDispatchPlanActualRow a, DplDispatchPlanActualRow b) {
      switch (_sortKey) {
        case _SortKey.description:
          return a.description
              .toLowerCase()
              .compareTo(b.description.toLowerCase());
        case _SortKey.today:
          return a.todayActual.compareTo(b.todayActual);
        case _SortKey.mtd:
          return a.mtdActual.compareTo(b.mtdActual);
        case _SortKey.till:
          return a.tillActual.compareTo(b.tillActual);
        case _SortKey.variance:
          return (a.tillActual - a.tillPlan)
              .compareTo(b.tillActual - b.tillPlan);
      }
    }

    final out = [...rows]..sort(cmp);
    if (_descending) {
      return out.reversed.toList();
    }
    return out;
  }
}

/// The three top summary cards. Each re-aggregates plan + actual across
/// the (filtered) rows passed in.
class _PeriodCards extends StatelessWidget {
  final List<DplDispatchPlanActualRow> rows;
  const _PeriodCards({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Row(
        children: [
          for (final p in DplPvaPeriod.values) ...[
            Expanded(child: _PeriodCard(period: p, rows: rows)),
            if (p != DplPvaPeriod.values.last) const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }
}

class _PeriodCard extends StatelessWidget {
  final DplPvaPeriod period;
  final List<DplDispatchPlanActualRow> rows;
  const _PeriodCard({required this.period, required this.rows});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final plan = rows.fold<int>(0, (s, r) => s + r.planFor(period));
    final actual = rows.fold<int>(0, (s, r) => s + r.actualFor(period));
    final pct = plan <= 0 ? null : (actual / plan * 100).round();
    final ink = _achievementInk(pct);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
        boxShadow: DplShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            period.label.toUpperCase(),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
              color: DplColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          // Actual — the hero number.
          Text(
            fmt.format(actual),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: ink,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            'of ${fmt.format(plan)} planned',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: DplColors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: plan <= 0 ? 0 : (actual / plan).clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: DplColors.neutralBg,
              valueColor: AlwaysStoppedAnimation(ink),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            pct == null ? 'No plan' : '$pct% achieved',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: ink,
            ),
          ),
        ],
      ),
    );
  }

  static Color _achievementInk(int? pct) {
    if (pct == null) return DplColors.textSecondary;
    if (pct >= 100) return DplColors.success;
    if (pct >= 70) return DplColors.warning;
    return DplColors.error;
  }
}

class _SortBar extends StatelessWidget {
  final _SortKey sortKey;
  final bool descending;
  final ValueChanged<_SortKey> onKey;
  final VoidCallback onToggleDir;
  const _SortBar({
    required this.sortKey,
    required this.descending,
    required this.onKey,
    required this.onToggleDir,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: Row(
        children: [
          Icon(Icons.sort_rounded,
              size: 16, color: DplColors.textSecondary),
          const SizedBox(width: 6),
          Text(
            'Sort',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              color: DplColors.textSecondary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<_SortKey>(
                isExpanded: true,
                value: sortKey,
                isDense: true,
                borderRadius: BorderRadius.circular(10),
                items: [
                  for (final k in _SortKey.values)
                    DropdownMenuItem(
                      value: k,
                      child: Text(
                        k.label,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
                onChanged: (k) {
                  if (k != null) onKey(k);
                },
              ),
            ),
          ),
          IconButton(
            tooltip: descending ? 'Descending' : 'Ascending',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              descending
                  ? Icons.arrow_downward_rounded
                  : Icons.arrow_upward_rounded,
              size: 18,
              color: DplColors.primaryDark,
            ),
            onPressed: onToggleDir,
          ),
        ],
      ),
    );
  }
}

class _BreakdownRowCard extends StatelessWidget {
  final DplDispatchPlanActualRow row;
  const _BreakdownRowCard({required this.row});

  @override
  Widget build(BuildContext context) {
    final subtitleBits = <String>[
      if (row.machineName.trim().isNotEmpty) row.machineName.trim(),
      if (row.plantName.trim().isNotEmpty)
        row.plantName.trim()
      else if (row.plantCode.trim().isNotEmpty)
        row.plantCode.trim(),
    ];
    final partLabel = row.partName.trim().isNotEmpty
        ? row.partName.trim()
        : (row.customerPn.trim().isNotEmpty ? row.customerPn.trim() : '—');

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
        boxShadow: DplShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (row.description.trim().isNotEmpty) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: DplColors.primaryTint,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    row.description.trim(),
                    style: TextStyle(
                      color: DplColors.primaryDark,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      partLabel,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitleBits.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        subtitleBits.join(' • '),
                        style: TextStyle(
                          color: DplColors.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final p in DplPvaPeriod.values) ...[
                Expanded(child: _PeriodCell(period: p, row: row)),
                if (p != DplPvaPeriod.values.last)
                  Container(
                    width: 1,
                    height: 30,
                    color: DplColors.divider,
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// One period's plan/actual inside a breakdown row.
class _PeriodCell extends StatelessWidget {
  final DplPvaPeriod period;
  final DplDispatchPlanActualRow row;
  const _PeriodCell({required this.period, required this.row});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final plan = row.planFor(period);
    final actual = row.actualFor(period);
    final ink = actual >= plan && plan > 0
        ? DplColors.success
        : (actual == 0 && plan == 0)
            ? DplColors.textTertiary
            : (actual < plan ? DplColors.warning : DplColors.textPrimary);

    return Column(
      children: [
        Text(
          period.label.toUpperCase(),
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
            color: DplColors.textSecondary,
          ),
        ),
        const SizedBox(height: 3),
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13.5,
              color: ink,
            ),
            children: [
              TextSpan(text: fmt.format(actual)),
              TextSpan(
                text: ' / ${fmt.format(plan)}',
                style: TextStyle(
                  color: DplColors.textSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 1),
        Text(
          'act / plan',
          style: TextStyle(
            fontSize: 8.5,
            fontWeight: FontWeight.w600,
            color: DplColors.textTertiary,
          ),
        ),
      ],
    );
  }
}
