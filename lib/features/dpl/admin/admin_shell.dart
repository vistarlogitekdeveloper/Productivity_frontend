import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design/dpl_theme.dart';
import '../core/dpl_permissions_provider.dart';
import '../core/widgets/dpl_app_bar.dart';
import '../core/widgets/dpl_bottom_nav.dart';
import '../core/widgets/dpl_refresh_icon_button.dart';
import 'providers/admin_providers.dart';
import 'screens/admin_access_screen.dart';
import 'screens/admin_activity_screen.dart';
import 'screens/admin_organizations_screen.dart';
import 'screens/admin_users_screen.dart';

/// Home for the Administrator role (backend migration 148).
///
/// Four tabs, in the order the work is usually done:
///   Users          — the people. Add, edit, disable, reset a password.
///   Organizations  — the tenants everything else is scoped to.
///   Access         — what each role may do. Settings, not code.
///   Activity       — who changed which account, and when.
///
/// Tabs the caller has no permission for are not rendered at all. Showing a
/// tab that answers every tap with a 403 is worse than not showing it: it
/// looks like the system is broken rather than like the person was not given
/// that job.
class DplAdminShell extends ConsumerStatefulWidget {
  const DplAdminShell({super.key});

  @override
  ConsumerState<DplAdminShell> createState() => _DplAdminShellState();
}

class _AdminTab {
  final String title;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget screen;
  final void Function(WidgetRef ref) refresh;

  const _AdminTab({
    required this.title,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.screen,
    required this.refresh,
  });
}

class _DplAdminShellState extends ConsumerState<DplAdminShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(dplPermissionsProvider);

    final tabs = <_AdminTab>[
      if (perms.can(DplPermission.usersView))
        _AdminTab(
          title: 'Administration — Users',
          label: 'Users',
          icon: Icons.group_outlined,
          selectedIcon: Icons.group,
          screen: const AdminUsersScreen(),
          refresh: (ref) => ref.invalidate(adminUsersProvider),
        ),
      if (perms.can(DplPermission.orgsView))
        _AdminTab(
          title: 'Administration — Organizations',
          label: 'Organizations',
          icon: Icons.apartment_outlined,
          selectedIcon: Icons.apartment,
          screen: const AdminOrganizationsScreen(),
          refresh: (ref) => ref.invalidate(adminOrganizationsProvider),
        ),
      if (perms.can(DplPermission.permissionsManage))
        _AdminTab(
          title: 'Administration — Access rules',
          label: 'Access',
          icon: Icons.tune_outlined,
          selectedIcon: Icons.tune,
          screen: const AdminAccessScreen(),
          refresh: (ref) => ref.invalidate(adminPermissionMatrixProvider),
        ),
      if (perms.can(DplPermission.auditView))
        _AdminTab(
          title: 'Administration — Activity',
          label: 'Activity',
          icon: Icons.history_outlined,
          selectedIcon: Icons.history,
          screen: const AdminActivityScreen(),
          refresh: (ref) => ref.invalidate(adminAuditProvider),
        ),
    ];

    if (tabs.isEmpty) {
      // Reachable only if an administrator strips every admin permission from
      // a role that still lands here. The lockout guard prevents this for
      // dpl_admin itself, so this is the delegated-permission case.
      return const Scaffold(
        backgroundColor: DplColors.pageBg,
        appBar: DplAppBar(title: 'Administration'),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'Your role no longer has access to any part of the '
              'Administration panel. Ask an administrator to restore it.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF6B7280)),
            ),
          ),
        ),
      );
    }

    // A permission change can shrink the tab list under a selected index.
    final index = _tab.clamp(0, tabs.length - 1);
    final active = tabs[index];

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: active.title,
        actions: [
          DplRefreshIconButton(
            onRefresh: () async {
              active.refresh(ref);
              // The catalogue and org list feed every tab's dropdowns, so a
              // refresh that left them stale would look like it had not worked.
              ref.invalidate(adminCatalogueProvider);
              ref.invalidate(adminOrganizationsProvider);
              await ref.read(dplPermissionsProvider.notifier).refresh();
            },
          ),
        ],
      ),
      body: IndexedStack(
        index: index,
        children: [for (final t in tabs) t.screen],
      ),
      bottomNavigationBar: tabs.length < 2
          ? null
          : DplBottomNav(
              currentIndex: index,
              onTap: (i) => setState(() => _tab = i),
              items: [
                for (final t in tabs)
                  DplNavItem(
                    icon: t.icon,
                    selectedIcon: t.selectedIcon,
                    label: t.label,
                  ),
              ],
            ),
    );
  }
}
