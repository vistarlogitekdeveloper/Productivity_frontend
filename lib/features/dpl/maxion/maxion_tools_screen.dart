import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design/dpl_theme.dart';
import '../core/dpl_api_service.dart';
import '../core/dpl_language_provider.dart';
import '../core/dpl_permissions_provider.dart';
import '../core/widgets/dpl_app_bar.dart';
import '../core/widgets/dpl_error_retry.dart';
import '../models/dpl_dispatch_trip.dart';
import 'logistics/customer_returns_screen.dart';
import 'logistics/gate_pass_screen.dart';
import 'logistics/gate_pass_verify_screen.dart';
import 'logistics/reversal_widgets.dart';
import 'logistics/trip_shipment_screen.dart';
import 'manager/logistics_masters_screen.dart';
import 'manager/oem_dashboard_screen.dart';
import 'manager/opening_stock_screen.dart';
import 'manager/scheduled_emails_screen.dart';
import 'manager/stock_reports_screen.dart';
import 'stock/rack_count_screen.dart';
import 'stock/stock_adjustments_screen.dart';
import 'sync/sync_status_widgets.dart';

/// One entry on the Tools hub: what it is, who may see it, where it goes.
class DplMaxionTool {
  final String title;
  final String subtitle;
  final IconData icon;

  /// Shown when the user holds ANY of these keys.
  final List<String> anyOf;
  final Widget Function() build;

  const DplMaxionTool({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.anyOf,
    required this.build,
  });
}

/// Every Maxion tool (backend phases 1–4 and offline handhelds), in the order
/// the floor uses them. Each is gated by the same permission the server
/// enforces, so a tile never leads to a screen whose every action is refused.
final List<DplMaxionTool> dplMaxionTools = [
  DplMaxionTool(
    title: 'OEM dashboard',
    subtitle: 'Plan vs dispatch per lane, and what needs attention',
    icon: Icons.space_dashboard_outlined,
    anyOf: const [DplPermission.reportsStock],
    build: () => const DplOemDashboardScreen(),
  ),
  DplMaxionTool(
    title: 'Stock & dispatch reports',
    subtitle: 'FG stock, racks, dispatch register, ageing, labels — Excel',
    icon: Icons.table_chart_outlined,
    anyOf: const [DplPermission.reportsStock],
    build: () => const DplStockReportsScreen(),
  ),
  DplMaxionTool(
    title: 'Trips: shipment & gate pass',
    subtitle: 'Transporter, driver, seal, LR, dock times; print the gate pass',
    icon: Icons.local_shipping_outlined,
    anyOf: const [DplPermission.tripsShipment, DplPermission.gatepassView],
    build: () => const DplTripsLogisticsScreen(),
  ),
  DplMaxionTool(
    title: 'Verify a gate pass',
    subtitle: 'Scan the QR at the gate before the truck leaves',
    icon: Icons.verified_user_outlined,
    anyOf: const [DplPermission.gatepassView],
    build: () => const DplGatePassVerifyScreen(),
  ),
  DplMaxionTool(
    title: 'Customer returns',
    subtitle: 'Receive wheels back into quarantine; QA restocks or scraps',
    icon: Icons.assignment_return_outlined,
    anyOf: const [DplPermission.returnsReceive, DplPermission.returnsDisposition],
    build: () => const DplCustomerReturnsScreen(),
  ),
  DplMaxionTool(
    title: 'Shipment reversals',
    subtitle: 'Approve or reject reversal requests',
    icon: Icons.undo_outlined,
    anyOf: const [DplPermission.slipsReverseApprove],
    build: () => const DplPendingReversalsScreen(),
  ),
  DplMaxionTool(
    title: 'Rack counts',
    subtitle: 'Blind count of pallets per rack, approved by someone else',
    icon: Icons.fact_check_outlined,
    anyOf: const [DplPermission.stockCount, DplPermission.stockCountApprove],
    build: () => const DplRackCountsScreen(),
  ),
  DplMaxionTool(
    title: 'Stock adjustments',
    subtitle: 'Raise or approve lot changes and write-offs',
    icon: Icons.tune_outlined,
    anyOf: const [DplPermission.stockAdjust, DplPermission.stockAdjustApprove],
    build: () => const DplStockAdjustmentsScreen(),
  ),
  DplMaxionTool(
    title: 'Opening stock from Ekatm',
    subtitle: 'Preview and import the old system’s stock export',
    icon: Icons.upload_file_outlined,
    anyOf: const [DplPermission.stockImport],
    build: () => const DplOpeningStockScreen(),
  ),
  DplMaxionTool(
    title: 'Transporters, consignees & lanes',
    subtitle: 'The masters shipments and trips pick from',
    icon: Icons.contacts_outlined,
    anyOf: const [DplPermission.mastersView, DplPermission.mastersEdit],
    build: () => const DplLogisticsMastersScreen(),
  ),
  DplMaxionTool(
    title: 'Scheduled report emails',
    subtitle: 'Who gets the daily dispatch and stock mail, and when',
    icon: Icons.schedule_send_outlined,
    anyOf: const [DplPermission.reportsSchedule],
    build: () => const DplScheduledEmailsScreen(),
  ),
  DplMaxionTool(
    title: 'Handheld sync',
    subtitle: 'Scans refused after reconnecting, and each device’s queue',
    icon: Icons.sync_problem_outlined,
    anyOf: const [DplPermission.syncResolve],
    build: () => const DplSyncConflictsScreen(),
  ),
];

