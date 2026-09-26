import '../maxion/maxion_tools_screen.dart';
import '../maxion/sync/sync_status_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/scanner/hardware_scanner.dart';
import '../core/design/dpl_theme.dart';
import '../core/dpl_permissions_provider.dart';
import '../core/widgets/dpl_app_bar.dart';
import '../core/widgets/dpl_bottom_nav.dart';
import '../core/widgets/dpl_refresh_icon_button.dart';
import '../summary/providers/dispatch_slips_provider.dart';
import '../summary/screens/dispatch_slips_inbox_screen.dart';
import 'providers/qa_production_provider.dart';
import 'screens/qa_direct_print_screen.dart';
import 'screens/qa_putaway_screen.dart';
import 'screens/qa_spd_screen.dart';
import 'screens/qa_pallet_merge_screen.dart';
import 'screens/qa_pallet_register_screen.dart';
import 'screens/qa_pallet_screen.dart';
import 'screens/qa_production_screen.dart';

/// Two-tab home for the QA role.
///
/// Tab 0 — Production: machine-wise plan vs actual for a date, defaulted to
/// the shift that is running, and the entry point into the scan-and-print
/// flow. This is the new work.
///
/// Tab 1 — Dispatch Slips: the inbox QA already had before this feature
/// existed. It is carried over deliberately. QA used to land on the shared
/// summary shell, and repointing the role at a new home without bringing the
/// slips inbox along would have quietly removed a screen people use.
class DplQaShell extends ConsumerStatefulWidget {
  const DplQaShell({super.key});

  @override
  ConsumerState<DplQaShell> createState() => _DplQaShellState();
}

class _DplQaShellState extends ConsumerState<DplQaShell> {
  int _tab = 0;

  /// One stable key per tab slot, so a tab switch can find the screen that
  /// just became visible. Sized to the most tabs this shell can ever show;
  /// unused slots cost nothing.
  final List<GlobalKey> _tabKeys = List.generate(8, (_) => GlobalKey());

  GlobalKey _tabKey(int i) => _tabKeys[i];

  /// Switch tabs.
  ///
  /// NOTHING IS FOCUSED HERE, deliberately. An earlier version moved focus
  /// into the new tab's scan field so the handheld had somewhere to deliver
  /// to — which worked, and raised the soft keyboard over half the screen on
  /// every single tab change. On a rugged handheld that keyboard is pure
  /// obstruction: the trigger is the input, and the operator wants to see the
  /// SPD list or the part list they just navigated to.
  ///
  /// It is not needed either. HardwareScanScope routes a decode to the first
  /// field in the visible tab whether or not anything holds focus — see
  /// `activeArea`. The keyboard now appears only when somebody taps a field,
  /// which is the only time anyone wants it.
  void _showTab(int i) => setState(() => _tab = i);

