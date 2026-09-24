import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_app_bar.dart';

/// A ConsumerWidget rather than a StatelessWidget SOLELY so the Maxion tile
/// below can be permission-gated.
///
/// Every other tile here is pre-existing DPL master data that has always been
/// on this screen for a manager; those stay unconditional. The pallet register
/// is a Maxion capability, and a capability an administrator cannot switch off
/// is not a capability an administrator controls.
class DplMastersHubScreen extends ConsumerWidget {
  final bool embedded;

  const DplMastersHubScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canViewPallets =
        ref.watch(dplPermissionsProvider).can(DplPermission.palletView);
    final body = Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF8FBFF), Color(0xFFF2FFF9), Color(0xFFF7F2FF)],
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE2EAF6)),
            ),
            child: const Text(
              'Manage master data used across plans and reports.',
              style: TextStyle(color: Color(0xFF5D6A7A)),
            ),
          ),
          const SizedBox(height: 12),
          _OptionCard(
            icon: Icons.precision_manufacturing_outlined,
            color: const Color(0xFF1D4ED8),
            title: 'Machines',
            subtitle: 'Production machines used for daily plans.',
            onTap: () => context.push('/dpl/manager/masters/machines'),
          ),
          const SizedBox(height: 10),
          _OptionCard(
            icon: Icons.inventory_2_outlined,
            color: const Color(0xFF047857),
            title: 'Parts',
            subtitle: 'Searchable, paginated parts catalogue.',
            onTap: () => context.push('/dpl/manager/masters/parts'),
          ),
          const SizedBox(height: 10),
          _OptionCard(
            icon: Icons.report_outlined,
            color: const Color(0xFFB45309),
            title: 'Downtime Reasons',
            subtitle: 'Planned & unplanned reasons used by the Pareto report.',
            onTap: () =>
                context.push('/dpl/manager/masters/downtime-reasons'),
          ),
          const SizedBox(height: 10),
          _OptionCard(
            icon: Icons.access_time,
            color: const Color(0xFF7C3AED),
            title: 'Shifts',
            subtitle:
                'Shift A / B / C windows. Drives the Monthly Chart and '
                'auto-tags every start / downtime event.',
            onTap: () => context.push('/dpl/manager/masters/shifts'),
          ),
          const SizedBox(height: 10),
          _OptionCard(
            icon: Icons.groups_outlined,
            color: const Color(0xFF0EA5E9),
            title: 'Manpower',
            subtitle: 'Per-shift headcount log — powers work-hours '
                'and lost-hours calculations.',
            onTap: () => context.push('/dpl/manager/masters/manpower'),
          ),
          const SizedBox(height: 10),
          _OptionCard(
            icon: Icons.verified_user_outlined,
            color: const Color(0xFFB45309),
            title: 'Identity Audit',
            subtitle: 'Supervisor selfies captured per shift — view '
                'photo, capture time and flag suspicious entries.',
            onTap: () => context.push('/dpl/manager/identity-audit'),
          ),
          const SizedBox(height: 10),
          // ───── Dispatch-planning baseline inputs ─────
          // These two fields drive the daily dispatch formula but
          // change rarely (norms = once, opening stock = monthly), so
          // they belong here in Settings rather than on the daily
          // dispatch-planning hub.
          _OptionCard(
            icon: Icons.layers_outlined,
            color: const Color(0xFF6B1F8C),
            title: 'Stocking Norm',
            subtitle:
                'Per-part safe-stock target at the customer. Configure '
                'once — feeds the daily dispatch calculation.',
            onTap: () => context.push('/dpl/manager/stocking-norms'),
          ),
          const SizedBox(height: 10),
          _OptionCard(
            icon: Icons.inventory_outlined,
            color: const Color(0xFFB45309),
            title: 'Customer Opening Stock',
            subtitle:
                'What the customer is currently holding per part. '
                'Refresh monthly — feeds the daily dispatch calculation.',
            onTap: () =>
                context.push('/dpl/manager/customer-opening-stocks'),
          ),
          const SizedBox(height: 10),
          _OptionCard(
            icon: Icons.warehouse_outlined,
            color: const Color(0xFF1D4ED8),
            title: 'Opening Stock at GA',
            subtitle:
                'Opening stock held at GA per part. Refresh monthly — '
                'seeds the buffer report\'s "Opn Stock at GA" column.',
            onTap: () => context.push('/dpl/manager/ga-opening-stocks'),
          ),
          const SizedBox(height: 10),
          _OptionCard(
            icon: Icons.all_inbox_outlined,
            color: const Color(0xFF0E7C66),
            title: 'Packaging Qty',
            subtitle:
                'Units per pack for each part (e.g. 14 NOS / pack). '
                'Powers the "Pack: N NOS" hint next to every qty input.',
            onTap: () => context.push('/dpl/manager/packaging-qtys'),
          ),
          const SizedBox(height: 10),
          _OptionCard(
            icon: Icons.warehouse_outlined,
            color: const Color(0xFF7C3AED),
            title: 'Storage Locations',
            subtitle:
                'Racks and floor positions finished goods are stored at, each '
                'with a capacity. QA picks from this list, and the capacity is '
                'what stops a location being over-filled.',
            onTap: () => context.push('/dpl/manager/masters/locations'),
          ),
          if (canViewPallets) ...[
            const SizedBox(height: 10),
            _OptionCard(
              icon: Icons.grid_view_outlined,
              color: const Color(0xFF0F766E),
              title: 'Pallets Built',
              subtitle:
                  'Every pallet the pack point has closed, with filters for '
                  'item, line, type and pack date. Reprint a pallet sticker, '
                  'and see which half pallets are still waiting to be filled.',
              onTap: () => context.push('/dpl/manager/pallets'),
            ),
          ],
        ],
      ),
    );

    return Scaffold(
      appBar: const DplAppBar(title: 'Settings'),
      body: body,
    );
  }
}

class _OptionCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _OptionCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2EAF6)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(color: Color(0xFF5D6A7A)),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios_rounded, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}