/// The tools this user may open. With permissions unknown every Maxion key is
/// opt-in denied, so the hub is empty rather than full of refusals.
List<DplMaxionTool> visibleMaxionTools(DplPermissions perms) =>
    dplMaxionTools.where((t) => perms.canAny(t.anyOf)).toList();

/// Whether to show the Tools entry at all in a shell.
bool hasAnyMaxionTool(DplPermissions perms) =>
    visibleMaxionTools(perms).isNotEmpty || perms.can(DplPermission.syncPush);

/// The Tools hub: one list of every Maxion screen this person may use, plus
/// the floor language and the handheld's sync status.
class DplMaxionToolsScreen extends ConsumerWidget {
  final bool showAppBar;

  const DplMaxionToolsScreen({super.key, this.showAppBar = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(dplPermissionsProvider);
    final tools = visibleMaxionTools(perms);
    final lang = ref.watch(dplLanguageProvider);

    final body = ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (perms.can(DplPermission.syncPush))
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Align(alignment: Alignment.centerLeft, child: DplSyncStatusChip()),
          ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.translate),
            title: const Text('Floor language'),
            subtitle: const Text('Refusals at the scanner in this language, with the English below'),
            trailing: DropdownButton<String>(
              value: lang ?? 'en',
              underline: const SizedBox.shrink(),
              onChanged: (v) => ref.read(dplLanguageProvider.notifier).set(v == 'en' ? null : v),
              items: DplLanguageController.choices.entries
                  .map((e) => DropdownMenuItem(value: e.key ?? 'en', child: Text(e.value)))
                  .toList(),
            ),
          ),
        ),
        if (tools.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'None of these tools are switched on for your role yet. An administrator turns them on in the permission grid.',
              textAlign: TextAlign.center,
            ),
          ),
        for (final t in tools)
          Card(
            child: ListTile(
              leading: Icon(t.icon, color: DplColors.primary),
              title: Text(t.title, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(t.subtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => t.build())),
            ),
          ),
      ],
    );

    if (!showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: const DplAppBar(title: 'Tools'),
      body: body,
    );
  }
}

/// Recent trips, each with Shipment details and Gate pass. Shipment details
/// start at vehicle-in, and the gate pass needs an approved slip, so both
/// open trips and fulfilled (fully slipped) ones are listed.
class DplTripsLogisticsScreen extends ConsumerStatefulWidget {
  const DplTripsLogisticsScreen({super.key});

  @override
  ConsumerState<DplTripsLogisticsScreen> createState() => _DplTripsLogisticsScreenState();
}

final _logisticsTripsProvider = FutureProvider.autoDispose.family((ref, DateTime day) =>
    ref.watch(dplApiServiceProvider).listTrips(statuses: const ['open', 'partial', 'fulfilled'], date: day, limit: 100));

class _DplTripsLogisticsScreenState extends ConsumerState<DplTripsLogisticsScreen> {
  DateTime _day = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(dplPermissionsProvider);
    final async = ref.watch(_logisticsTripsProvider(_day));
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Trips: shipment & gate pass',
        actions: [
          IconButton(
            tooltip: 'Pick a day',
            icon: const Icon(Icons.calendar_today_outlined),
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                firstDate: DateTime.now().subtract(const Duration(days: 60)),
                lastDate: DateTime.now().add(const Duration(days: 14)),
                initialDate: _day,
              );
              if (picked != null) setState(() => _day = picked);
            },
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => DplInlineErrorRetry(message: e.toString(), onRetry: () => ref.invalidate(_logisticsTripsProvider(_day))),
        data: (res) {
          if (res.isError) {
            return DplInlineErrorRetry(message: res.error ?? 'Could not load trips.', onRetry: () => ref.invalidate(_logisticsTripsProvider(_day)));
          }
          final List<DplTrip> trips = res.data?.trips ?? const [];
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(_logisticsTripsProvider(_day)),
            child: trips.isEmpty
                ? ListView(children: const [Padding(padding: EdgeInsets.all(32), child: Text('No trips on this day.', textAlign: TextAlign.center))])
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: trips.length,
                    itemBuilder: (_, i) {
                      final t = trips[i];
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Trip #${t.tripNumber} · ${t.plantCode}', style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text('Status: ${t.status}${t.vehicleNo == null ? '' : ' · ${t.vehicleNo}'}'),
                              const SizedBox(height: 8),
                              Wrap(spacing: 8, children: [
                                if (perms.canAny(const [DplPermission.tripsShipment, DplPermission.gatepassView]))
                                  OutlinedButton.icon(
                                    icon: const Icon(Icons.edit_note, size: 18),
                                    label: const Text('Shipment'),
                                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                                        builder: (_) => DplTripShipmentScreen(tripId: t.id, tripNumber: t.tripNumber))),
                                  ),
                                if (perms.can(DplPermission.gatepassView))
                                  FilledButton.icon(
                                    icon: const Icon(Icons.receipt_long, size: 18),
                                    label: const Text('Gate pass'),
                                    onPressed: () => Navigator.of(context)
                                        .push(MaterialPageRoute(builder: (_) => DplGatePassScreen(tripId: t.id))),
                                  ),
                              ]),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          );
        },
      ),
    );
  }
}
