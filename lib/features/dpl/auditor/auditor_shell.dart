import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/scanner/hardware_scanner.dart';
import '../core/design/dpl_theme.dart';
import '../core/dpl_api_service.dart';
import '../core/dpl_permissions_provider.dart';
import '../core/widgets/dpl_app_bar.dart';
import '../core/widgets/dpl_bottom_nav.dart';
import '../core/widgets/dpl_snack.dart';
import '../qa/screens/pallet_lookup_screen.dart';
import 'auditor_providers.dart';
import 'screens/audit_register_screen.dart';
import 'screens/audit_scan_screen.dart';
import 'screens/pallet_audit_screen.dart';
import 'screens/pallets_to_audit_screen.dart';

/// Home for `DPL_AUDITOR` (backend migration 167).
///
/// Three tabs, in the order the job is done: the pallets there are to check,
/// the scanner that starts a check, and the register of what has been checked
/// already.
///
/// Every tab is gated on a permission the administrator grants, because the
/// audit is a Maxion capability like the rest — a plant that has never asked
/// for it gets the role in the list and nothing switched on. An auditor whose
/// administrator has granted nothing sees a screen that says so rather than an
/// empty shell they will report as broken.
class DplAuditorShell extends ConsumerStatefulWidget {
  const DplAuditorShell({super.key});

  @override
  ConsumerState<DplAuditorShell> createState() => _DplAuditorShellState();
}

class _DplAuditorShellState extends ConsumerState<DplAuditorShell> {
  int _tab = 0;

  /// One per tab. The hardware scan scope needs to know which subtree is on
  /// screen: every tab is built at once inside the IndexedStack, and on a
  /// freshly-opened one none of them holds focus, so a decode would otherwise
  /// have nowhere to go — or worse, reach all of them.
  final _tabKeys = List.generate(3, (_) => GlobalKey());

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(dplPermissionsProvider);
    final canView = perms.can(DplPermission.palletAuditView);
    final canAudit = perms.can(DplPermission.palletAuditPerform);
    final canSeePallets = perms.can(DplPermission.palletView);

    if (!canView && !canAudit) return _notEnabled(context);

    // Tabs the grid actually allows, so the bar never shows a door that opens
    // onto a 403.
    final tabs = <_AuditorTab>[
      if (canSeePallets)
        const _AuditorTab(
          title: 'Pallets',
          item: DplNavItem(
            icon: Icons.inventory_2_outlined,
            selectedIcon: Icons.inventory_2,
            label: 'Pallets',
          ),
        ),
      if (canAudit)
        const _AuditorTab(
          title: 'Audit a pallet',
          item: DplNavItem(
            icon: Icons.qr_code_scanner_outlined,
            selectedIcon: Icons.qr_code_scanner,
            label: 'Audit',
          ),
        ),
      const _AuditorTab(
        title: 'Checked',
        item: DplNavItem(
          icon: Icons.fact_check_outlined,
          selectedIcon: Icons.fact_check,
          label: 'Checked',
        ),
      ),
    ];

    final tab = _tab.clamp(0, tabs.length - 1);

    final pages = <Widget>[
      if (canSeePallets) const DplPalletsToAuditScreen(showAppBar: false),
      if (canAudit) const DplAuditScanScreen(showAppBar: false),
      const DplAuditRegisterScreen(showAppBar: false),
    ];

    return HardwareScanScope(
      // Which tab is on screen. The scope cannot work this out for itself.
      activeArea: _tabKeys[tab.clamp(0, _tabKeys.length - 1)],
      child: Scaffold(
        backgroundColor: DplColors.pageBg,
        appBar: DplAppBar(
          title: tabs[tab].title,
          actions: [
            // Scan anything to see where it belongs: a pallet shows its
            // wheels, a wheel shows its pallet. On every tab, because "which
            // pallet is this wheel on?" comes up mid-audit as often as before.
            IconButton(
              tooltip: 'Scan to find',
              icon: const Icon(Icons.qr_code_scanner_rounded),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PalletLookupScreen()),
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                ref.invalidate(dplAuditPalletsProvider);
                ref.invalidate(dplAuditRegisterProvider);
              },
            ),
          ],
        ),
        body: IndexedStack(
          index: tab,
          children: [
            for (var i = 0; i < pages.length; i++)
              KeyedSubtree(key: _tabKeys[i], child: pages[i]),
          ],
        ),
        bottomNavigationBar: DplBottomNav(
          currentIndex: tab,
          onTap: (i) {
            // The tabs live in an IndexedStack and are built once, so without
            // this a pallet audited on one tab was missing from the others
            // until Refresh. Riverpod keeps the old list on screen while the
            // new one loads, so there is no spinner flash.
            if (i != _tab) {
              ref.invalidate(dplAuditPalletsProvider);
              ref.invalidate(dplAuditRegisterProvider);
            }
            setState(() => _tab = i);
          },
          items: [for (final t in tabs) t.item],
        ),
      ),
    );
  }

  /// Nothing granted yet.
  ///
  /// Says WHO turns it on and WHAT they tick. "You do not have permission" on
  /// its own produces a support call; naming the switch produces a message to
  /// the right person.
  Widget _notEnabled(BuildContext context) {
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: const DplAppBar(title: 'Audit'),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 40, color: DplColors.textTertiary),
              const SizedBox(height: 14),
              const Text(
                'Auditing is not switched on yet',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Ask an administrator to grant "Audit a pallet" and "See the '
                'pallet audit register" to the DPL Auditor role for your '
                'organization.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: DplColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuditorTab {
  final String title;
  final DplNavItem item;
  const _AuditorTab({required this.title, required this.item});
}

/// Starts an audit from a scanned pallet label, wherever the auditor is.
///
/// Shared by the scanner tab and the "Audit" button on a row of the pallet
/// list, so there is ONE place a pallet turns into a running audit rather than
/// two that drift.
Future<void> startAuditFor(
  BuildContext context,
  WidgetRef ref, {
  String? code,
  int? palletId,
}) async {
  final res = await ref.read(dplApiServiceProvider).startPalletAudit(
        code: code,
        palletId: palletId,
      );
  if (!context.mounted) return;

  if (res.isError || res.data == null) {
    // PALLET_STILL_OPEN and the resolver's own refusals already name the
    // situation and what to do about it.
    DplSnacks.error(
      context,
      res.floorMessage.isEmpty ? 'Could not start the audit.' : res.floorMessage,
    );
    return;
  }

  final done = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => DplPalletAuditScreen(session: res.data!),
    ),
  );

  if (done == true && context.mounted) {
    ref.invalidate(dplAuditRegisterProvider);
    ref.invalidate(dplAuditPalletsProvider);
  }
}
