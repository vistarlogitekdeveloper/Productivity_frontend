import '../core/dpl_permissions_provider.dart';
import '../maxion/maxion_tools_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/widgets/dpl_app_bar.dart';
import '../core/widgets/dpl_bottom_nav.dart';
import '../core/widgets/dpl_refresh_icon_button.dart';
import 'providers/dpl_dashboard_provider.dart';
import 'providers/dpl_manager_tab_provider.dart';
import 'providers/dpl_plan_list_provider.dart';
import 'providers/dpl_reports_provider.dart';
import 'providers/dpl_viewer_only_provider.dart';
import 'screens/dashboard_screen.dart';
import 'screens/masters_hub_screen.dart';
import 'screens/plan_list_screen.dart';
import 'screens/reports_screen.dart';
import 'widgets/manager_downtime_banner.dart';

/// Bottom-nav container for the DPL Manager experience.
/// Dashboard / Plans / Reports / Settings.
///
/// The active tab is held in `dplManagerTabProvider` so the persistent
/// footer mounted on nested detail screens can switch tabs without
/// losing state.
///
/// DPL Customer (read-only viewer) sees only Dashboard + Plans — the
/// Reports and Settings tabs are stripped so they can't reach anything
/// outside the scope the user signed off on for that role.
class DplManagerShell extends ConsumerWidget {
  const DplManagerShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewerOnly = ref.watch(dplViewerOnlyProvider);
    final rawIndex = ref.watch(dplManagerTabProvider);

    // Maxion tools (backend phases 1–4): one extra tab, only for a manager
    // who holds at least one of their permissions. Every other plant's
    // manager sees exactly the four tabs they had.
    final showTools = !viewerOnly && hasAnyMaxionTool(ref.watch(dplPermissionsProvider));
    final pages = viewerOnly
        ? const <Widget>[
            DplManagerDashboardScreen(),
            _EmbeddedPlanList(),
          ]
        : <Widget>[
            const DplManagerDashboardScreen(),
            const _EmbeddedPlanList(),
            const DplReportsScreen(),
            const DplMastersHubScreen(embedded: true),
            if (showTools) const DplMaxionToolsScreen(),
          ];

    final navItems = viewerOnly
        ? const <DplNavItem>[
            DplNavItem(
              icon: Icons.dashboard_outlined,
              selectedIcon: Icons.dashboard,
              label: 'Dashboard',
            ),
            DplNavItem(
              icon: Icons.assignment_outlined,
              selectedIcon: Icons.assignment,
              label: 'Plans',
            ),
          ]
        : [...dplManagerNavItems, if (showTools) dplManagerToolsNavItem];

    // Clamp the selected tab so an old index from a previous role/session
    // can never overflow the (possibly shorter) viewer-only nav.
    final index = rawIndex.clamp(0, pages.length - 1);

    return Scaffold(
      body: Column(
        children: [
          // Global sticky red banner — visible to both DPL Manager and
          // the read-only "DPL Customer" viewer on every tab, mirroring
          // the supervisor shell. Hidden when no downtime is active.
          const ManagerDowntimeBanner(),
          Expanded(child: IndexedStack(index: index, children: pages)),
        ],
      ),
      bottomNavigationBar: DplBottomNav(
        currentIndex: index,
        items: navItems,
        onTap: (i) {
          ref.read(dplManagerTabProvider.notifier).set(i);
          // Every tab tap (including re-tapping the active tab)
          // refreshes the destination's primary data so the manager
          // never sees stale numbers without a manual gesture.
          switch (i) {
            case 0:
              ref.invalidate(dplDashboardSummaryProvider);
              ref.invalidate(dplDashboardMtdProvider);
              break;
            case 1:
              ref.invalidate(dplPlanListProvider);
              break;
            case 2:
              if (!viewerOnly) {
                ref.invalidate(dplPlanVsActualReportProvider);
                ref.invalidate(dplDowntimeReportProvider);
              }
              break;
            case 3:
              // Settings is mostly navigation tiles — nothing live
              // to invalidate here.
              break;
          }
        },
      ),
    );
  }
}

class _EmbeddedPlanList extends ConsumerWidget {
  const _EmbeddedPlanList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: DplAppBar(
        title: 'Production Plans',
        actions: [
          DplRefreshIconButton(
            onRefresh: () async {
              ref.invalidate(dplPlanListProvider);
              try {
                await ref.read(dplPlanListProvider.future);
              } catch (_) {}
            },
          ),
        ],
      ),
      body: const DplPlanListScreen(embedded: true),
    );
  }
}
