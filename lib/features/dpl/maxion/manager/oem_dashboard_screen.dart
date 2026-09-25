import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_empty_state.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_progress_bar.dart';
import '../../core/widgets/dpl_stat_tile.dart';
import '../../models/dpl_oem_dashboard.dart';
import 'manager_maxion_providers.dart';

/// Human labels for the dashboard's `attention` counters (API.md §11.1).
const Map<String, String> dplAttentionLabels = {
  'half_pallets_over_7_days': 'Half pallets older than 7 days',
  'pallets_not_put_away': 'Pallets not put away',
  'wheels_in_quarantine': 'Wheels in quarantine (returns)',
  'reversals_pending': 'Shipment reversals awaiting approval',
  'adjustments_pending': 'Stock adjustments awaiting approval',
  'counts_awaiting_approval': 'Rack counts awaiting approval',
  'returns_open': 'Customer returns still open',
};

const Map<String, IconData> _attentionIcons = {
  'half_pallets_over_7_days': Icons.hourglass_bottom,
  'pallets_not_put_away': Icons.move_to_inbox_outlined,
  'wheels_in_quarantine': Icons.report_gmailerrorred_outlined,
  'reversals_pending': Icons.undo,
  'adjustments_pending': Icons.tune,
  'counts_awaiting_approval': Icons.fact_check_outlined,
  'returns_open': Icons.assignment_return_outlined,
};

String dplAttentionLabel(String key) {
  final known = dplAttentionLabels[key];
  if (known != null) return known;
  final words = key.replaceAll('_', ' ');
  return words.isEmpty ? key : words[0].toUpperCase() + words.substring(1);
}

/// The manager's home screen: each lane's plan against dispatch today and
/// month to date, stock on hand, and what needs somebody's attention.
class DplOemDashboardScreen extends ConsumerWidget {
  final bool showAppBar;

  const DplOemDashboardScreen({super.key, this.showAppBar = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dplOemDashboardProvider);
    Future<void> refresh() => ref.refresh(dplOemDashboardProvider.future);

    final body = async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => DplInlineErrorRetry(message: e.toString(), onRetry: refresh),
      data: (res) {
        if (res.isError || res.data == null) {
          return DplInlineErrorRetry(
            message: res.floorMessage.isEmpty ? 'Could not load the dashboard.' : res.floorMessage,
            onRetry: refresh,
          );
        }
        return RefreshIndicator(onRefresh: refresh, child: _DashboardBody(dashboard: res.data!));
      },
    );

    if (!showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'OEM dashboard',
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(dplOemDashboardProvider),
          ),
        ],
      ),
      body: body,
    );
  }
}

class _DashboardBody extends StatelessWidget {
  final DplOemDashboard dashboard;

  const _DashboardBody({required this.dashboard});

  @override
  Widget build(BuildContext context) {
    final d = dashboard;
    final attention = d.attention.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return ListView(
      padding: const EdgeInsets.all(DplSpacing.md),
      children: [
        if (d.date.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: DplSpacing.sm),
            child: Text('Plant day ${d.date} · month to date from the 1st', style: DplText.caption()),
          ),
        _section('Lanes'),
        if (d.lanes.isEmpty)
          const DplEmptyView(
            title: 'No lanes yet',
            message: 'Nothing is planned or dispatched against a lane. Set up lanes under Logistics masters.',
            icon: Icons.local_shipping_outlined,
          )
        else
          for (final lane in d.lanes) _LaneCard(lane: lane),
        const SizedBox(height: DplSpacing.md),
        _section('Stock'),
        DplCard(
          child: Wrap(
            spacing: DplSpacing.xxl,
            runSpacing: DplSpacing.md,
            children: [
              DplStatTile(label: 'On hand', value: '${d.onHandQty}'),
              DplStatTile(label: 'Unlabelled (opening)', value: '${d.unlabelledQty}'),
              DplStatTile(label: 'Loaded, not dispatched', value: '${d.loadedQty}'),
            ],
          ),
        ),
        const SizedBox(height: DplSpacing.lg),
        _section('Needs attention'),
        DplCard(
          padding: const EdgeInsets.symmetric(vertical: DplSpacing.xs),
          child: attention.isEmpty
              ? const ListTile(
                  leading: Icon(Icons.check_circle_outline, color: DplColors.success),
                  title: Text('Nothing needs attention right now.'),
                )
              : Column(
                  children: [
                    for (final e in attention)
                      ListTile(
                        dense: true,
                        leading: Icon(_attentionIcons[e.key] ?? Icons.flag_outlined, color: DplColors.warning),
                        title: Text(dplAttentionLabel(e.key)),
                        trailing: Text('${e.value}', style: DplText.numMd().copyWith(color: DplColors.warning)),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: DplSpacing.lg),
        _section('Returns this month'),
        DplCard(
          padding: const EdgeInsets.symmetric(vertical: DplSpacing.xs),
          child: d.returnsMtd.isEmpty
              ? const ListTile(title: Text('No wheels returned this month.'))
              : Column(
                  children: [
                    for (final r in d.returnsMtd)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.assignment_return_outlined),
                        title: Text(r.consignee.isEmpty ? 'No consignee recorded' : r.consignee),
                        trailing: Text('${r.qty} wheels', style: DplText.body()),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: DplSpacing.xxl),
      ],
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: DplSpacing.sm),
        child: Text(title, style: DplText.h3()),
      );
}

class _LaneCard extends StatelessWidget {
  final DplLaneStats lane;

  const _LaneCard({required this.lane});

  @override
  Widget build(BuildContext context) {
    final planned = lane.plannedToday;
    final done = lane.dispatchedToday;
    final ratio = planned <= 0 ? (done > 0 ? 1.0 : 0.0) : done / planned;
    final pct = lane.fulfilmentTodayPct;
    final color = pct == null
        ? DplColors.neutral
        : pct >= 100
            ? DplColors.success
            : pct >= 70
                ? DplColors.warning
                : DplColors.error;

    return DplCard(
      margin: const EdgeInsets.only(bottom: DplSpacing.md),
      accentColor: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(lane.name.isEmpty ? lane.plantCode : lane.name, style: DplText.h3())),
              if (lane.plantCode.isNotEmpty) Text(lane.plantCode, style: DplText.caption()),
            ],
          ),
          const SizedBox(height: DplSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Text('Today: $done of $planned wheels dispatched', style: DplText.bodySm()),
              ),
              Text(
                pct == null ? '—' : '${pct.toStringAsFixed(pct == pct.roundToDouble() ? 0 : 1)}%',
                style: DplText.numMd().copyWith(color: color),
              ),
            ],
          ),
          const SizedBox(height: DplSpacing.xs),
          DplProgressBar(value: ratio, color: color),
          const SizedBox(height: DplSpacing.md),
          Wrap(
            spacing: DplSpacing.xl,
            runSpacing: DplSpacing.sm,
            children: [
              DplStatTile(label: 'MTD wheels', value: '${lane.dispatchedMtd}', valueStyle: DplText.numMd()),
              DplStatTile(label: 'Pallets MTD', value: '${lane.palletsMtd}', valueStyle: DplText.numMd()),
              DplStatTile(label: 'Open trips', value: '${lane.openTrips}', valueStyle: DplText.numMd()),
              DplStatTile(
                label: 'Avg at dock',
                value: lane.avgMinutesAtDock == null ? '—' : '${lane.avgMinutesAtDock}',
                suffix: lane.avgMinutesAtDock == null ? null : ' min',
                valueStyle: DplText.numMd(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
