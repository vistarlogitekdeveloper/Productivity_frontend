import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_refresh_icon_button.dart';
import '../../models/dpl_part_field.dart';
import '../providers/dpl_part_field_provider.dart';

/// Manager landing page for the "simple" dispatch-planning flow.
///
/// Renders one card per per-part field the manager edits at different
/// cadences (once / monthly / daily), plus a final card that opens
/// the computed Daily Dispatch Plan view that applies the formula
/// `dispatch = (stocking_norm + customer_today_plan) − customer_opening_stock`.
class DispatchPlanningHubScreen extends ConsumerWidget {
  const DispatchPlanningHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Dispatch Planning',
        actions: [
          DplRefreshIconButton(
            onRefresh: () async {
              for (final k in DplPartFieldKind.dispatchPlanningKinds) {
                ref.invalidate(dplPartFieldPageProvider(k));
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 22),
        children: [
          const _IntroCard(),
          const SizedBox(height: 14),
          // Only the *daily* input lives on this hub. The two
          // less-frequent inputs (Stocking Norm — once, Customer
          // Opening Stock — monthly) have been moved to the Settings
          // tab so this screen stays focused on what the manager
          // actually touches every morning.
          const _MasterFieldCard(kind: DplPartFieldKind.customerTodayPlan),
          const SizedBox(height: 10),
          const SizedBox(height: 6),
          const _ViewPlanCard(),
          const SizedBox(height: 10),
          const _PlanTripCard(),
        ],
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: DplColors.primaryTint,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.calculate_outlined,
                    color: DplColors.primaryDark),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text('How daily dispatch is calculated',
                    style: DplText.h3()),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: DplColors.neutralBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '(Stocking Norm  +  Customer\'s Today\'s Plan)  −  '
              'Customer Opening Stock  =  Daily Dispatch',
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: DplColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Update today\'s plan below — stocking norms and opening '
            'stocks live under Settings since they change rarely. Once '
            'all 3 are set for a part, today\'s dispatch quantity is '
            'computed automatically.',
            style: TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _MasterFieldCard extends ConsumerWidget {
  final DplPartFieldKind kind;
  const _MasterFieldCard({required this.kind});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncPage = ref.watch(dplPartFieldPageProvider(kind));
    return InkWell(
      onTap: () => context.push('/dpl/manager/${_routePath(kind)}'),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: DplColors.cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: DplColors.divider),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _accentBg(kind),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(_icon(kind), color: _accentInk(kind), size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    kind.label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    kind.cadence,
                    style: TextStyle(
                      color: DplColors.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 11.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  asyncPage.when(
                    loading: () => Text(
                      'Loading…',
                      style: TextStyle(
                        color: DplColors.textTertiary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    error: (e, _) => Text(
                      'Error: $e',
                      style: TextStyle(
                        color: DplColors.error,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    data: (res) {
                      if (res.isError) {
                        return Text(
                          res.error ?? 'Failed to load.',
                          style: TextStyle(
                            color: DplColors.error,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        );
                      }
                      final t = res.data!.totals;
                      return _ConfiguredChip(totals: t);
                    },
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: DplColors.textTertiary),
          ],
        ),
      ),
    );
  }

  static String _routePath(DplPartFieldKind kind) {
    switch (kind) {
      case DplPartFieldKind.stockingNorm:
        return 'stocking-norms';
      case DplPartFieldKind.customerOpeningStock:
        return 'customer-opening-stocks';
      case DplPartFieldKind.customerTodayPlan:
        return 'customer-todays-plans';
      case DplPartFieldKind.packagingQty:
        return 'packaging-qtys';
      case DplPartFieldKind.gaOpeningStock:
        return 'ga-opening-stocks';
    }
  }

  static IconData _icon(DplPartFieldKind kind) {
    switch (kind) {
      case DplPartFieldKind.stockingNorm:
        return Icons.layers_outlined;
      case DplPartFieldKind.customerOpeningStock:
        return Icons.inventory_2_outlined;
      case DplPartFieldKind.customerTodayPlan:
        return Icons.today_outlined;
      case DplPartFieldKind.packagingQty:
        return Icons.all_inbox_outlined;
      case DplPartFieldKind.gaOpeningStock:
        return Icons.warehouse_outlined;
    }
  }

  static Color _accentBg(DplPartFieldKind kind) {
    switch (kind) {
      case DplPartFieldKind.stockingNorm:
        return DplColors.primaryTint;
      case DplPartFieldKind.customerOpeningStock:
        return DplColors.warningBg;
      case DplPartFieldKind.customerTodayPlan:
        return DplColors.infoBg;
      case DplPartFieldKind.packagingQty:
        return DplColors.successBg;
      case DplPartFieldKind.gaOpeningStock:
        return DplColors.infoBg;
    }
  }

  static Color _accentInk(DplPartFieldKind kind) {
    switch (kind) {
      case DplPartFieldKind.stockingNorm:
        return DplColors.primaryDark;
      case DplPartFieldKind.customerOpeningStock:
        return DplColors.warning;
      case DplPartFieldKind.customerTodayPlan:
        return DplColors.info;
      case DplPartFieldKind.packagingQty:
        return DplColors.success;
      case DplPartFieldKind.gaOpeningStock:
        return DplColors.info;
    }
  }
}

class _ConfiguredChip extends StatelessWidget {
  final DplPartFieldTotals totals;
  const _ConfiguredChip({required this.totals});

  @override
  Widget build(BuildContext context) {
    final bg = totals.isFullyConfigured
        ? DplColors.successBg
        : DplColors.warningBg;
    final ink = totals.isFullyConfigured
        ? DplColors.success
        : DplColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        totals.totalParts == 0
            ? 'No parts'
            : '${totals.configured} / ${totals.totalParts} configured',
        style: TextStyle(
          color: ink,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _ViewPlanCard extends ConsumerWidget {
  const _ViewPlanCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Compute readiness summary: count parts that have all 3 fields
    // set on the current cached responses. If any provider isn't
    // loaded yet, show a "loading…" placeholder.
    final pages = <DplPartFieldKind, DplPartFieldPage?>{};
    for (final k in DplPartFieldKind.dispatchPlanningKinds) {
      final async = ref.watch(dplPartFieldPageProvider(k));
      pages[k] = async.asData?.value.data;
    }
    final allLoaded = pages.values.every((p) => p != null);

    int readyParts = 0;
    int blockedParts = 0;
    if (allLoaded) {
      final byPart = <int, Set<DplPartFieldKind>>{};
      for (final entry in pages.entries) {
        for (final r in entry.value!.entries) {
          if (r.value != null) {
            byPart.putIfAbsent(r.partId, () => {}).add(entry.key);
          }
        }
      }
      final partIds = <int>{
        for (final p in pages.values) ...p!.entries.map((e) => e.partId),
      };
      for (final pid in partIds) {
        final set = byPart[pid] ?? const {};
        if (set.length == DplPartFieldKind.dispatchPlanningKinds.length) {
          readyParts++;
        } else {
          blockedParts++;
        }
      }
    }

    return InkWell(
      onTap: () => context.push('/dpl/manager/dispatch-plan-view'),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          gradient: VistarPalette.heroGradient,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(Icons.local_shipping_outlined,
                  color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'View Daily Dispatch Plan',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    DateFormat('EEE, dd MMM yyyy').format(DateTime.now()),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                      fontSize: 11.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (!allLoaded)
                    const Text(
                      'Loading inputs…',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _DarkChip(
                          label: '$readyParts ready',
                          accent: Colors.greenAccent.shade100,
                        ),
                        if (blockedParts > 0)
                          _DarkChip(
                            label: '$blockedParts blocked',
                            accent: Colors.orangeAccent.shade100,
                          ),
                      ],
                    ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white70),
          ],
        ),
      ),
    );
  }
}

/// Trip-builder entry card. Same dark-tile aesthetic as the
/// `_ViewPlanCard` above so the two related actions read as a pair on
/// the hub.
class _PlanTripCard extends StatelessWidget {
  const _PlanTripCard();

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.push('/dpl/manager/plan-trip'),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: DplColors.cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: DplColors.primary, width: 1.2),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: DplColors.primaryTint,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.local_shipping_rounded,
                color: DplColors.primaryDark,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Plan Trip', style: DplText.h3()),
                  const SizedBox(height: 2),
                  Text(
                    'Allocate the day\'s dispatch qty across truck trips '
                    '— up to 6 parts per trip.',
                    style: TextStyle(
                      color: DplColors.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: DplColors.textTertiary),
          ],
        ),
      ),
    );
  }
}

class _DarkChip extends StatelessWidget {
  final String label;
  final Color accent;
  const _DarkChip({required this.label, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accent,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      ),
    );
  }
}
