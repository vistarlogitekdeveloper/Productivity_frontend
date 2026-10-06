import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/scanner/hardware_scanner.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_content_width.dart';
import '../../core/widgets/dpl_scan_panel.dart';
import '../../models/dpl_pallet.dart';
import '../../models/dpl_spd.dart';
import 'dpl_qr_scan_sheet.dart';

/// "What is this?" — scan a pallet sticker or a wheel label and see where it
/// belongs.
///
///   * Pallet sticker -> the pallet, where it is, and every wheel on it.
///   * Wheel label    -> the pallet that wheel is on, with that wheel picked
///                       out at the top of the list.
///
/// Opened from Pallets built and from the auditor's screens. Read-only: it
/// moves nothing, so it is safe to scan anything at all here. The field stays
/// focused after every answer, so the next scan simply replaces the result.
class PalletLookupScreen extends ConsumerStatefulWidget {
  const PalletLookupScreen({super.key, this.initialCode});

  /// Look this up straight away — a pallet number tapped in Pallets built
  /// opens here already showing its wheels.
  final String? initialCode;

  @override
  ConsumerState<PalletLookupScreen> createState() => _PalletLookupScreenState();
}

class _PalletLookupScreenState extends ConsumerState<PalletLookupScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  /// This page is pushed over a shell whose scanner scope points at the tab
  /// underneath. Claiming the scan area is what sends a hardware trigger here
  /// instead of to that hidden tab — see HardwareScanScope.claimArea.
  final _scanArea = GlobalKey();

  bool _busy = false;
  DplScanLookup? _result;
  String? _error;
  String _scanned = '';

  @override
  void initState() {
    super.initState();
    HardwareScanScope.claimArea(_scanArea);
    final code = widget.initialCode?.trim() ?? '';
    if (code.isNotEmpty) {
      // After the first frame: the lookup calls setState.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _lookup(code);
      });
    }
  }

  @override
  void dispose() {
    HardwareScanScope.releaseArea(_scanArea);
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _lookup(String raw) async {
    final code = raw.trim();
    _ctrl.clear();
    if (code.isEmpty || _busy) return;

    setState(() {
      _busy = true;
      _scanned = code;
    });
    final res = await ref.read(dplApiServiceProvider).lookupScan(code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res.isError || res.data == null) {
        _result = null;
        _error = res.error ?? 'Could not look that label up.';
      } else {
        _result = res.data;
        _error = null;
      }
    });
    _focus.requestFocus();
  }

  Future<void> _scanWithCamera() async {
    // Either kind of label is a valid answer here, so the sheet is opened for
    // a wheel (the looser of the two) and the server decides what it was.
    final code = await DplQrScanSheet.open(context, kind: DplScanKind.any);
    if (code == null || !mounted) return;
    await _lookup(code);
  }

  @override
  Widget build(BuildContext context) {
    final canCamera = ref
        .watch(dplPermissionsProvider)
        .can(DplPermission.palletScanCamera);
    final r = _result;

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: const DplAppBar(title: 'Scan to find'),
      body: DplContentWidth(
        child: ListView(
          key: _scanArea,
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
          children: [
            DplScanPanel(
              title: 'Scan a pallet sticker or a wheel label',
              subtitle:
                  'A pallet shows every wheel on it. A wheel shows which '
                  'pallet it is on. Nothing is changed by scanning here.',
              cameraLabel: 'Scan a label',
              onCamera: canCamera ? _scanWithCamera : null,
              controller: _ctrl,
              focusNode: _focus,
              hint: 'or type a pallet number or wheel serial',
              onSubmitted: _lookup,
              busy: _busy,
              // Old Maxion labels are mixed case and matched exactly.
              capitalize: false,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _message(Icons.search_off_rounded, DplColors.error, _error!),
            ],
            if (r != null) ...[
              const SizedBox(height: 12),
              if (r.pallet == null)
                _message(
                  Icons.info_outline_rounded,
                  DplColors.warning,
                  '${r.wheel?.serialNo ?? _scanned}: '
                  '${r.note.isEmpty ? 'not on any pallet.' : r.note}',
                )
              else ...[
                _palletCard(r),
                const SizedBox(height: 12),
                _wheelsCard(r),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _message(IconData icon, Color color, String text) {
    return DplCard(
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontWeight: FontWeight.w700, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _palletCard(DplScanLookup r) {
    final DplPallet p = r.pallet!;
    final lines = <String>[
      [
        if (p.customerPartNo.isNotEmpty) p.customerPartNo,
        if (p.partDescription.isNotEmpty) p.partDescription,
      ].join(' · '),
      [
        p.typeLabel,
        p.status,
        p.locationCode.isEmpty ? 'no location' : 'on ${p.locationCode}',
      ].where((s) => s.isNotEmpty).join(' · '),
    ];

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            r.isPallet ? 'PALLET' : 'THIS WHEEL IS ON',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
              color: DplColors.primary,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  p.palletNo,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                  ),
                ),
              ),
              Text(
                p.countLabel,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                ),
              ),
            ],
          ),
          for (final l in lines.where((l) => l.isNotEmpty)) ...[
            const SizedBox(height: 2),
            Text(
              l,
              style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
            ),
          ],
          if (r.renamedFrom.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'You scanned ${r.renamedFrom}, an old label — this pallet is now '
              '${p.palletNo}. Reprint its sticker.',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: DplColors.warning,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _wheelsCard(DplScanLookup r) {
    final scannedId = r.wheel?.id;
    // The scanned wheel first, so the answer to "is it here?" is the first row.
    final wheels = [
      ...r.wheels.where((w) => w.id == scannedId),
      ...r.wheels.where((w) => w.id != scannedId),
    ];

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Wheels on this pallet (${r.wheels.where((w) => !w.isVoided).length})',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 6),
          if (wheels.isEmpty)
            Text(
              'No wheels on this pallet.',
              style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
            ),
          for (final w in wheels)
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: w.id == scannedId ? DplColors.primaryTint : null,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    w.id == scannedId
                        ? Icons.my_location_rounded
                        : w.isVoided
                        ? Icons.block_rounded
                        : Icons.circle_outlined,
                    size: 16,
                    color: w.id == scannedId
                        ? DplColors.primary
                        : DplColors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          w.serialNo,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: w.id == scannedId
                                ? FontWeight.w800
                                : FontWeight.w600,
                            decoration: w.isVoided
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        Text(
                          [
                            if (w.id == scannedId) 'Scanned',
                            if (w.isVoided) 'Voided',
                            if (w.shiftCode.isNotEmpty) 'Shift ${w.shiftCode}',
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: 11,
                            color: DplColors.textSecondary,
                          ),
                        ),
                      ],
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
