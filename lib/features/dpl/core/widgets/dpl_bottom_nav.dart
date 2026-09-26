import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/vistar_palette.dart';
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

/// Unified bottom navigation used by the Manager, Supervisor and QA shells.
///
/// SIZES ITSELF TO ITS CONTENT, in both directions, and that is the whole
/// design. It used to be a hard `SizedBox(height: 72)` wrapped around a Column
/// with a fixed 24dp icon and an unbounded label, which overflowed by five
/// pixels the moment either of two things happened — and both happen on real
/// devices:
///
///   * the operator had Android's font size turned up, which every warehouse
///     phone in a bright building eventually does; or
///   * the QA shell showed all seven of its tabs, squeezing each label into
///     about fifty pixels with nothing to say what should give.
///
/// Both produced red overflow stripes across the bar — on the busiest screen
/// in the system, permanently.
///
/// So: the row is measured, never assumed. Text scaling is clamped so
/// accessibility settings cannot burst the chrome (the rest of the app still
/// scales; a nav label is a signpost, not prose), the height comes from the
/// content with a comfortable floor, and each cell adapts what it draws to the
/// width it actually got.
///
/// Visual rules: card surface (deep ink in dark mode), 1px top hairline, soft
/// top shadow. The selected tab gets a tinted pill behind its icon, the filled
/// icon in primary, and a thin ribbon accent above — the ribbon stays a thin
/// accent and never a fill, per the palette's rule.
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

  /// Below this, a cell shows its icon alone.
  ///
  /// Seven tabs on a 320dp phone leaves 45dp each. A label shrunk to fit that
  /// is unreadable at arm's length in a warehouse, so it is dropped rather
  /// than rendered as decoration nobody can use — the icon and the tooltip
  /// carry the meaning instead.
  static const _labelFloor = 52.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: VistarPalette.isDark ? VistarPalette.bg2 : DplColors.cardBg,
        border: Border(top: BorderSide(color: DplColors.divider, width: 1)),
        boxShadow: DplShadows.bottomNav,
      ),
      child: SafeArea(
        top: false,
        // Clamped, not ignored. A nav label is a signpost: at 2x it stops
        // being one and starts breaking the bar it sits in. Everything else
        // in the app keeps the operator's chosen scale.
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cell = items.isEmpty
                  ? constraints.maxWidth
                  : constraints.maxWidth / items.length;
              final showLabels = cell >= _labelFloor;

              // Tighten as the cells narrow rather than letting the label
              // decide the width it wants.
              final iconSize = cell >= 72 ? 24.0 : (cell >= 60 ? 22.0 : 20.0);
              final labelSize = cell >= 72 ? 11.5 : (cell >= 60 ? 10.5 : 9.5);

              return Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: _NavCell(
                        item: items[i],
                        selected: i == currentIndex,
                        showLabel: showLabels,
                        iconSize: iconSize,
                        labelSize: labelSize,
                        onTap: () {
                          // Don't early-return on same-tab tap — the shell
                          // uses every tap as a refresh signal so the manager
                          // can pull fresh data with a single poke on the
                          // active tab.
                          HapticFeedback.lightImpact();
                          onTap(i);
                        },
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _NavCell extends StatelessWidget {
  final DplNavItem item;
  final bool selected;
  final bool showLabel;
  final double iconSize;
  final double labelSize;
  final VoidCallback onTap;

  const _NavCell({
    required this.item,
    required this.selected,
    required this.showLabel,
    required this.iconSize,
    required this.labelSize,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? (VistarPalette.isDark ? VistarPalette.primaryInk : DplColors.primary)
        : DplColors.textSecondary;

    final cell = Column(
      // min, and no fixed parent height: the bar takes its height from this,
      // so the content can never be taller than the box drawn around it.
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // The ribbon accent. Reserves its 3dp whether or not it is showing, so
        // icons do not jump by three pixels as the operator moves between
        // tabs.
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 3,
          width: selected ? 18 : 0,
          decoration: BoxDecoration(
            gradient: VistarPalette.ribbonFlat,
            borderRadius: BorderRadius.circular(DplRadius.pill),
          ),
        ),
        const SizedBox(height: 5),
        // A tinted pill behind the selected icon. This is where the colour the
        // bar was missing comes from: unselected tabs stay quiet, and the one
        // you are on reads at a glance from across a bay.
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.symmetric(
            horizontal: showLabel ? 12 : 10,
            vertical: 3,
          ),
          decoration: BoxDecoration(
            color: selected ? DplColors.primaryTint : Colors.transparent,
            borderRadius: BorderRadius.circular(DplRadius.pill),
          ),
          child: Icon(
            selected ? item.selectedIcon : item.icon,
            color: color,
            size: iconSize,
          ),
        ),
        if (showLabel) ...[
          const SizedBox(height: 3),
          // One line, ellipsised, and never allowed to ask for more width than
          // the cell has. "Pallets built" on a seven-tab bar is exactly the
          // string that used to push the row past its bounds.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              item.label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: DplText.caption().copyWith(
                fontSize: labelSize,
                height: 1.15,
                color: color,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
        ],
        const SizedBox(height: 6),
      ],
    );

    return InkWell(
      onTap: onTap,
      // Named for the screen reader, and for the icon-only case where the
      // label is not drawn at all.
      child: Semantics(
        label: item.label,
        selected: selected,
        button: true,
        child: showLabel
            ? cell
            : Tooltip(message: item.label, child: cell),
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