  @override
  void initState() {
    super.initState();
    // Re-read what this organization is allowed to do, once, on entering the
    // shell.
    //
    // The permission list is otherwise written only at login and cached. So an
    // administrator who granted `labels.print_batch` while the QA operator was
    // already signed in changed nothing the operator could see: the quantity
    // field stayed hidden until they happened to log out and back in, with no
    // hint that a re-login was the missing step. Nothing else in a QA session
    // ever refreshes it.
    //
    // Deferred past the first frame because it touches providers, and
    // fire-and-forget because a failed refresh must not block the screen —
    // `refresh()` leaves the cached list untouched on a network error.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(dplPermissionsProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    // `labels.print_batch` does not add a tab — it decides WHICH of two
    // mutually exclusive ways of getting labels this plant uses.
    //
    //   OFF (the existing DPL plants, e.g. Sanand JIT):
    //     Production — pick a machine and an item off the day's plan, and
    //     print against the actual quantity the supervisor recorded.
    //
    //   ON (Maxion):
    //     Print labels — pick a machine and an item, type a quantity, print.
    //     There is no plan behind it and no actual quantity to check against.
    //
    // They are shown as alternatives rather than together because a Maxion
    // plant has no production plan at all: its Production tab would be a
    // permanently empty screen reading "Nothing planned", which looks like
    // the app has lost the day's work. And offering a DPL plant the
    // uncapped screen would let it print past what it actually made — the
    // precise thing the cap exists to stop.
    final perms = ref.watch(dplPermissionsProvider);
    final canDirectPrint = perms.can(DplPermission.labelsPrintBatch);
    // Pallet build and close (SSR Module 4). Same reasoning as above: a plant
    // without the permission must not see a tab whose every action the server
    // would refuse.
    final canBuildPallets = perms.can(DplPermission.palletBuild);
    // The register is read-only and has its own permission, so a plant can let
    // somebody browse what has been packed without letting them pack.
    final canViewPallets = perms.can(DplPermission.palletView);
    // Warehouse putaway (SSR Module 6). Its own permission because which role
    // racks a pallet differs by plant — the pack operator here, a dedicated
    // putaway operator with a handheld at Maxion.
    final canPutAway = perms.can(DplPermission.palletPutaway);
    // Combining part-filled pallets (SSR Module 5).
    final canMerge = perms.can(DplPermission.palletMerge);
    // Taking wheels off a pallet for a spare-parts order (SSR §8).
    final canSpd = perms.can(DplPermission.palletSpd);
    // The dispatch slips inbox — the screen QA had before any of this.
    //
    // Gated last and GRANTED by default, the opposite polarity to every other
    // flag here, because it is the only one that is not new: a key defaulting
    // to deny would have taken the tab away from every plant the moment this
    // deployed. The administrator turns it off for a pack point that never
    // approves a slip.
    final canSlips = perms.can(DplPermission.slipsQaInbox);

    // Read only when the tab exists. _pendingQaCount() WATCHES the slips list,
    // so calling it unconditionally would keep fetching dispatch slips every
    // build for a pack point that has been told not to see them — a round trip
    // per rebuild for a badge on a tab that is not there.
    final pendingCount = canSlips ? _pendingQaCount() : 0;

    final titles = <String>[
      if (canDirectPrint) 'QA — Print labels' else 'QA — Production',
      if (canBuildPallets) 'QA — Pallet',
      if (canMerge) 'QA — Merge pallets',
      if (canPutAway) 'QA — Put away',
      if (canSpd) 'QA — SPD',
      if (canViewPallets) 'QA — Pallets built',
      if (canSlips) 'QA — Dispatch Slips',
    ];
    final tab = _tab.clamp(0, titles.length - 1);

    // Mounted ONCE, here, rather than on each tab.
    //
    // These tabs live in an IndexedStack, so every one of them is built and
    // listening at the same time. A per-screen subscription would hand a
    // single trigger pull to Pallet, Merge, Put away and SPD together — one
    // press becoming a wheel packed, a pallet resolved and an SPD lookup at
    // once. The scope routes each decode to whichever field has focus, so it
    // reaches the tab the operator is actually looking at, and does it the
    // same way a keyboard-wedge scanner already does.
    return HardwareScanScope(
      // Which tab is on screen. The scope cannot work this out for itself —
      // every tab is mounted at once and, on a freshly-opened one, none of
      // them holds focus.
      activeArea: _tabKeys[tab],
      child: _buildShell(context, tab, perms, canDirectPrint, canBuildPallets,
          canMerge, canPutAway, canSpd, canViewPallets, canSlips, titles,
          pendingCount),
    );
  }

