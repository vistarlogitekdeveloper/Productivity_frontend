import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/vistar_palette.dart';
import '../../../../core/widgets/shimmer_skeleton.dart';
import '../../../auth/auth_provider.dart';
import '../../core/design/dpl_theme.dart';
import '../../manager/widgets/empty_state.dart';
import '../../manager/widgets/error_retry.dart';
import '../../models/dpl_dispatch_plan_actual.dart';
import '../../models/dpl_plant.dart';
import '../providers/dispatch_plan_actual_provider.dart';
import '../providers/dispatch_trips_provider.dart';
import '../providers/plants_provider.dart';
import '../providers/production_summary_provider.dart';
import '../widgets/open_trips_section.dart';
import '../widgets/plant_card.dart';
import 'dispatch_plan_actual_screen.dart';
import 'production_summary_screen.dart';

/// New "select a plant first" landing screen for the Dispatch / QA /
/// PDI shell. Replaces the old bucket-first production summary view.
///
/// The user picks one of the three plants → drills into its production
/// summary (filtered to that plant's machines). Slips, in turn, are
/// scoped to a single plant in the new multi-item flow, so plant
/// selection is the entry point for all dispatch work.
class PlantLandingScreen extends ConsumerWidget {
  final bool showAppBar;
  const PlantLandingScreen({super.key, this.showAppBar = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plantsAsync = ref.watch(dplPlantsProvider);
    // A manager reaches this shell view-only via the dashboard toggle —
    // the Open Trips section is the dispatcher's "cut slips" action queue,
    // so it's hidden for managers (they still get the read-only totals,
    // plant cards and the slip pipeline tab).
    final role = ref.watch(authControllerProvider).asData?.value?.role ?? '';
    final isManager = AppConstants.isDplManagerRole(role);

    final body = RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(dplPlantsProvider);
        ref.invalidate(dplProductionSummaryProvider);
        ref.invalidate(dplOpenTripsProvider);
        // Per-plant production-summary family — drives the
        // "Out of stock" availability hint on each trip-plan row.
        // Without invalidating the whole family, stale bucket data
        // can mask an inventory bump that just arrived on the wire.
        ref.invalidate(dplProductionSummaryByPlantProvider);
        try {
          await ref.read(dplPlantsProvider.future);
          await ref.read(dplProductionSummaryProvider.future);
          await ref.read(dplOpenTripsProvider(null).future);
        } catch (_) {}
      },
      child: CustomScrollView(
        slivers: [
          // Top — at-a-glance totals banner (Actual / Plan / Buckets /
          // Remaining + In pipeline / Dispatched / Rejected). Same
          // widget the production summary tab uses, so the numbers
          // stay perfectly consistent across both screens.
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          // Dispatch Plan-vs-Actual summary (Today / MTD / Till-date) —
          // tap to open the full breakdown with filters + sort. Hides
          // itself until the report is available.
          const SliverToBoxAdapter(child: _DispatchPvaLandingCard()),
          const SliverToBoxAdapter(child: ProductionTotalsBanner()),
          const SliverToBoxAdapter(child: SizedBox(height: 6)),
          // Open trips section — manager-submitted trips waiting to be
          // slipped. This is the new dispatch entry point introduced in
          // migration 048; the per-plant manual machine-picker form
          // (in `PlantCard`) stays below as fallback during transition.
          // Hidden for the view-only manager (it carries the Send-to-DEO
          // write action).
          if (!isManager)
            const SliverToBoxAdapter(child: OpenTripsSection()),
          // Then — landing header + plant selection cards.
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            sliver: SliverToBoxAdapter(child: const _LandingHeader()),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 14)),
          ..._buildPlantSection(context, ref, plantsAsync),
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );

