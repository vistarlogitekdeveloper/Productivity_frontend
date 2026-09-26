import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../models/dpl_logistics.dart';
import '../common/maxion_kit.dart';
import 'logistics_providers.dart';

/// A gate pass number made safe for a file name ("GP/PL2/260925/1" → "GP-PL2-260925-1").
String gatePassFileName(String gatePassNo, int tripId) {
  final base = gatePassNo.trim().isEmpty ? 'gate-pass-trip-$tripId' : gatePassNo.trim();
  return '${base.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.pdf';
}

/// The outward gate pass / delivery challan for a trip (§8.3).
class DplGatePassScreen extends ConsumerStatefulWidget {
  const DplGatePassScreen({super.key, required this.tripId, this.showAppBar = true});

  final int tripId;
  final bool showAppBar;

  @override
  ConsumerState<DplGatePassScreen> createState() => _DplGatePassScreenState();
}

class _DplGatePassScreenState extends ConsumerState<DplGatePassScreen> {
  bool _printing = false;
  bool _saving = false;

  Future<void> _print(DplGatePass gp) async {
    setState(() => _printing = true);
    final res = await ref.read(dplApiServiceProvider).getGatePassPdf(widget.tripId);
    if (!mounted) return;
    setState(() => _printing = false);
    if (res.isError || res.data == null) {
      showFloorError(context, res, fallback: 'Could not download the gate pass.');
      return;
    }
    final bytes = res.data!;
    try {
      await Printing.layoutPdf(name: gp.gatePassNo.isEmpty ? 'Gate pass' : gp.gatePassNo, onLayout: (_) async => bytes);
    } on MissingPluginException {
      if (!mounted) return;
      await saveServerFile(context, res, fileName: gatePassFileName(gp.gatePassNo, widget.tripId), mimeType: pdfMime);
    }
  }

  Future<void> _savePdf(DplGatePass gp) async {
    setState(() => _saving = true);
    final res = await ref.read(dplApiServiceProvider).getGatePassPdf(widget.tripId);
    if (!mounted) return;
    setState(() => _saving = false);
    await saveServerFile(context, res, fileName: gatePassFileName(gp.gatePassNo, widget.tripId), mimeType: pdfMime);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(gatePassProvider(widget.tripId));
    void retry() => ref.invalidate(gatePassProvider(widget.tripId));

    final body = async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => DplInlineErrorRetry(message: e.toString(), onRetry: retry),
      data: (res) {
        if (res.code == 'NOTHING_TO_SHIP') {
          return LogisticsFriendlyEmpty(
            icon: Icons.local_shipping_outlined,
            title: 'No approved slip on this trip yet',
            message: 'The gate pass is built from approved slips. Approve the slip, then come back here.',
            onRetry: retry,
          );
        }
        if (res.isError || res.data == null) {
          return DplInlineErrorRetry(
            message: res.floorMessage.isEmpty ? 'Could not build the gate pass.' : res.floorMessage,
            onRetry: retry,
          );
        }
        return RefreshIndicator(
          onRefresh: () async => retry(),
          child: _content(res.data!),
        );
      },
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(title: 'Gate pass'),
      body: body,
    );
  }

  Widget _content(DplGatePass gp) {
    final s = gp.shipment;
    return ListView(
      padding: const EdgeInsets.all(DplSpacing.md),
      children: [
        if (!gp.readyForGate) ...[
          GatePassIncompleteBanner(missing: gp.missing),
          const SizedBox(height: DplSpacing.md),
        ],
        DplCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(gp.gatePassNo, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                    Text('Trip #${s.tripNumber}${s.tripDate == null ? '' : ' · ${s.tripDate}'}',
                        style: TextStyle(color: DplColors.textSecondary, fontSize: 12.5)),
                    const SizedBox(height: 10),
                    GatePassShipmentFacts(shipment: s),
                  ],
                ),
              ),
              if (gp.qrToken.isNotEmpty) ...[
                const SizedBox(width: 12),
                Column(
                  children: [
                    QrImageView(data: gp.qrToken, size: 120, backgroundColor: Colors.white),
                    Text('Security scans this', style: TextStyle(fontSize: 10.5, color: DplColors.textSecondary)),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: DplSpacing.md),
        DplCard(
          padding: const EdgeInsets.symmetric(vertical: DplSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: DplSpacing.lg),
                child: Text('Items', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              ),
              GatePassLinesTable(lines: gp.lines),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: DplSpacing.lg),
                child: Wrap(spacing: 8, children: [
                  DplCountChip(label: 'Total qty', count: gp.totalQty),
                  DplCountChip(label: 'Pallets', count: gp.totalPallets, color: DplColors.info),
                ]),
              ),
            ],
          ),
        ),
        const SizedBox(height: DplSpacing.lg),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _printing ? null : () => _print(gp),
                icon: _printing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.print_outlined, size: 18),
                label: const Text('Print'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : () => _savePdf(gp),
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Save PDF'),
              ),
            ),
          ],
        ),
        const SizedBox(height: DplSpacing.lg),
      ],
    );
  }
}

