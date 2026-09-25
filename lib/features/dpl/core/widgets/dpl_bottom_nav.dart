import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/dpl_theme.dart';

/// One item in [DplBottomNav].
class DplNavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  const DplNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });
}

/// Unified bottom navigation used by both the Manager and Supervisor
/// shells.
///
/// Visual rules: 72dp tall, white, 1px top border, soft top shadow.
/// Selected tab uses the filled icon + primary color + a small pill
/// indicator above the icon. Unselected tabs use the outlined icon
/// and textSecondary color. Light haptic feedback on every tab change.
class DplBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<DplNavItem> items;

  const DplBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: DplColors.cardBg,
        border: Border(top: BorderSide(color: DplColors.divider, width: 1)),
        boxShadow: DplShadows.bottomNav,
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 72,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _NavCell(
                    item: items[i],
                    selected: i == currentIndex,
                    onTap: () {
                      // Don't early-return on same-tab tap — the
                      // shell uses every tap as a refresh signal so
                      // the manager can pull fresh data with a single
                      // poke on the active tab.
                      HapticFeedback.lightImpact();
                      onTap(i);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavCell extends StatelessWidget {
  final DplNavItem item;
  final bool selected;
  final VoidCallback onTap;

  const _NavCell({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? DplColors.primary : DplColors.textSecondary;
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 3,
            width: selected ? 18 : 0,
            margin: const EdgeInsets.only(top: 6, bottom: 6),
            decoration: BoxDecoration(
              color: DplColors.primary,
              borderRadius: BorderRadius.circular(DplRadius.pill),
            ),
          ),
          Icon(selected ? item.selectedIcon : item.icon, color: color),
          const SizedBox(height: 4),
          Text(
            item.label,
            style: DplText.caption().copyWith(
              color: color,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Manager nav items (Dashboard / Plans / Reports / Settings).
const dplManagerNavItems = <DplNavItem>[
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
  DplNavItem(
    icon: Icons.bar_chart_outlined,
    selectedIcon: Icons.bar_chart,
    label: 'Reports',
  ),
  DplNavItem(
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
    label: 'Settings',
  ),
];

/// The fifth manager tab, added only when the manager holds a Maxion tool
/// permission (see maxion_tools_screen.dart `hasAnyMaxionTool`).
const dplManagerToolsNavItem = DplNavItem(
  icon: Icons.handyman_outlined,
  selectedIcon: Icons.handyman,
  label: 'Tools',
);

/// Supervisor nav items (Today / Shift Summary / Profile).
const dplSupervisorNavItems = <DplNavItem>[
  DplNavItem(
    icon: Icons.today_outlined,
    selectedIcon: Icons.today,
    label: 'Today',
  ),
  DplNavItem(
    icon: Icons.summarize_outlined,
    selectedIcon: Icons.summarize,
    label: 'Shift Summary',
  ),
  DplNavItem(
    icon: Icons.person_outline,
    selectedIcon: Icons.person,
    label: 'Profile',
  ),
];
