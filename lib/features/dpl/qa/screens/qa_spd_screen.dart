import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_spd.dart';
import '../services/pallet_label_pdf.dart';
import '../services/spd_label_pdf.dart';
import 'dpl_qr_scan_sheet.dart';

final spdPacksProvider =
    FutureProvider.autoDispose<DplApiResponse<DplSpdPage>>((ref) async {
  return ref.watch(dplApiServiceProvider).listSpdPacks();
});

/// SPD conversion — Maxion SSR §8, Module 12.
///
/// A customer orders spare parts by the WHEEL, not by the pallet. So this
/// screen scans a pallet, lists what is physically on it, and lets the
/// operator pick the wheels that are leaving. Each one becomes its own pack
/// with its own number and its own 50 x 25 mm label; whatever is left stays on
/// the pallet, which drops to a half pallet and is relabelled.
///
/// WHERE THIS DEPARTS FROM THE REFERENCE APP, DELIBERATELY. Theirs closes the
/// source as SPLIT_CONSUMED and mints a brand-new pallet for the leftovers,
/// which loses the link back and leaves a tombstone still claiming its
/// original quantity. Here the pallet survives: it keeps its identity, loses
/// the wheels that left, and is renumbered onto the H series — so the wheels
/// still on the floor and the wheels in the system stay the same wheels.
class QaSpdScreen extends ConsumerStatefulWidget {
  const QaSpdScreen({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  ConsumerState<QaSpdScreen> createState() => _QaSpdScreenState();
}

class _QaSpdScreenState extends ConsumerState<QaSpdScreen> {
  final _scanCtrl = TextEditingController();
  final _scanFocus = FocusNode();

  bool _busy = false;

  /// The pallet being taken from, once scanned.
  DplPalletWheels? _loaded;

  /// Sticker ids the operator has ticked.
  final Set<int> _picked = <int>{};

  @override
  void dispose() {
    _scanCtrl.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
      children: [
        _scanCard(),
        if (_loaded != null) ...[
          const SizedBox(height: 12),
          _wheelsCard(_loaded!),
        ] else ...[
          const SizedBox(height: 12),
          _registerCard(),
        ],
      ],
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: AppBar(title: const Text('SPD')),
      body: body,
    );
  }

  // -------------------------------------------------------------------------
  // Scan a pallet
  // -------------------------------------------------------------------------

  Widget _scanCard() {
    final canCamera =
        ref.watch(dplPermissionsProvider).can(DplPermission.palletScanCamera);

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Take wheels for a spare-parts order',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
              if (_loaded != null)
                TextButton(
                  onPressed: _busy ? null : _clear,
                  child: const Text('Start over'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Scan a pallet, pick the wheels that are leaving, and each one is '
            'labelled as its own pack.',
            style: TextStyle(fontSize: 12, color: Color(0xFF5D6A7A)),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _scanCtrl,
            focusNode: _scanFocus,
            enabled: !_busy && _loaded == null,
            textInputAction: TextInputAction.done,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              hintText: _loaded == null
                  ? 'Scan, or type the pallet number'
                  : 'Pallet loaded',
              prefixIcon: const Icon(Icons.qr_code_scanner_rounded),
              isDense: true,
              helperText: _loaded == null
                  ? 'The number is printed under the code, so a damaged label '
                      'can be keyed in by hand.'
                  : null,
              helperMaxLines: 3,
            ),
            onSubmitted: _busy ? null : _resolve,
          ),
          if (canCamera && _loaded == null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _scanWithCamera,
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: const Text('Scan with the camera'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _clear() {
    setState(() {
      _loaded = null;
      _picked.clear();
      _scanCtrl.clear();
    });
    _scanFocus.requestFocus();
  }

  Future<void> _scanWithCamera() async {
    final code = await DplQrScanSheet.open(context, kind: DplScanKind.pallet);
    if (code == null || !mounted) return;
    _scanCtrl.text = code;
    await _resolve(code);
  }

  Future<void> _resolve(String raw) async {
    final code = raw.trim();
    if (code.isEmpty) return;

    setState(() => _busy = true);
    final api = ref.read(dplApiServiceProvider);

    // Resolve the label to a pallet first — the scan carries a NUMBER, and the
    // wheels endpoint needs an id.
    final found = await api.resolvePalletForPutaway(code);
    if (!mounted) return;

    if (found.isError || found.data == null) {
      setState(() => _busy = false);
      DplSnacks.error(context, found.error ?? 'Could not read that pallet label.');
      _scanFocus.requestFocus();
      return;
    }

    if (found.data!.wasRenamed) {
      DplSnacks.warning(
        context,
        '${found.data!.renamedFrom} is now ${found.data!.pallet.palletNo}. '
        'That label is out of date — reprint it.',
      );
    }

    final res = await api.getPalletWheels(found.data!.pallet.id);
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError || res.data == null) {
      DplSnacks.error(
        context,
        res.error ?? 'Failed to load the wheels on this pallet.',
      );
      return;
    }

    final loaded = res.data!;
    if (loaded.sellable.isEmpty) {
      DplSnacks.warning(
        context,
        '${loaded.pallet.palletNo} has no wheels available to convert.',
      );
      return;
    }

    setState(() {
      _loaded = loaded;
      _picked.clear();
      _scanCtrl.clear();
    });
  }

  // -------------------------------------------------------------------------
  // Pick the wheels
  // -------------------------------------------------------------------------

  Widget _wheelsCard(DplPalletWheels loaded) {
    final p = loaded.pallet;
    final wheels = loaded.sellable;
    final standard = p.standardQty ?? 0;
    final remaining = wheels.length - _picked.length;

    return Column(
      children: [
        DplCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      p.palletNo,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  Text(
                    p.countLabel,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${p.customerPartNo}'
                '${p.partDescription.isEmpty ? '' : ' · ${p.partDescription}'}',
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF5D6A7A)),
              ),
              if (p.locationCode.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'On ${p.locationCode}',
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280)),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        DplCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Pick wheels for SPD  (${_picked.length} of ${wheels.length})',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              if (_picked.length == wheels.length) {
                                _picked.clear();
                              } else {
                                _picked
                                  ..clear()
                                  ..addAll(wheels.map((w) => w.id));
                              }
                            }),
                    child: Text(
                      _picked.length == wheels.length ? 'None' : 'All',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (final w in wheels)
                CheckboxListTile(
                  value: _picked.contains(w.id),
                  onChanged: _busy
                      ? null
                      : (on) => setState(() {
                            if (on == true) {
                              _picked.add(w.id);
                            } else {
                              _picked.remove(w.id);
                            }
                          }),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    w.serialNo,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                  subtitle: Text(
                    [
                      if (w.shiftCode.isNotEmpty) 'Shift ${w.shiftCode}',
                      if (w.machineName.isNotEmpty) w.machineName,
                      if (w.printedAt != null) _d(w.printedAt!),
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
              const SizedBox(height: 10),
              if (_picked.isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: DplColors.primaryTint,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  // Says what the press does to BOTH outcomes, before it
                  // happens. The pallet changing identity is the surprising
                  // half, so it is spelled out rather than discovered.
                  child: Text(
                    remaining < 1
                        ? '${_picked.length} SPD label'
                            '${_picked.length == 1 ? '' : 's'} will print. '
                            '${p.palletNo} will then hold nothing and is closed out.'
                        : '${_picked.length} SPD label'
                            '${_picked.length == 1 ? '' : 's'} will print. '
                            '$remaining stay on ${p.palletNo}'
                            '${standard > 0 && remaining < standard ? ', which becomes a HALF pallet and gets a new master sticker' : ''}.',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: (_busy || _picked.isEmpty) ? null : _convert,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.print_outlined, size: 18),
                  label: Text(
                    _busy
                        ? 'Converting…'
                        : _picked.isEmpty
                            ? 'Pick at least one wheel'
                            : 'Convert ${_picked.length} & print labels',
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _d(DateTime t) {
    final l = t.toLocal();
    return '${l.day.toString().padLeft(2, '0')}/'
        '${l.month.toString().padLeft(2, '0')}/${l.year}';
  }

  // -------------------------------------------------------------------------
  // Convert and print
  // -------------------------------------------------------------------------

  Future<void> _convert() async {
    final loaded = _loaded!;
    final ids = _picked.toList();

    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).convertToSpd(
          palletId: loaded.pallet.id,
          stickerIds: ids,
        );
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError || res.data == null) {
      // WHEEL_MOVED, WHEEL_VOIDED, PALLET_CONSUMED and the rest each name a
      // different remedy, and the server words them precisely.
      DplSnacks.error(context, res.error ?? 'Failed to convert those wheels.');
      return;
    }

    final out = res.data!;
    DplSnacks.success(
      context,
      '${out.packs.length} SPD pack${out.packs.length == 1 ? '' : 's'} created'
      '${out.sourceConsumed ? '. ${out.source.palletNo} is now empty.' : '. ${out.source.palletNo} holds ${out.source.qty}.'}',
    );

    // Packs first — they are what the operator is holding and about to box.
    await _printPacks(out.packs);
    if (!mounted) return;

    // Then the pallet's new master sticker, if it still exists. Its count
    // changed, so the old one is now wrong (§5).
    if (out.reprintSource != null) {
      await _printPalletLabel(out.reprintSource!);
    }
    if (!mounted) return;

    ref.invalidate(spdPacksProvider);
    _clear();
  }

  Future<void> _printPacks(List<DplSpdPack> packs) async {
    if (packs.isEmpty) return;
    setState(() => _busy = true);
    try {
      await Printing.layoutPdf(
        name: 'SPD-${packs.first.packNo}',
        // Both the page box AND the layout format must be the die-cut, with
        // dynamicLayout off. Left on, picking A4 in the print dialog silently
        // rescales a 50 x 25 mm label and the QR stops scanning.
        format: SpdLabelPdf.rollFormat,
        dynamicLayout: false,
        onLayout: (PdfPageFormat _) => SpdLabelPdf.buildRoll(packs),
      );
    } catch (_) {
      if (mounted) {
        DplSnacks.error(
          context,
          'The packs were created but the print sheet failed to open. '
          'Reprint them from the SPD list rather than converting again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _printPalletLabel(int palletId) async {
    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).getPalletLabel(palletId);
    if (!mounted) return;

    if (res.isError || res.data == null) {
      setState(() => _busy = false);
      final code = res.code;
      DplSnacks.error(
        context,
        '${res.error ?? 'Could not load the pallet label.'}'
        '${code == null || code.isEmpty ? '' : ' ($code)'} — the conversion '
        'DID happen; reprint the pallet from Pallets built.',
      );
      return;
    }

    try {
      await Printing.layoutPdf(
        name: 'Pallet-${res.data!.palletNo}',
        format: PalletLabelPdf.pageFormat,
        dynamicLayout: false,
        onLayout: (PdfPageFormat _) => PalletLabelPdf.build(res.data!),
      );
    } catch (_) {
      if (mounted) {
        DplSnacks.error(
          context,
          'The conversion is saved, but the pallet label failed to print. '
          'Reprint it from Pallets built.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // -------------------------------------------------------------------------
  // The register
  // -------------------------------------------------------------------------

  Widget _registerCard() {
    final async = ref.watch(spdPacksProvider);

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'SPD packs',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh',
                onPressed: () => ref.invalidate(spdPacksProvider),
              ),
            ],
          ),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(minHeight: 2),
            ),
            error: (e, _) => DplInlineErrorRetry(
              message: e.toString(),
              onRetry: () => ref.invalidate(spdPacksProvider),
            ),
            data: (res) {
              if (res.isError) {
                return DplInlineErrorRetry(
                  message: res.error ?? 'Failed to load SPD packs.',
                  onRetry: () => ref.invalidate(spdPacksProvider),
                );
              }
              final page = res.data ?? const DplSpdPage();
              if (page.packs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    'None yet. Scan a pallet above to take wheels for a '
                    'spare-parts order.',
                    style: TextStyle(fontSize: 12.5, color: Color(0xFF5D6A7A)),
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      page.total <= page.packs.length
                          ? '${page.total} pack${page.total == 1 ? '' : 's'}'
                          : 'Showing ${page.packs.length} of ${page.total}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF5D6A7A),
                      ),
                    ),
                  ),
                  for (final pack in page.packs)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        pack.packNo,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                      subtitle: Text(
                        [
                          if (pack.serialNo.isNotEmpty) pack.serialNo,
                          if (pack.customerPartNo.isNotEmpty) pack.customerPartNo,
                          if (pack.closedAt != null) _d(pack.closedAt!),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      trailing: TextButton.icon(
                        onPressed: _busy ? null : () => _printPacks([pack]),
                        icon: const Icon(Icons.print_outlined, size: 16),
                        label: const Text('Label'),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