    if (!showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: AppBar(title: const Text('Select Plant')),
      body: body,
    );
  }

  /// Slivers for the plant-selection row. Returns the right slivers
  /// for whichever state the plants provider is in.
  List<Widget> _buildPlantSection(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<dynamic> async,
  ) {
    return async.when(
      loading: () => [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SkeletonList(count: 3),
          ),
        ),
      ],
      error: (e, _) => [
        SliverToBoxAdapter(
          child: DplErrorRetry(
            message: e.toString(),
            onRetry: () => ref.invalidate(dplPlantsProvider),
          ),
        ),
      ],
      data: (res) {
        if (res.isError) {
          return [
            SliverToBoxAdapter(
              child: DplErrorRetry(
                message: res.error ?? 'Failed to load plants.',
                onRetry: () => ref.invalidate(dplPlantsProvider),
              ),
            ),
          ];
        }
        final plants = (res.data ?? const <DplPlant>[]) as List<DplPlant>;
        if (plants.isEmpty) {
          return const [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: DplEmptyState(
                  icon: Icons.factory_outlined,
                  title: 'No plants configured',
                  message: 'Ask an admin to seed the plant mapping.',
                ),
              ),
            ),
          ];
        }
        return [
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.builder(
              itemCount: plants.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: PlantCard(
                  plant: plants[i],
                  palette: _paletteFor(i),
                ),
              ),
            ),
          ),
        ];
      },
    );
  }

  /// Cycle three distinct accents across the three plant cards so the
  /// eye can distinguish them at a glance. Order is stable across
  /// sessions — same plant always gets the same accent.
  PlantCardPalette _paletteFor(int index) {
    switch (index % 3) {
      case 0:
        return PlantCardPalette(
          accent: DplColors.primary,
          accentDark: DplColors.primaryDark,
          surface: DplColors.primaryTint,
          edge: VistarPalette.primaryLine,
          fill: DplColors.primary,
        );
      case 1:
        return PlantCardPalette(
          accent: VistarPalette.warn,
          accentDark: VistarPalette.warnInk,
          surface: VistarPalette.warnBg,
          edge: VistarPalette.warnLine,
          fill: VistarPalette.warnSolid,
        );
      default:
        return PlantCardPalette(
          accent: VistarPalette.ok,
          accentDark: VistarPalette.okInk,
          surface: VistarPalette.okBg,
          edge: VistarPalette.okLine,
          fill: VistarPalette.okSolid,
        );
    }
  }
}

class _LandingHeader extends StatelessWidget {
  const _LandingHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider, width: 1.2),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: DplColors.primaryTint,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: DplColors.primary.withValues(alpha: 0.15),
              ),
            ),
            child: Icon(
              Icons.factory_outlined,
              size: 18,
              color: DplColors.primaryDark,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Select a plant', style: DplText.h3()),
                const SizedBox(height: 2),
                Text(
                  'Pick the plant you want to dispatch from. '
                  'Each slip you create is scoped to one plant.',
                  style: TextStyle(
                    color: DplColors.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 11.5,
                    height: 1.3,
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

/// Compact Dispatch Plan-vs-Actual summary on the landing top. Shows the
/// three period actuals-vs-plan at a glance and opens the full breakdown
/// (with filters + sort) on tap. Renders nothing until a non-empty report
/// is available, so the landing stays clean while loading / if the report
/// endpoint isn't live yet.
class _DispatchPvaLandingCard extends ConsumerWidget {
  const _DispatchPvaLandingCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report =
        ref.watch(dplDispatchPlanActualProvider).asData?.value.data;
    if (report == null || report.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const DispatchPlanActualScreen(),
            ),
          ),
          child: Ink(
            decoration: BoxDecoration(
              color: DplColors.cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: DplColors.divider),
              boxShadow: DplShadows.card,
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.local_shipping_rounded,
                        size: 18, color: DplColors.primaryDark),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Dispatch — Plan vs Actual',
                          style: DplText.h3()),
                    ),
                    Text(
                      'Details',
                      style: TextStyle(
                        color: DplColors.primaryDark,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        size: 18, color: DplColors.primaryDark),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    for (final p in DplPvaPeriod.values) ...[
                      Expanded(child: _PvaMiniStat(period: p, report: report)),
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
          ),
        ),
      ),
    );
  }
}

class _PvaMiniStat extends StatelessWidget {
  final DplPvaPeriod period;
  final DplDispatchPlanActualReport report;
  const _PvaMiniStat({required this.period, required this.report});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final plan = report.planTotal(period);
    final actual = report.actualTotal(period);
    final pct = plan <= 0 ? null : (actual / plan * 100).round();
    final ink = pct == null
        ? DplColors.textSecondary
        : (pct >= 100
            ? DplColors.success
            : (pct >= 70 ? DplColors.warning : DplColors.error));

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
              fontSize: 14,
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
          pct == null ? 'no plan' : '$pct%',
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            color: ink,
          ),
        ),
      ],
    );
  }
}