/// Red banner listing what the gate pass still lacks before the truck may go.
class GatePassIncompleteBanner extends StatelessWidget {
  const GatePassIncompleteBanner({super.key, required this.missing});

  final List<String> missing;

  static String _label(String key) => switch (key) {
        'vehicle' => 'vehicle no',
        'transporter' => 'transporter',
        'driver' => 'driver',
        'seal' => 'seal no',
        'consignee' => 'consignee',
        _ => key.replaceAll('_', ' '),
      };

  @override
  Widget build(BuildContext context) {
    final text = missing.isEmpty ? 'details missing' : missing.map(_label).join(', ');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DplColors.errorBg,
        border: Border.all(color: DplColors.error.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(DplRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.block, color: DplColors.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Incomplete: $text. Security will not let the truck out until these are filled in the shipment details.',
              style: TextStyle(color: DplColors.error, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// Consignee, transporter, vehicle, driver, seal and LR as label/value rows.
class GatePassShipmentFacts extends StatelessWidget {
  const GatePassShipmentFacts({super.key, required this.shipment});

  final DplTripShipment shipment;

  @override
  Widget build(BuildContext context) {
    final s = shipment;
    String? driver = s.driverName;
    if (s.driverMobile != null && s.driverMobile!.isNotEmpty) {
      driver = driver == null ? s.driverMobile : '$driver · ${s.driverMobile}';
    }
    String? lr = s.lrNo;
    if (lr != null && s.lrDate != null) lr = '$lr · ${s.lrDate!.length >= 10 ? s.lrDate!.substring(0, 10) : s.lrDate}';
    final rows = <(String, String?)>[
      ('Consignee', s.consignee?.name),
      ('Transporter', s.transporter?.name),
      ('Vehicle', s.vehicleNo),
      ('Driver', driver),
      ('Seal', s.sealNo),
      ('LR', lr),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 92,
                  child: Text(r.$1, style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary)),
                ),
                Expanded(
                  child: Text(
                    (r.$2 == null || r.$2!.isEmpty) ? '—' : r.$2!,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The gate pass lines: item, HSN, qty, pallets, pallet numbers, invoice.
class GatePassLinesTable extends StatelessWidget {
  const GatePassLinesTable({super.key, required this.lines});

  final List<DplGatePassLine> lines;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(16),
        child: Text('No lines.', style: TextStyle(color: DplColors.textSecondary)),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 36,
        dataRowMinHeight: 40,
        dataRowMaxHeight: 64,
        columnSpacing: 18,
        columns: const [
          DataColumn(label: Text('Item')),
          DataColumn(label: Text('HSN')),
          DataColumn(label: Text('Qty'), numeric: true),
          DataColumn(label: Text('Pallets'), numeric: true),
          DataColumn(label: Text('Pallet nos')),
          DataColumn(label: Text('Invoice')),
        ],
        rows: [
          for (final l in lines)
            DataRow(cells: [
              DataCell(Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.customerPartNo, style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (l.description.isNotEmpty)
                    Text(l.description, style: TextStyle(fontSize: 11.5, color: DplColors.textSecondary)),
                ],
              )),
              DataCell(Text(l.hsnCode ?? '—')),
              DataCell(Text('${l.qty}')),
              DataCell(Text('${l.palletCount}')),
              DataCell(ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(l.palletNos.isEmpty ? '—' : l.palletNos, style: const TextStyle(fontSize: 12)),
              )),
              DataCell(Text(l.invoiceNos.isEmpty ? '—' : l.invoiceNos)),
            ]),
        ],
      ),
    );
  }
}

/// A calm empty state with no font download behind it (safe in widget tests).
class LogisticsFriendlyEmpty extends StatelessWidget {
  const LogisticsFriendlyEmpty({super.key, required this.title, this.message, this.icon = Icons.inbox_outlined, this.onRetry});

  final String title;
  final String? message;
  final IconData icon;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 36,
              backgroundColor: DplColors.primaryTint,
              child: Icon(icon, size: 36, color: DplColors.primary),
            ),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(message!, textAlign: TextAlign.center, style: TextStyle(color: DplColors.textSecondary)),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh, size: 18), label: const Text('Check again')),
            ],
          ],
        ),
      ),
    );
  }
}
