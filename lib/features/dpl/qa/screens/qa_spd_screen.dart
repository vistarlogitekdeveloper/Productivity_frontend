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
import '../../core/widgets/dpl_scan_panel.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_spd.dart';
import '../services/pallet_label_pdf.dart';
import '../services/spd_label_pdf.dart';
import '../services/spd_master_sticker_pdf.dart';
import '../services/wheel_scan_match.dart';
import 'dpl_qr_scan_sheet.dart';

final spdPacksProvider =
    FutureProvider.autoDispose<DplApiResponse<DplSpdPage>>((ref) async {
  return ref.watch(dplApiServiceProvider).listSpdPacks();
});

/// "Also print the SPD master sticker", remembered for the session so an
/// operator packing an order does not have to switch it on for every pallet.
class SpdMasterStickerChoice extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool on) => state = on;
}

final spdMasterStickerProvider =
    NotifierProvider<SpdMasterStickerChoice, bool>(SpdMasterStickerChoice.new);

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

  /// Sticker ids of the wheels scanned for SPD, and the order they were
  /// scanned in (for the list on screen).
  final Set<int> _picked = <int>{};
  final List<int> _pickedOrder = <int>[];

  /// The wheel-label field, once a pallet is loaded.
  final _wheelCtrl = TextEditingController();
  final _wheelFocus = FocusNode();

  @override
  void dispose() {
    _scanCtrl.dispose();
    _scanFocus.dispose();
    _wheelCtrl.dispose();
    _wheelFocus.dispose();
    super.dispose();
  }

  Future<void> _scanWheelWithCamera(List<DplWheel> wheels) async {
    final code = await DplQrScanSheet.open(context, kind: DplScanKind.wheel);
    if (code == null || !mounted) return;
    _pickScanned(code, wheels);
  }

  /// One scan adds that wheel to the SPD order.
  void _pickScanned(String raw, List<DplWheel> wheels) {
    _wheelCtrl.clear();
    final code = raw.trim();
    if (code.isEmpty) return;

    final wheel = matchScannedWheel(code, wheels);
    if (wheel == null) {
      DplSnacks.error(
        context,
        'That label is not on ${_loaded?.pallet.palletNo ?? 'this pallet'}. '
        'Scan a wheel from this pallet.',
      );
    } else if (_picked.contains(wheel.id)) {
      // A repeat trigger, not a second wheel.
      DplSnacks.warning(context, '${wheel.serialNo} is already scanned.');
    } else {
      setState(() {
        _picked.add(wheel.id);
        _pickedOrder.add(wheel.id);
      });
    }
    _wheelFocus.requestFocus();
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
    final loaded = _loaded;

    // Once a pallet is in, the scan panel becomes the pallet it scanned: one
    // card that says what is being taken from, with the way back out.
    if (loaded != null) {
      final p = loaded.pallet;
      return DplCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'TAKING FROM',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                      color: DplColors.primary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _busy ? null : _clear,
                  child: const Text('Start over'),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    p.palletNo,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                  ),
                ),
                Text(
                  p.countLabel,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              [
                '${p.customerPartNo}'
                    '${p.partDescription.isEmpty ? '' : ' · ${p.partDescription}'}',
                if (p.locationCode.isNotEmpty) 'On ${p.locationCode}',
              ].join('\n'),
              style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
            ),
          ],
        ),
      );
    }

    return DplScanPanel(
      step: 'Step 1 of 2',
      title: 'Take wheels for a spare-parts order',
      subtitle: 'Scan the pallet the wheels are coming off. Next you scan each '
          'wheel that is leaving, and each one becomes its own pack.',
      cameraLabel: 'Scan pallet sticker',
      onCamera: canCamera ? _scanWithCamera : null,
      controller: _scanCtrl,
      focusNode: _scanFocus,
      hint: 'or type the pallet number',
      onSubmitted: _resolve,
      busy: _busy,
    );
  }

  void _clear() {
    setState(() {
      _loaded = null;
      _picked.clear();
      _pickedOrder.clear();
      _scanCtrl.clear();
      _wheelCtrl.clear();
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
      _pickedOrder.clear();
      _scanCtrl.clear();
    });
    // The next thing scanned is a wheel off this pallet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _wheelFocus.requestFocus();
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
    final canCamera =
        ref.watch(dplPermissionsProvider).can(DplPermission.palletScanCamera);
    final allScanned = _picked.length >= wheels.length;

    return Column(
      children: [
        if (!allScanned)
          DplScanPanel(
            step: 'Step 2 of 2',
            // Scanned, not ticked: a wheel joins the order only when its own
            // label is read, so the list is what is physically in the
            // operator's hands rather than rows chosen on a screen.
            title: 'Scan the wheels going to SPD',
            subtitle: 'Take each wheel off ${p.palletNo} and scan its label. '
                '${_picked.length} of ${wheels.length} scanned.',
            cameraLabel: 'Scan wheel label',
            onCamera: canCamera ? () => _scanWheelWithCamera(wheels) : null,
            controller: _wheelCtrl,
            focusNode: _wheelFocus,
            hint: 'or type the wheel serial',
            onSubmitted: (v) => _pickScanned(v, wheels),
            busy: _busy,
            capitalize: false,
          ),
        const SizedBox(height: 12),
        DplCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Scanned (${_picked.length})',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
              if (_picked.isEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Nothing yet. Each wheel you scan appears here.',
                  style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
                ),
              ],
              const SizedBox(height: 4),
              // Newest first, so the wheel just scanned is the row in view.
              for (final w in _pickedOrder.reversed
                  .map((id) => wheels.where((x) => x.id == id).firstOrNull)
                  .whereType<DplWheel>())
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.check_circle_rounded,
                      color: DplColors.success, size: 20),
                  title: Text(
                    w.serialNo,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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
                  // A wrong scan is put right by removing it, not by starting
                  // the whole pallet again.
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _picked.remove(w.id);
                              _pickedOrder.remove(w.id);
                            }),
                  ),
                ),
              if (_picked.isNotEmpty) ...[
                const SizedBox(height: 8),
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
              ],
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: ref.watch(spdMasterStickerProvider),
                onChanged: _busy
                    ? null
                    : (on) => ref.read(spdMasterStickerProvider.notifier).set(on),
                title: const Text(
                  'Also print the SPD master sticker',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                ),
                subtitle: Text(
                  _picked.length > 1
                      ? 'One sticker for the box, listing all '
                          '${_picked.length} packs — 100 × 75 mm, the pallet '
                          'label stock.'
                      : 'One sticker for the box, listing its packs — '
                          '100 × 75 mm, the pallet label stock.',
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
              const SizedBox(height: 8),
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
                            ? 'Scan at least one wheel'
                            : 'Convert ${_picked.length} & print labels',
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
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

    // Then the box sticker listing every pack, when asked for. A separate
    // print because it is a different stock (100 x 75 mm, not 50 x 25 mm).
    if (ref.read(spdMasterStickerProvider)) {
      await _printMasterStickers(out.packs);
      if (!mounted) return;
    }

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

  Future<void> _printMasterStickers(List<DplSpdPack> packs) async {
    if (packs.isEmpty) return;
    setState(() => _busy = true);
    try {
      await Printing.layoutPdf(
        name: 'SPD-master-${packs.first.packNo}',
        // Die-cut page box with dynamicLayout off, so picking A4 in the
        // print dialog cannot silently rescale the sticker.
        format: SpdMasterStickerPdf.rollFormat,
        dynamicLayout: false,
        onLayout: (PdfPageFormat _) => SpdMasterStickerPdf.buildRoll(packs),
      );
    } catch (_) {
      if (mounted) {
        DplSnacks.error(
          context,
          'The packs were created but the master sticker failed to print. '
          'Reprint it from the SPD list.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The master sticker lists every pack of the conversion, so a reprint
  /// fetches the whole batch rather than trusting whatever page of the
  /// register happens to be loaded.
  Future<void> _reprintMaster(DplSpdPack pack) async {
    setState(() => _busy = true);
    final res = await ref
        .read(dplApiServiceProvider)
        .listSpdPacks(batch: pack.batchNo, limit: 200);
    if (!mounted) return;
    setState(() => _busy = false);

    final batch = res.data?.packs ?? const <DplSpdPack>[];
    if (res.isError) {
      DplSnacks.error(context, res.error ?? 'Could not load the packs of this box.');
      return;
    }
    // A server that predates batches ignores the filter and answers with
    // the whole register; keep only this batch, and never print nothing.
    final mine = batch.where((p) => p.batchNo == pack.batchNo).toList();
    await _printMasterStickers(mine.isEmpty ? [pack] : mine);
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
                return Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    'None yet. Scan a pallet above to take wheels for a '
                    'spare-parts order.',
                    style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
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
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: DplColors.textSecondary,
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
                      // Text only, and tight: on a phone two icon buttons
                      // left the pack number a third of the row.
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final (label, onTap) in [
                            ('Label', () => _printPacks([pack])),
                            ('Master', () => _reprintMaster(pack)),
                          ])
                            TextButton(
                              onPressed: _busy ? null : onTap,
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: const Size(44, 40),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(label),
                            ),
                        ],
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
