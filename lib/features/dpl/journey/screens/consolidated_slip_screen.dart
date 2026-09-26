import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_organization_provider.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_consolidated_slip.dart';
import '../../summary/services/consolidated_slip_pdf.dart';

/// Consolidated trip slip — the whole trip rendered in the Vistar Pulse
/// dispatch-slip format (gradient band, plate identity strip, "SCAN TO
/// VERIFY" QR sidebar, `# / PART DESCRIPTION / CUSTOMER P/N / QUANTITY`
/// table + TOTAL DISPATCHED) with every slip's lines combined. On-screen
/// twin of [ConsolidatedSlipPdfBuilder] — view = print.
class ConsolidatedSlipScreen extends ConsumerStatefulWidget {
  final int tripId;
  const ConsolidatedSlipScreen({super.key, required this.tripId});

  @override
  ConsumerState<ConsolidatedSlipScreen> createState() =>
      _ConsolidatedSlipScreenState();
}

class _ConsolidatedSlipScreenState
    extends ConsumerState<ConsolidatedSlipScreen> {
  // ── Slip palette — kept in lockstep with the PDF builder. ──
  static const _ink = Color(0xFF1A161D);
  static const _muted = Color(0xFF78727F);
  static const _line = Color(0xFFE9E6EC);
  static const _lineSoft = Color(0xFFF1EFF3);
  static const _surface = Color(0xFFFAF9FB);
  static const _brand = Color(0xFFA3238E);
  static const _trust = Color(0xFF4F7A64);

  static const _bandDark = Color(0xFF2A0A36);
  static const _bandMid = Color(0xFF4A1163);
  static const _bandLight = Color(0xFF6B1F8C);
  static const _bandChipBg = Color(0xFFB958AB);
  static const _bandChipBorder = Color(0xFFCC8AC4);

  Future<DplConsolidatedSlip>? _future;
  DplConsolidatedSlip? _data;
  bool _printing = false;

  final _fmt = NumberFormat.decimalPattern();
  final _dateFmt = DateFormat('dd MMM yyyy');
  final _timeFmt = DateFormat('HH:mm');

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<DplConsolidatedSlip> _load() async {
    final api = ref.read(dplApiServiceProvider);
    final res = await api.getConsolidatedSlip(widget.tripId);
    if (res.isError || res.data == null) {
      throw Exception(res.error ?? 'Failed to load consolidated slip');
    }
    if (mounted) setState(() => _data = res.data);
    return res.data!;
  }

  Future<void> _refresh() async {
    final fresh = _load();
    setState(() => _future = fresh);
    await fresh;
  }

  Future<void> _print() async {
    final data = _data;
    if (data == null || _printing) return;
    setState(() => _printing = true);
    final orgLabel = ref.read(dplActiveOrganizationProvider)?.displayLabel;
    final name = 'Trip-${data.trip.tripNumber}-consolidated-slip';
    try {
      await Printing.layoutPdf(
        name: name,
        onLayout: (_) =>
            ConsolidatedSlipPdfBuilder.build(data, organizationLabel: orgLabel),
      );
    } on MissingPluginException {
      if (mounted) {
        DplSnacks.error(
          context,
          'Print not available in this build. Please fully restart the app '
          '(stop + run again) so the print plugin is registered.',
        );
      }
    } catch (e) {
      if (mounted) {
        DplSnacks.error(context, 'Failed to open print sheet: $e');
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPrint = _data != null && !_printing;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Consolidated Slip',
        actions: [
          IconButton(
            tooltip: 'Print slip',
            icon: _printing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.print_outlined),
            onPressed: canPrint ? _print : null,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<DplConsolidatedSlip>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _errorState(snap.error.toString());
          }
          return _sheet(snap.data!);
        },
      ),
    );
  }

  Widget _errorState(String message) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: DplColors.error, size: 40),
            const SizedBox(height: 12),
            Text(
              message.replaceFirst('Exception: ', ''),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: _refresh, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  // ── The document sheet. ──
  Widget _sheet(DplConsolidatedSlip data) {
    final rows = data.flattenRows();
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _line),
                  boxShadow: DplShadows.card,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _band(data),
                    LayoutBuilder(
                      builder: (context, c) {
                        final wide = c.maxWidth >= 700;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _identity(data, rows, wide),
                            _body(data, rows, wide),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Header band. ──
  Widget _band(DplConsolidatedSlip data) {
    final slipCount = data.slips.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [_bandDark, _bandMid, _bandLight],
          stops: [0.0, 0.5, 1.0],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _bandChipBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _bandChipBorder),
            ),
            child: const Text(
              'GA',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 19,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Grupo Antolin India Private Limited',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 18,
                letterSpacing: 0.4,
                height: 1.15,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'DISPATCH SLIP',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  letterSpacing: 2.0,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _bandChipBg,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: _bandChipBorder),
                ),
                child: Text(
                  'Trip #${data.trip.tripNumber}  ·  $slipCount '
                  'slip${slipCount == 1 ? '' : 's'}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Identity strip — 5 cells across on wide, stacked on narrow. ──
  Widget _identity(
    DplConsolidatedSlip data,
    List<DplConsolidatedSlipRow> rows,
    bool wide,
  ) {
    final trip = data.trip;
    final plant = trip.plantName.isNotEmpty ? trip.plantName : trip.plantCode;

    final machines = rows
        .map((r) => r.machineLabel.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    final machineLabel = machines.length <= 1
        ? (machines.isEmpty ? '—' : machines.first)
        : '${machines.length} machines';

    final firstPart = rows.isEmpty
        ? '—'
        : (rows.first.description.trim().isNotEmpty
            ? rows.first.description.trim()
            : rows.first.partLabel);
    final partSub = rows.length > 1 ? '+ ${rows.length - 1} more' : null;

    DateTime? disp;
    for (final s in data.slips) {
      final at = s.dispatchedAt;
      if (at != null && (disp == null || at.isAfter(disp))) disp = at;
    }
    final dateStr = disp == null ? '—' : _dateFmt.format(disp.toLocal());
    final timeStr = disp == null ? null : '${_timeFmt.format(disp.toLocal())} IST';

    final cells = <_IdCell>[
      _IdCell(
        label: 'VEHICLE',
        value: data.vehicleNo.trim().isEmpty ? '—' : data.vehicleNo.trim(),
        plate: true,
        surface: true,
        flex: 14,
      ),
      _IdCell(label: 'PLANT', value: plant, flex: 10),
      _IdCell(label: 'MACHINE', value: machineLabel, flex: 10),
      _IdCell(
          label: 'PART DESCRIPTION',
          value: firstPart,
          sub: partSub,
          plate: true,
          flex: 10),
      _IdCell(label: 'DISPATCHED', value: dateStr, sub: timeStr, flex: 11),
    ];

    if (wide) {
      return Container(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: _line)),
        ),
        child: Row(
          // `start` (not stretch): this Row sits in an unbounded-height
          // scroll column, where a stretch Row forces children to
          // minHeight:infinity and fails to lay out.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < cells.length; i++)
              Expanded(
                flex: cells[i].flex,
                child: _idCellWidget(cells[i], leftBorder: i != 0),
              ),
          ],
        ),
      );
    }
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < cells.length; i++)
            Container(
              decoration: BoxDecoration(
                color: cells[i].surface ? _surface : Colors.white,
                border: Border(
                  top: i == 0
                      ? BorderSide.none
                      : const BorderSide(color: _lineSoft),
                ),
              ),
              child: _idCellWidget(cells[i], leftBorder: false),
            ),
        ],
      ),
    );
  }

  Widget _idCellWidget(_IdCell cell, {required bool leftBorder}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
      decoration: BoxDecoration(
        color: cell.surface ? _surface : null,
        border: Border(
          left: leftBorder
              ? const BorderSide(color: _lineSoft)
              : BorderSide.none,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            cell.label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
              color: _ink,
            ),
          ),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              cell.value,
              maxLines: 1,
              style: TextStyle(
                fontSize: cell.plate ? 24 : 20,
                fontWeight: FontWeight.w800,
                color: _ink,
                letterSpacing: 0.4,
              ),
            ),
          ),
          if (cell.sub != null) ...[
            const SizedBox(height: 3),
            Text(
              cell.sub!,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: _muted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Body — QR sidebar + parts table. ──
  Widget _body(
    DplConsolidatedSlip data,
    List<DplConsolidatedSlipRow> rows,
    bool wide,
  ) {
    if (wide) {
      // `start`, NOT IntrinsicHeight+stretch: the QR sidebar contains a
      // QrImageView (internally a LayoutBuilder), and IntrinsicHeight over a
      // LayoutBuilder throws. The QR panel reads as a top-left card.
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 210, child: _qrSidebar(data)),
          Expanded(child: _partsColumn(data, rows, wide)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _qrSidebar(data),
        _partsColumn(data, rows, wide),
      ],
    );
  }

  Widget _qrSidebar(DplConsolidatedSlip data) {
    return Container(
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(right: BorderSide(color: _line)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'SCAN TO VERIFY',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
              color: _ink,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _line),
            ),
            child: data.qrToken.isNotEmpty
                ? QrImageView(
                    data: data.qrToken,
                    version: QrVersions.auto,
                    size: 150,
                    padding: EdgeInsets.zero,
                  )
                : const SizedBox(
                    width: 150,
                    height: 150,
                    child: Center(
                      child: Text(
                        'QR not\navailable',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: _muted),
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Scan at Origin Gate (Security)\nand TATA Dock (QRE) · HMAC-signed',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _trust,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _partsColumn(
    DplConsolidatedSlip data,
    List<DplConsolidatedSlipRow> rows,
    bool wide,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _partsHeader(wide),
        for (var i = 0; i < rows.length; i++)
          _partRow(
            i + 1,
            rows[i],
            firstOfSlip: i == 0 || rows[i].slipId != rows[i - 1].slipId,
            isLast: i == rows.length - 1,
            wide: wide,
          ),
        _totalRow(data, rows.length),
      ],
    );
  }

  Widget _partsHeader(bool wide) {
    const style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.1,
      color: _ink,
    );
    return Container(
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(bottom: BorderSide(color: _line)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
      child: Row(
        children: [
          const SizedBox(width: 30, child: Text('#', style: style)),
          const Expanded(flex: 11, child: Text('PART DESCRIPTION', style: style)),
          if (wide)
            const Expanded(flex: 6, child: Text('CUSTOMER P/N', style: style)),
          const SizedBox(
            width: 96,
            child:
                Text('QUANTITY', textAlign: TextAlign.right, style: style),
          ),
        ],
      ),
    );
  }

  Widget _partRow(
    int index,
    DplConsolidatedSlipRow row, {
    required bool firstOfSlip,
    required bool isLast,
    required bool wide,
  }) {
    final partName = row.partName.trim().isNotEmpty
        ? row.partName.trim()
        : (row.description.trim().isNotEmpty
            ? row.description.trim()
            : row.partLabel);
    final hasSub = row.description.trim().isNotEmpty &&
        row.description.trim() != partName.trim();
    final pn = row.customerPartNo.trim();

    return Container(
      decoration: BoxDecoration(
        color: firstOfSlip ? Colors.white : _surface,
        border: Border(
          bottom: BorderSide(color: isLast ? _line : _lineSoft),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 30,
            child: Text(
              index.toString().padLeft(2, '0'),
              style: const TextStyle(
                fontSize: 12,
                color: _muted,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            flex: 11,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  partName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: _ink,
                    letterSpacing: 0.2,
                    height: 1.15,
                  ),
                ),
                if (hasSub) ...[
                  const SizedBox(height: 2),
                  Text(
                    row.description.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: _brand,
                    ),
                  ),
                ],
                // On narrow screens the P/N column is dropped — show it here.
                if (!wide && pn.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'P/N  $pn',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: _muted),
                  ),
                ],
              ],
            ),
          ),
          if (wide)
            Expanded(
              flex: 6,
              child: Text(
                pn.isEmpty ? '—' : pn,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: _ink,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          SizedBox(
            width: 96,
            child: Text.rich(
              textAlign: TextAlign.right,
              TextSpan(
                children: [
                  TextSpan(
                    text: _fmt.format(row.qty),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: _ink,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const TextSpan(
                    text: '  NOS',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: _muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalRow(DplConsolidatedSlip data, int lineCount) {
    final slipCount = data.slips.length;
    return Container(
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(top: BorderSide(color: _ink, width: 1.4)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: 30),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'TOTAL DISPATCHED',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.4,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$slipCount slip${slipCount == 1 ? '' : 's'}  ·  '
                  '$lineCount line item${lineCount == 1 ? '' : 's'}  ·  '
                  'verified at loading',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _muted,
                  ),
                ),
              ],
            ),
          ),
          Text.rich(
            textAlign: TextAlign.right,
            TextSpan(
              children: [
                TextSpan(
                  text: _fmt.format(data.totalQty),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: _brand,
                  ),
                ),
                const TextSpan(
                  text: '  NOS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: _muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One identity-strip cell descriptor.
class _IdCell {
  final String label;
  final String value;
  final String? sub;
  final bool plate;
  final bool surface;
  final int flex;
  const _IdCell({
    required this.label,
    required this.value,
    this.sub,
    this.plate = false,
    this.surface = false,
    this.flex = 10,
  });
}
