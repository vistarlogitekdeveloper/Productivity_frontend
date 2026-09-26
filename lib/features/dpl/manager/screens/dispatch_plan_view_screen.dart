import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_refresh_icon_button.dart';
import '../../models/dpl_part_field.dart';
import '../../models/dpl_plant.dart';
import '../../summary/providers/plants_provider.dart';
import '../providers/dpl_part_field_provider.dart';
import '../widgets/dpl_part_filter_bar.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_retry.dart';

/// Read-only daily dispatch plan derived from the 3 master fields.
///
/// `dispatch = (stocking_norm + customer_today_plan) − customer_opening_stock`
///
/// For each part, computed only when all 3 inputs are non-null. Parts
/// missing any input are listed in a "blocked" section so the manager
/// can jump back to the hub to fill them in.
class DispatchPlanViewScreen extends ConsumerStatefulWidget {
  const DispatchPlanViewScreen({super.key});

  @override
  ConsumerState<DispatchPlanViewScreen> createState() =>
      _DispatchPlanViewScreenState();
}

class _DispatchPlanViewScreenState
    extends ConsumerState<DispatchPlanViewScreen> {
  /// Search + plant + machine filter applied to the joined rows
  /// before the ready/blocked split. The summary tile counts also
  /// reflect the filtered subset so the totals stay consistent with
  /// what's on screen.
  DplPartFilter _filter = const DplPartFilter();

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

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Daily Dispatch Plan',
        actions: [
          IconButton(
            tooltip: 'Edit inputs',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => context.go('/dpl/manager/dispatch-planning'),
          ),
          DplRefreshIconButton(
            onRefresh: () async {
              for (final k in DplPartFieldKind.values) {
                ref.invalidate(dplPartFieldPageProvider(k));
              }
            },
          ),
        ],
      ),
      body: _buildBody(context, ref, norms, stocks, plans),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<dynamic> norms,
    AsyncValue<dynamic> stocks,
    AsyncValue<dynamic> plans,
  ) {
    // Any in-flight or errored fetch blocks the table — we need all 3.
    if (norms.isLoading || stocks.isLoading || plans.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final err =
        norms.error ?? stocks.error ?? plans.error;
    if (err != null) {
      return DplErrorRetry(
        message: err.toString(),
        onRetry: () {
          for (final k in DplPartFieldKind.values) {
            ref.invalidate(dplPartFieldPageProvider(k));
          }
        },
      );
    }
    final normsRes = (norms as AsyncData).value;
    final stocksRes = (stocks as AsyncData).value;
    final plansRes = (plans as AsyncData).value;
    if (normsRes.isError || stocksRes.isError || plansRes.isError) {
      return DplErrorRetry(
        message: normsRes.error ?? stocksRes.error ?? plansRes.error ?? 'Failed.',
        onRetry: () {
          for (final k in DplPartFieldKind.values) {
            ref.invalidate(dplPartFieldPageProvider(k));
          }
        },
      );
    }

    final DplPartFieldPage normsPage = normsRes.data!;
    final DplPartFieldPage stocksPage = stocksRes.data!;
    final DplPartFieldPage plansPage = plansRes.data!;

    final byPart = _joinByPart(normsPage, stocksPage, plansPage);
    if (byPart.isEmpty) {
      return const DplEmptyState(
        icon: Icons.inbox_outlined,
        title: 'No parts yet',
        message:
            'Configure stocking norms / opening stocks / today\'s plans first.',
      );
    }

    final plants =
        ref.watch(dplPlantsProvider).asData?.value.data ?? const <DplPlant>[];
    final allRows = byPart.values.toList(growable: false);
    final filtered = allRows
        .where((r) => _filter.accepts(
              customerPn: r.customerPn,
              description: r.description,
              partName: r.partName,
              machineName: r.machineName,
              plants: plants,
            ))
        .toList(growable: false);
    final machineRoster = <String>{
      for (final r in allRows)
        if (r.machineName.isNotEmpty) r.machineName,
    };

    final ready = <_PlanRow>[];
    final blocked = <_PlanRow>[];
    for (final row in filtered) {
      (row.isReady ? ready : blocked).add(row);
    }
    // Ready rows: dispatch DESC then description ASC. Blocked rows:
    // description ASC.
    ready.sort((a, b) {
      final byDispatch = (b.dispatch ?? 0).compareTo(a.dispatch ?? 0);
      if (byDispatch != 0) return byDispatch;
      return a.description.compareTo(b.description);
    });
    blocked.sort((a, b) => a.description.compareTo(b.description));

    final totalDispatch = ready.fold<int>(0, (s, r) => s + (r.dispatch ?? 0));

    return Column(
      children: [
        DplPartFilterBar(
          filter: _filter,
          onChanged: (f) => setState(() => _filter = f),
          availableMachineNames: machineRoster,
          totalCount: allRows.length,
          matchedCount: filtered.length,
        ),
        Expanded(
          child: filtered.isEmpty
              ? _NoMatchesState(
                  onClear: () =>
                      setState(() => _filter = const DplPartFilter()),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 22),
                  children: [
                    _SummaryCard(
                      totalDispatch: totalDispatch,
                      readyCount: ready.length,
                      blockedCount: blocked.length,
                    ),
                    const SizedBox(height: 12),
                    if (ready.isNotEmpty) ...[
                      _SectionHeader(
                        label: 'Ready (${ready.length})',
                        colour: DplColors.success,
                      ),
                      for (final row in ready)
                        _PlanRowCard(row: row, ready: true),
                      const SizedBox(height: 14),
                    ],
                    if (blocked.isNotEmpty) ...[
                      _SectionHeader(
                        label: 'Missing inputs (${blocked.length})',
                        colour: DplColors.warning,
                      ),
                      for (final row in blocked)
                        _PlanRowCard(row: row, ready: false),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  /// Join the 3 endpoint pages by `partId`. Each row carries whatever
  /// values are present; null is preserved so the UI can show "—" for
  /// missing inputs and `isReady` knows what's blocked.
  Map<int, _PlanRow> _joinByPart(
    DplPartFieldPage norms,
    DplPartFieldPage stocks,
    DplPartFieldPage plans,
  ) {
    final out = <int, _PlanRow>{};
    void merge(
      DplPartFieldPage page,
      _PlanRow Function(_PlanRow current, int? value) update,
    ) {
      for (final e in page.entries) {
        final cur = out[e.partId] ??
            _PlanRow(
              partId: e.partId,
              customerPn: e.customerPn,
              description: e.description,
              partName: e.partName,
              machineName: e.machineName,
            );
        out[e.partId] = update(cur, e.value);
      }
    }

    merge(norms, (cur, v) => cur.copyWith(stockingNorm: v));
    merge(stocks, (cur, v) => cur.copyWith(customerOpeningStock: v));
    merge(plans, (cur, v) => cur.copyWith(customerTodayPlan: v));
    return out;
  }
}

class _NoMatchesState extends StatelessWidget {
  final VoidCallback onClear;
  const _NoMatchesState({required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_alt_off_rounded,
              size: 56,
              color: DplColors.textTertiary,
            ),
            const SizedBox(height: 12),
            const Text(
              'No parts match the current filters',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              'Try a different search, plant, or machine.',
              style: TextStyle(
                color: DplColors.textSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Clear filters'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final int totalDispatch;
  final int readyCount;
  final int blockedCount;
  const _SummaryCard({
    required this.totalDispatch,
    required this.readyCount,
    required this.blockedCount,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
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
              Text('Today\'s total', style: DplText.h3()),
              const Spacer(),
              Text(
                DateFormat('EEE, dd MMM').format(DateTime.now()),
                style: TextStyle(
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
                  label: 'Dispatch',
                  value: fmt.format(totalDispatch),
                  unit: 'NOS',
                  accent: DplColors.primaryDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SummaryTile(
                  label: 'Ready',
                  value: '$readyCount',
                  unit: 'parts',
                  accent: DplColors.success,
                  background: DplColors.successBg,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SummaryTile(
                  label: 'Blocked',
                  value: '$blockedCount',
                  unit: 'parts',
                  accent:
                      blockedCount > 0 ? DplColors.warning : DplColors.textPrimary,
                  background: blockedCount > 0 ? DplColors.warningBg : null,
                ),
              ),
            ],
          ),
        ],
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
            style: TextStyle(
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

class _SectionHeader extends StatelessWidget {
  final String label;
  final Color colour;
  const _SectionHeader({required this.label, required this.colour});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
              color: DplColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanRowCard extends StatelessWidget {
  final _PlanRow row;
  final bool ready;
  const _PlanRowCard({required this.row, required this.ready});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: ready ? DplColors.divider : DplColors.warning,
          width: ready ? 1.0 : 1.4,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: DplColors.primaryTint,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  row.description.isEmpty ? '-' : row.description,
                  style: TextStyle(
                    color: DplColors.primaryDark,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      row.partName.isEmpty ? row.customerPn : row.partName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      row.customerPn,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: DplColors.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (ready)
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: fmt.format(row.dispatch ?? 0),
                        style: TextStyle(
                          color: DplColors.primaryDark,
                          fontWeight: FontWeight.w800,
                          fontSize: 22,
                        ),
                      ),
                      TextSpan(
                        text: '  NOS',
                        style: TextStyle(
                          color: DplColors.textSecondary,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Text(
                  '—',
                  style: TextStyle(
                    color: DplColors.textTertiary,
                    fontWeight: FontWeight.w800,
                    fontSize: 22,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InputChip(
                label: 'Stocking norm',
                value: row.stockingNorm,
                fmt: fmt,
              ),
              _InputChip(
                label: 'Today\'s plan',
                value: row.customerTodayPlan,
                fmt: fmt,
              ),
              _InputChip(
                label: 'Opening stock',
                value: row.customerOpeningStock,
                fmt: fmt,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InputChip extends StatelessWidget {
  final String label;
  final int? value;
  final NumberFormat fmt;
  const _InputChip({
    required this.label,
    required this.value,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    final missing = value == null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: missing ? DplColors.warningBg : DplColors.neutralBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label  ',
              style: TextStyle(
                color: DplColors.textSecondary,
                fontWeight: FontWeight.w700,
                fontSize: 10.5,
                letterSpacing: 0.5,
              ),
            ),
            TextSpan(
              text: missing ? 'not set' : fmt.format(value),
              style: TextStyle(
                color: missing ? DplColors.warning : DplColors.textPrimary,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────── Computed-row model ──────────────

/// Joined row across the 3 endpoints. Computes `dispatch` on the fly
/// only when all 3 inputs are present (ensures the formula doesn't
/// silently swallow missing data).
class _PlanRow {
  final int partId;
  final String customerPn;
  final String description;
  final String partName;
  final String machineName;
  final int? stockingNorm;
  final int? customerOpeningStock;
  final int? customerTodayPlan;

  const _PlanRow({
    required this.partId,
    this.customerPn = '',
    this.description = '',
    this.partName = '',
    this.machineName = '',
    this.stockingNorm,
    this.customerOpeningStock,
    this.customerTodayPlan,
  });

  _PlanRow copyWith({
    int? stockingNorm,
    int? customerOpeningStock,
    int? customerTodayPlan,
  }) {
    return _PlanRow(
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

  /// `(stocking_norm + customer_today_plan) − customer_opening_stock`,
  /// clamped at 0 (never dispatch a negative quantity).
  int? get dispatch {
    if (!isReady) return null;
    final raw = stockingNorm! + customerTodayPlan! - customerOpeningStock!;
    return raw < 0 ? 0 : raw;
  }
}