  Widget _buildShell(
    BuildContext context,
    int tab,
    DplPermissions perms,
    bool canDirectPrint,
    bool canBuildPallets,
    bool canMerge,
    bool canPutAway,
    bool canSpd,
    bool canViewPallets,
    bool canSlips,
    List<String> titles,
    int pendingCount,
  ) {
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: titles[tab],
        // The running shift belongs to the plan-driven Production tab. Direct
        // printing has no plan and no shift filter, so the subtitle would be
        // describing a control that is not on screen.
        subtitle: (tab == 0 && !canDirectPrint) ? const _ShiftSubtitle() : null,
        actions: [
          // Offline handhelds: queued scans and blocked state, tap to sync.
          if (perms.can(DplPermission.syncPush))
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Center(child: DplSyncStatusChip(hideWhenSynced: true)),
            ),
          if (hasAnyMaxionTool(perms))
            IconButton(
              tooltip: 'Tools',
              icon: const Icon(Icons.handyman_outlined),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const DplMaxionToolsScreen())),
            ),
          DplRefreshIconButton(
            onRefresh: () async {
              // Always re-read permissions: this is also how the direct-print
              // tab appears for an operator who was already signed in when the
              // administrator granted it.
              await ref.read(dplPermissionsProvider.notifier).refresh();
              // Tab 0 is Production OR Print labels, never both — see the
              // note where `canDirectPrint` is read. Keying off the flag
              // rather than off the index is what keeps this correct when the
              // administrator flips the switch mid-session and the tab under
              // index 0 changes out from under us.
              if (tab == 0 && !canDirectPrint) {
                ref.invalidate(qaDashboardProvider);
                ref.invalidate(qaCurrentShiftProvider);
                try {
                  await ref.read(qaDashboardProvider.future);
                } catch (_) {
                  // Surfaced inline by the screen's own error state; the
                  // refresh spinner must still settle.
                }
              } else if (titles[tab].endsWith('Dispatch Slips')) {
                ref.invalidate(dplDispatchSlipsProvider);
                try {
                  await ref.read(dplDispatchSlipsProvider.future);
                } catch (_) {}
              } else {
                // Covers both the Print labels and Pallet tabs: they share the
                // machine and part pickers, and the pallet screen additionally
                // reads the open pallet and the stored half pallets. Refreshing
                // all of them is a few cheap calls and means the button does
                // what it says on whichever of the two is showing.
                ref.invalidate(qaMachinesProvider);
                ref.invalidate(qaDirectPartsProvider);
                ref.invalidate(qaOpenPalletProvider);
                ref.invalidate(qaHalfPalletsProvider);
                ref.invalidate(palletRegisterProvider);
              }
            },
          ),
        ],
      ),
      body: IndexedStack(
        index: tab,
        children: [
          for (final (i, screen) in <Widget>[
            if (canDirectPrint)
              const QaDirectPrintScreen(showAppBar: false)
            else
              const QaProductionScreen(showAppBar: false),
            if (canBuildPallets) const QaPalletScreen(showAppBar: false),
            if (canMerge) const QaPalletMergeScreen(showAppBar: false),
            if (canPutAway) const QaPutawayScreen(showAppBar: false),
            if (canSpd) const QaSpdScreen(showAppBar: false),
            if (canViewPallets)
              const QaPalletRegisterScreen(showAppBar: false),
            if (canSlips) const DispatchSlipsInboxScreen(showAppBar: false),
          ].indexed)
            // Keyed so the tab switch below can reach INTO the newly visible
            // screen and put focus on its scan field. Without that, a handheld
            // is dead on every tab after the first — see _showTab.
            KeyedSubtree(key: _tabKey(i), child: screen),
        ],
      ),
      bottomNavigationBar: DplBottomNav(
        currentIndex: tab,
        onTap: _showTab,
        items: [
          if (canDirectPrint)
            const DplNavItem(
              icon: Icons.print_outlined,
              selectedIcon: Icons.print,
              label: 'Print labels',
            )
          else
            const DplNavItem(
              icon: Icons.precision_manufacturing_outlined,
              selectedIcon: Icons.precision_manufacturing,
              label: 'Production',
            ),
          if (canBuildPallets)
            const DplNavItem(
              icon: Icons.inventory_2_outlined,
              selectedIcon: Icons.inventory_2,
              label: 'Pallet',
            ),
          if (canMerge)
            const DplNavItem(
              icon: Icons.merge_outlined,
              selectedIcon: Icons.merge,
              label: 'Merge',
            ),
          if (canPutAway)
            const DplNavItem(
              icon: Icons.warehouse_outlined,
              selectedIcon: Icons.warehouse,
              label: 'Put away',
            ),
          if (canSpd)
            const DplNavItem(
              icon: Icons.call_split_outlined,
              selectedIcon: Icons.call_split,
              label: 'SPD',
            ),
          if (canViewPallets)
            const DplNavItem(
              icon: Icons.grid_view_outlined,
              selectedIcon: Icons.grid_view,
              label: 'Pallets built',
            ),
          if (canSlips)
            DplNavItem(
              icon: pendingCount > 0
                  ? Icons.notifications_active_outlined
                  : Icons.receipt_long_outlined,
              selectedIcon: Icons.receipt_long,
              label: pendingCount > 0 ? 'Slips ($pendingCount)' : 'Slips',
            ),
        ],
      ),
    );
  }

  /// Live pending-QA badge, read from the slips list `totals` block so the
  /// count costs no extra round trip.
  int _pendingQaCount() {
    final res = ref.watch(dplDispatchSlipsProvider).asData?.value;
    if (res == null || res.isError || res.data == null) return 0;
    return res.data!.totals.pendingQa;
  }
}

/// "Shift A • running now" under the app-bar title.
class _ShiftSubtitle extends ConsumerWidget {
  const _ShiftSubtitle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(qaShiftFilterProvider);
    final live = ref.watch(qaCurrentShiftProvider).asData?.value.data;
    final code = effectiveShiftCode(ref);

    String text;
    if (code == null) {
      text = 'All shifts';
    } else if (filter.auto && live != null) {
      text = 'Shift ${live.code} • running now';
    } else {
      text = 'Shift $code';
    }

    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: DplColors.textSecondary,
      ),
    );
  }
}
