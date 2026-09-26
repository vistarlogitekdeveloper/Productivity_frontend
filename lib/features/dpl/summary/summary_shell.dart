import '../core/dpl_permissions_provider.dart';
import '../maxion/maxion_tools_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../auth/auth_provider.dart';
import '../core/design/dpl_theme.dart';
import '../core/widgets/dpl_app_bar.dart';
import '../core/widgets/dpl_bottom_nav.dart';
import '../core/widgets/dpl_dashboard_switcher.dart';
import '../core/widgets/dpl_refresh_icon_button.dart';
import 'providers/dispatch_slips_provider.dart';
import 'providers/dispatch_trips_provider.dart';
import 'providers/plants_provider.dart';
import 'providers/production_summary_provider.dart';
import 'providers/summary_tab_provider.dart';
import 'screens/dispatch_slip_verifier_screen.dart';
import 'screens/dispatch_slips_inbox_screen.dart';
import 'screens/plant_landing_screen.dart';
import 'widgets/buffer_plan_download_sheet.dart';

/// Two-tab shell for the Dispatch / QA / PDI roles.
///
/// Tab 0 — Production Summary (the running aggregate of total actual qty
/// per machine + part, with the Request Dispatch Slip CTA for Dispatch).
///
/// Tab 1 — Dispatch Slips inbox/list with role-aware status defaults:
///   * QA lands on the "Pending QA" filter
///   * PDI lands on the "Pending PDI" filter
///   * Dispatch sees their own slips across every status
///
/// The bottom-nav badge on the Slips tab shows the live pending count
/// for the active role's queue, sourced from the slips list endpoint's
/// `totals` block so it stays accurate without an extra round-trip.
class DplSummaryShell extends ConsumerWidget {
  const DplSummaryShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).asData?.value;
    final role = user?.role ?? '';
    final tabIndex = ref.watch(dplSummaryTabProvider).clamp(0, 1);

    final summaryTitle = _summaryTitleForRole(role);
    final slipsTitle = _slipsTitleForRole(role);

    // Tab 0 — Plant landing replaces the old direct-to-buckets view.
    // The user picks a plant, then drills into that plant's production
    // summary on a pushed route. Tab 1 stays as the slips inbox.
    final pages = const <Widget>[
      PlantLandingScreen(showAppBar: false),
      DispatchSlipsInboxScreen(showAppBar: false),
    ];

    final titles = [summaryTitle, slipsTitle];

    // Live pending count for whichever queue this role primarily owns —
    // QA → pending_qa, PDI → pending_pdi, Dispatch → pending_qa + pending_pdi
    // (everything not yet approved or terminal). Manager uses the QA
    // count as a generic "needs attention" signal.
    final pendingCount = _pendingCountForRole(ref, role);

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: titles[tabIndex],
        // Full-width Production⇄Dispatch toggle band directly under the
        // nav bar. Manager-only — Dispatch / DEO / PDI never see it (they
        // can't reach the Production shell).
        bottom: AppConstants.isDplManagerRole(role)
            ? const DplDashboardSwitcher(current: DplDashboardMode.dispatch)
            : null,
        actions: [
          // Maxion tools: shipment & gate pass, returns, reports, counts…
          if (hasAnyMaxionTool(ref.watch(dplPermissionsProvider)))
            IconButton(
              tooltip: 'Tools',
              icon: const Icon(Icons.handyman_outlined),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const DplMaxionToolsScreen())),
            ),
          // Dispatch role can pull the monthly Buffer Creation Plan as an
          // Excel workbook (Opn Stock at TML / Production at GA / Dispatch
          // From GA / Customer Plan, per part per day). Hidden for QA/PDI
          // since the underlying inputs endpoint is Manager + Dispatch only.
          if (AppConstants.isDplDispatchRole(role))
            IconButton(
              tooltip: 'Download Buffer Creation Plan',
              icon: const Icon(Icons.table_view_outlined),
              onPressed: () => BufferPlanDownloadSheet.show(context),
            ),
          IconButton(
            tooltip: 'Verify slip QR',
            icon: const Icon(Icons.qr_code_scanner_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const DispatchSlipVerifierScreen(),
              ),
            ),
          ),
          DplRefreshIconButton(
            onRefresh: () async {
              if (tabIndex == 0) {
                // Plant landing — refresh everything the screen
                // shows. Plant master is effectively static, but the
                // open-trips list, the global production-summary
                // banner and the per-plant production-summary
                // (which drives the "Out of stock" hint on each
                // trip-plan row) are all live and need a fresh
                // pull on every refresh tap.
                ref.invalidate(dplPlantsProvider);
                ref.invalidate(dplOpenTripsProvider);
                ref.invalidate(dplProductionSummaryProvider);
                ref.invalidate(dplProductionSummaryByPlantProvider);
                try {
                  await Future.wait([
                    ref.read(dplPlantsProvider.future),
                    ref.read(dplOpenTripsProvider(null).future),
                    ref.read(dplProductionSummaryProvider.future),
                  ]);
                } catch (_) {}
              } else {
                ref.invalidate(dplDispatchSlipsProvider);
                try {
                  await ref.read(dplDispatchSlipsProvider.future);
                } catch (_) {}
              }
            },
          ),
        ],
      ),
      body: IndexedStack(index: tabIndex, children: pages),
      bottomNavigationBar: DplBottomNav(
        currentIndex: tabIndex,
        items: [
          const DplNavItem(
            icon: Icons.factory_outlined,
            selectedIcon: Icons.factory,
            label: 'Plants',
          ),
          DplNavItem(
            icon: pendingCount > 0
                ? Icons.notifications_active_outlined
                : Icons.receipt_long_outlined,
            selectedIcon: Icons.receipt_long,
            label: pendingCount > 0
                ? 'Slips ($pendingCount)'
                : 'Slips',
          ),
        ],
        onTap: (i) {
          ref.read(dplSummaryTabProvider.notifier).set(i);
          // Re-tapping the active tab refreshes the live data, same
          // pattern the manager shell uses. Tab 0 is now the plant
          // landing — production-summary data only matters once the
          // user drills into a plant, so we don't preempt that here.
          if (i == 0) {
            ref.invalidate(dplPlantsProvider);
            ref.invalidate(dplOpenTripsProvider);
            ref.invalidate(dplProductionSummaryProvider);
            ref.invalidate(dplProductionSummaryByPlantProvider);
          } else {
            ref.invalidate(dplDispatchSlipsProvider);
          }
        },
      ),
    );
  }

  /// Title for tab 0, prefixed by role so the user always knows which
  /// "lens" they're in. Tab 0 is now the plant landing, so the title
  /// reflects that — the per-plant production summary screen sets its
  /// own AppBar when the user drills in.
  String _summaryTitleForRole(String role) {
    if (AppConstants.isDplDispatchRole(role)) {
      return 'Dispatch — Select Plant';
    }
    if (AppConstants.isDplDeoRole(role)) {
      return 'DEO — Select Plant';
    }
    // QA approval step removed from the workflow — QA users land on
    // the PDI-style screen.
    if (AppConstants.isDplQaRole(role) || AppConstants.isDplPdiRole(role)) {
      return 'PDI — Select Plant';
    }
    return 'Select Plant';
  }

  String _slipsTitleForRole(String role) {
    if (AppConstants.isDplDispatchRole(role)) return 'My Dispatch Slips';
    if (AppConstants.isDplDeoRole(role)) return 'DEO — Dispatch Slips';
    // QA users see the PDI inbox view.
    if (AppConstants.isDplQaRole(role) || AppConstants.isDplPdiRole(role)) {
      return 'PDI — Dispatch Slips';
    }
    return 'Dispatch Slips';
  }

  /// Count to show on the Slips nav-bar badge. Reads from the slips
  /// provider's `totals` block (which ignores the active filter), so the
  /// badge reflects the role's queue depth even when the user is
  /// filtered to a different status. Defensive against every level of
  /// the chain being null — slips request may still be in flight, may
  /// have errored, or may have returned a response without totals.
  int _pendingCountForRole(WidgetRef ref, String role) {
    final asyncSlips = ref.watch(dplDispatchSlipsProvider);
    final response = asyncSlips.asData?.value;
    if (response == null || !response.isOk) return 0;
    final totals = response.data?.totals;
    if (totals == null) return 0;
    // DEO's badge counts the trips waiting for an invoice.
    if (AppConstants.isDplDeoRole(role)) {
      return totals.pendingDeo;
    }
    // QA approval step removed — QA users see the PDI pending count.
    if (AppConstants.isDplQaRole(role) ||
        AppConstants.isDplPdiRole(role)) {
      return totals.pendingPdi;
    }
    if (AppConstants.isDplDispatchRole(role)) {
      // Dispatch cares about the whole pipeline they kicked off.
      return totals.pendingDeo + totals.pendingPdi;
    }
    // Manager fallback.
    return totals.pendingDeo + totals.pendingPdi;
  }
}
