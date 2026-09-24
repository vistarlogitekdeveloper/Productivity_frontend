import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_pallet.dart';
import '../../models/dpl_part.dart';
import '../services/pallet_label_pdf.dart';
import 'qa_putaway_screen.dart';
import 'dpl_qr_scan_sheet.dart';
import 'qa_direct_print_screen.dart' show qaDirectPartsProvider, qaDirectPartSearchProvider, qaMachinesProvider;

/// The pallet this operator has open, if any. At most one can exist.
final qaOpenPalletProvider =
    FutureProvider.autoDispose<DplApiResponse<DplPallet?>>((ref) async {
  return ref.watch(dplApiServiceProvider).getOpenPallet();
});

/// Stored half pallets, oldest first — SSR Module 5's order of suggestion.
final qaHalfPalletsProvider =
    FutureProvider.autoDispose<DplApiResponse<List<DplPallet>>>((ref) async {
  return ref.watch(dplApiServiceProvider).getHalfPallets();
});

/// Build a pallet: scan printed wheel labels onto it, then close it.
///
/// Maxion SSR v3.0 Module 4. SSR calls this "the busiest screen in the system",
/// so it is built for an operator who is not watching it: the field keeps
/// focus after every scan, the count is the biggest thing on screen, and
/// refusals are loud and specific rather than a generic red bar.
///
/// The operator never chooses the pallet type. SSR §4: "The app decides P, H
/// or PM by itself." Close says in plain words what it is about to do.
class QaPalletScreen extends ConsumerStatefulWidget {
  final bool showAppBar;

  const QaPalletScreen({super.key, this.showAppBar = true});

  @override
  ConsumerState<QaPalletScreen> createState() => _QaPalletScreenState();
}

class _QaPalletScreenState extends ConsumerState<QaPalletScreen> {
  final _scanCtrl = TextEditingController();
  final _scanFocus = FocusNode();
  bool _busy = false;

  /// The last few scans, newest first. Shown so an operator who looked away
  /// can see what actually landed without opening anything.
  final List<_ScanEvent> _recent = [];

  @override
  void dispose() {
    _scanCtrl.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  void _note(String text, {required bool ok}) {
    setState(() {
      _recent.insert(0, _ScanEvent(text: text, ok: ok));
      if (_recent.length > 8) _recent.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(qaOpenPalletProvider);

    final body = async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => DplInlineErrorRetry(
        message: e.toString(),
        onRetry: () => ref.invalidate(qaOpenPalletProvider),
      ),
      data: (res) {
        if (res.isError) {
          return DplInlineErrorRetry(
            message: res.error ?? 'Failed to read the open pallet.',
            onRetry: () => ref.invalidate(qaOpenPalletProvider),
          );
        }
        final pallet = res.data;
        return pallet == null ? _startView() : _buildView(pallet);
      },
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: AppBar(title: const Text('Pallet')),
      body: body,
    );
  }

  // -------------------------------------------------------------------------
  // No pallet open
  // -------------------------------------------------------------------------

  Widget _startView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
      children: [
        DplCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'No pallet open',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const SizedBox(height: 6),
              const Text(
                'Start one for the item you are packing, then scan each wheel '
                'label onto it.',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF5D6A7A)),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _startPallet,
                  icon: const Icon(Icons.add_box_outlined, size: 18),
                  label: const Text('Start a pallet'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _halfPalletCard(),
      ],
    );
  }

  /// Stored half pallets waiting to be topped up.
  ///
  /// SSR §4 names ageing half pallets as the problem the system exists to
  /// solve — "the part-filled pallet is set aside and forgotten" — so they are
  /// surfaced here rather than hidden behind a menu, with the age in days.
  Widget _halfPalletCard() {
    final async = ref.watch(qaHalfPalletsProvider);

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Stored half pallets',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: () => ref.invalidate(qaHalfPalletsProvider),
                tooltip: 'Refresh',
              ),
            ],
          ),
          const Text(
            'Oldest first. Fill one of these before starting a fresh pallet.',
            style: TextStyle(fontSize: 12, color: Color(0xFF5D6A7A)),
          ),
          const SizedBox(height: 10),
          async.when(
            loading: () => const LinearProgressIndicator(minHeight: 2),
            error: (e, _) => DplInlineErrorRetry(
              message: e.toString(),
              onRetry: () => ref.invalidate(qaHalfPalletsProvider),
            ),
            data: (res) {
              if (res.isError) {
                return DplInlineErrorRetry(
                  message: res.error ?? 'Failed to load half pallets.',
                  onRetry: () => ref.invalidate(qaHalfPalletsProvider),
                );
              }
              final rows = res.data ?? const <DplPallet>[];
              if (rows.isEmpty) {
                return const Text(
                  'None waiting. Nothing has been left part-filled.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF5D6A7A)),
                );
              }
              return Column(
                children: [
                  for (final p in rows.take(10))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${p.palletNo} · ${p.customerPartNo}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                      subtitle: Text(
                        '${p.qty}${p.hasTarget ? ' of ${p.standardQty}' : ''}'
                        '${p.ageDays != null ? ' · ${p.ageDays} days old' : ''}',
                        style: TextStyle(
                          fontSize: 11.5,
                          // Red once it has been sitting a week. SSR asks for
                          // old ones highlighted; a number alone gets skimmed.
                          color: (p.ageDays ?? 0) >= 7
                              ? DplColors.error
                              : const Color(0xFF6B7280),
                          fontWeight: (p.ageDays ?? 0) >= 7
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Reprint. A pallet label gets torn off by strapping
                          // or soaked in the yard often enough that without
                          // this the only recovery is to break the pallet down
                          // and rebuild it under a new number.
                          IconButton(
                            icon: const Icon(Icons.print_outlined, size: 18),
                            tooltip: 'Reprint pallet sticker',
                            onPressed:
                                _busy ? null : () => _printPalletLabel(p.id),
                          ),
                          TextButton(
                            onPressed:
                                _busy ? null : () => _startPallet(half: p),
                            child: const Text('Fill'),
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

  // -------------------------------------------------------------------------
  // Pallet open
  // -------------------------------------------------------------------------

  Widget _buildView(DplPallet pallet) {
    // ORDER CHANGES WHEN THE PALLET FILLS UP, and that is the point.
    //
    // While there is room, scanning is the job and Finish sits at the bottom
    // out of the way. The moment the pallet is full, closing it is the ONLY
    // thing left to do — so the button moves directly under the counter,
    // where the operator is already looking.
    //
    // Before this, Finish sat below "Last few scans", which grows with every
    // wheel. On a full pallet the operator saw a green 5 / 5, no button, and
    // a scan field that answered every further scan with "This pallet already
    // holds its full 5. Close it first." — an instruction pointing at a
    // control that was off the bottom of the screen.
    final full = pallet.isFull;

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
      children: [
        _countCard(pallet),
        const SizedBox(height: 12),
        if (full) ...[
          _closeCard(pallet),
          const SizedBox(height: 12),
          _scanCard(pallet),
        ] else ...[
          _scanCard(pallet),
          if (_recent.isNotEmpty) ...[
            const SizedBox(height: 12),
            _recentCard(),
          ],
          const SizedBox(height: 12),
          _closeCard(pallet),
        ],
        if (full && _recent.isNotEmpty) ...[
          const SizedBox(height: 12),
          _recentCard(),
        ],
      ],
    );
  }

  /// The count, as big as it can reasonably be. SSR Module 4 asks for "a large
  /// count such as 37 / 96" precisely because the operator glances rather than
  /// reads.
  Widget _countCard(DplPallet pallet) {
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pallet.customerPartNo.isEmpty
                          ? pallet.partDescription
                          : pallet.customerPartNo,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    if (pallet.machineName.isNotEmpty)
                      Text(
                        pallet.machineName,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF5D6A7A),
                        ),
                      ),
                  ],
                ),
              ),
              // The way out. Without it an operator who opened a pallet for the
              // wrong item is stuck with it — only one can be open at a time,
              // and closing would mint a real number and a real label for a
              // pallet that does not physically exist.
              TextButton.icon(
                onPressed: _busy ? null : () => _discard(pallet),
                icon: const Icon(Icons.close_rounded, size: 16),
                label: const Text('Discard'),
                style: TextButton.styleFrom(foregroundColor: DplColors.error),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              pallet.countLabel,
              style: TextStyle(
                fontSize: 46,
                fontWeight: FontWeight.w900,
                height: 1,
                color: pallet.isFull ? DplColors.success : DplColors.primary,
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (pallet.hasTarget)
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: pallet.progress,
                minHeight: 8,
                backgroundColor: const Color(0xFFEEF1F5),
                valueColor: AlwaysStoppedAnimation(
                  pallet.isFull ? DplColors.success : DplColors.primary,
                ),
              ),
            )
          else
            const Text(
              'No standard pallet quantity is set for this item, so there is '
              'no target to count against and this will close as a HALF '
              'pallet. Ask a manager to set it under Masters > Packaging Qtys. '
              'Until then, close when the pallet is done.',
              style: TextStyle(
                fontSize: 12,
                color: DplColors.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }

  Widget _scanCard(DplPallet pallet) {
    // A FULL pallet takes no more wheels, so the input is closed rather than
    // left open to refuse. The server says "This pallet already holds its full
    // 5. Close it first." on every scan, and a hardware scanner fires that
    // once per trigger pull — the operator ends up reading a wall of identical
    // red errors instead of the one instruction that matters. Shutting the
    // field says the same thing once, quietly, and points at the button.
    final full = pallet.isFull;

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            full ? 'Pallet full' : 'Scan a wheel label',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          if (full) ...[
            const SizedBox(height: 6),
            Text(
              'All ${pallet.qty} are on. Close it above to print the pallet '
              'label — then start the next one.',
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF5D6A7A)),
            ),
          ],
          const SizedBox(height: 10),
          TextField(
            controller: _scanCtrl,
            focusNode: _scanFocus,
            enabled: !_busy && !full,
            // Only grabs focus while it can actually take a wheel. Autofocus
            // on a disabled-in-spirit field steals the keyboard from the
            // close button on a tablet.
            autofocus: !full,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: full ? 'Nothing more fits on this pallet' : 'Scan, or type the serial',
              prefixIcon: const Icon(Icons.qr_code_scanner_rounded),
              isDense: true,
              helperText: full
                  ? 'Close this pallet before scanning the next wheel.'
                  : 'A hardware scanner types the code and presses enter. A '
                      'scuffed label can be keyed in by hand.',
              helperMaxLines: 3,
            ),
            // A hardware scanner ends with a newline, so this is the real
            // trigger; there is no Scan button to press between wheels.
            onSubmitted: (v) => _scan(pallet, v),
          ),
          // Camera scanning is a separate permission an administrator grants
          // per organization: a plant issuing ring scanners does not want
          // operators pointing a phone at a wheel.
          if (!full &&
              ref.watch(dplPermissionsProvider).can(DplPermission.palletScanCamera)) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _scanWithCamera(pallet),
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: const Text('Scan with the camera'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Open the camera, read one label, and feed it through the same path a
  /// hardware scan takes — so there is one place where a scan is accepted or
  /// refused, not two that can drift.
  Future<void> _scanWithCamera(DplPallet pallet) async {
    final code = await DplQrScanSheet.open(
      context,
      expecting: pallet.customerPartNo,
    );
    if (code == null || !mounted) return;
    await _scan(pallet, code);
  }

  Widget _recentCard() {
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Last few scans',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
          ),
          const SizedBox(height: 6),
          for (final e in _recent)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Icon(
                    e.ok ? Icons.check_circle : Icons.error_outline,
                    size: 15,
                    color: e.ok ? DplColors.success : DplColors.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      e.text,
                      style: TextStyle(
                        fontSize: 12,
                        color: e.ok
                            ? const Color(0xFF374151)
                            : DplColors.error,
                        fontWeight: e.ok ? FontWeight.w500 : FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _closeCard(DplPallet pallet) {
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Finish',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 6),
          // SSR Module 4: "Says in plain words what type it will be, then
          // prints the label."
          Text(
            pallet.closePreview,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF5D6A7A)),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_busy || pallet.qty < 1) ? null : () => _close(pallet),
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_outlined, size: 18),
              // Names BOTH halves of what the press does. SSR Module 4 ends
              // the pack point's job at "print the master pallet label and
              // stick it on the shroud", and an operator who does not expect
              // a print dialog dismisses it — leaving a numbered pallet on
              // the floor with nothing on it to scan.
              label: Text(
                pallet.qty < 1
                    ? 'Nothing packed yet'
                    : _busy
                        ? 'Closing…'
                        : 'Close pallet & print label',
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  Future<void> _startPallet({DplPallet? half}) async {
    int? partId = half?.partId;
    int? machineId;

    if (half == null) {
      final picked = await showDialog<_StartChoice>(
        context: context,
        builder: (_) => const _StartPalletDialog(),
      );
      if (picked == null || !mounted) return;
      partId = picked.partId;
      machineId = picked.machineId;
    }
    if (partId == null || partId <= 0) return;

    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).openPallet(
          partId: partId,
          machineId: machineId,
          fromHalfPalletId: half?.id,
        );
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError) {
      // PALLET_ALREADY_OPEN and the SOURCE_* refusals all name the situation.
      DplSnacks.error(context, res.error ?? 'Failed to open the pallet.');
      ref.invalidate(qaOpenPalletProvider);
      return;
    }

    setState(_recent.clear);
    if (half != null) {
      _note('Brought back ${half.palletNo} (${half.qty} wheels)', ok: true);
    }
    ref.invalidate(qaOpenPalletProvider);
    ref.invalidate(qaHalfPalletsProvider);
    _scanFocus.requestFocus();
  }

  Future<void> _scan(DplPallet pallet, String code) async {
    final value = code.trim();
    // Clear and re-focus FIRST, so the next wheel can be scanned while this
    // one is still in flight. An operator working at speed must never wait for
    // a round trip to be able to scan again.
    _scanCtrl.clear();
    _scanFocus.requestFocus();
    if (value.isEmpty) return;

    final res = await ref.read(dplApiServiceProvider).scanWheelOntoPallet(
          palletId: pallet.id,
          code: value,
        );
    if (!mounted) return;

    if (res.isError) {
      // Every refusal from the server names the physical situation — wrong
      // part, already on another pallet, pallet full — so it is shown
      // verbatim rather than being reworded into something vaguer.
      _note(res.error ?? 'Refused', ok: false);
      HapticFeedback.heavyImpact();
      DplSnacks.error(context, res.error ?? 'That wheel was refused.');
      return;
    }

    _note('Added $value', ok: true);
    HapticFeedback.selectionClick();
    ref.invalidate(qaOpenPalletProvider);
  }

  /// Abandon an open pallet and go back to the start view.
  ///
  /// Every wheel on it is released back to unpacked so it can be packed onto
  /// the right pallet; no number is issued, because a number that refers to
  /// nothing physical is worse than none.
  Future<void> _discard(DplPallet pallet) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this pallet?'),
        content: Text(
          // Says which of the two outcomes applies. A pallet opened by
          // bringing a half pallet back is NOT simply undone — the half
          // pallet is put together again with exactly the wheels it gave up,
          // and only the extras go to unpacked. Promising "they all go back to
          // unpacked" would be a lie, and the operator would reasonably expect
          // to have to rebuild the half pallet by hand.
          pallet.qty < 1
              ? 'Nothing has been packed on it, so nothing is lost.'
              : pallet.broughtBackQty > 0
                  ? 'The half pallet this was started from is put back '
                      'together with the ${pallet.broughtBackQty} wheel'
                      '${pallet.broughtBackQty == 1 ? '' : 's'} it gave up, and '
                      'goes back on the stored list. '
                      '${pallet.qty > pallet.broughtBackQty ? 'The other ${pallet.qty - pallet.broughtBackQty} go back to unpacked. ' : ''}'
                      'No pallet number is issued for this one.'
                  : 'The ${pallet.qty} wheel${pallet.qty == 1 ? '' : 's'} on it go '
                      'back to unpacked and can be scanned onto another pallet. '
                      'No pallet number is issued.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep packing'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DplColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).discardPallet(pallet.id);
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError) {
      DplSnacks.error(context, res.error ?? 'Failed to discard the pallet.');
      return;
    }
    setState(_recent.clear);
    ref.invalidate(qaOpenPalletProvider);
    ref.invalidate(qaHalfPalletsProvider);
    // Name the half pallet that came back. "Pallet discarded" alone leaves the
    // operator to guess whether the stock they brought back still exists.
    DplSnacks.success(
      context,
      pallet.broughtBackQty > 0
          ? 'Discarded. The half pallet is back on the stored list with '
              '${pallet.broughtBackQty} on it.'
          : 'Pallet discarded.',
    );
  }

  Future<void> _close(DplPallet pallet) async {
    final reason = await showDialog<String?>(
      context: context,
      builder: (_) => _ClosePalletDialog(pallet: pallet),
    );
    // The dialog returns null when cancelled and '' when closed with no
    // reason, so an empty string must not be treated as a cancel.
    if (reason == null || !mounted) return;

    setState(() => _busy = true);
    final res = await ref
        .read(dplApiServiceProvider)
        .closePallet(palletId: pallet.id, reason: reason);
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError) {
      DplSnacks.error(context, res.error ?? 'Failed to close the pallet.');
      return;
    }

    final closed = res.data;
    setState(_recent.clear);
    ref.invalidate(qaOpenPalletProvider);
    ref.invalidate(qaHalfPalletsProvider);

    if (closed != null) {
      DplSnacks.success(
        context,
        'Closed as ${closed.typeLabel.toUpperCase()} — ${closed.palletNo} '
        'with ${closed.qty} on it.',
      );
    }

    // The label follows the close automatically. SSR Module 4 ends the pack
    // point's job with "print the master pallet label and stick it on the
    // shroud" — a pallet that is closed in the system but bare on the floor
    // cannot be found again except by opening it, so the print is not a
    // separate button the operator can forget.
    //
    // pallet.id, not closed.id: the close response is the only thing that
    // could be malformed here, and the pallet we just closed is not in doubt.
    await _printPalletLabel(pallet.id);
    if (!mounted) return;

    // Then offer the rack, while the pallet is still in front of them.
    //
    // SSR Module 6 is a separate job done by a separate person at Maxion, so
    // this is an OFFER and not a step: at a plant where the pack operator also
    // racks the pallet it saves a walk back, and at one where a putaway
    // operator collects it later, declining costs nothing. Only shown when the
    // administrator has actually granted putaway to this plant.
    final canPutAway =
        ref.read(dplPermissionsProvider).can(DplPermission.palletPutaway);
    final palletNo = closed?.palletNo ?? '';
    if (!canPutAway || palletNo.isEmpty) return;

    final goNow = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Put it on a rack?'),
        content: Text(
          '$palletNo is closed and labelled. Recording where it is stored now '
          'is what lets it be found again at dispatch.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Put it away'),
          ),
        ],
      ),
    );
    if (goNow != true || !mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        // Pre-filled, so they do not scan a label they are already holding.
        builder: (_) => QaPutawayScreen(initialCode: palletNo),
      ),
    );
  }

  /// Fetch and print the master pallet label.
  ///
  /// Two failure paths, told apart because the remedies differ: if the fetch
  /// fails the pallet is still closed and correct and a reprint will work; if
  /// the print sheet fails the operator needs to be told to reprint rather
  /// than assume the close did not take.
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
        '${code == null || code.isEmpty ? '' : ' ($code)'} — '
        'the pallet IS closed; reprint it from Pallets built.',
      );
      return;
    }

    final sticker = res.data!;
    try {
      await Printing.layoutPdf(
        name: 'Pallet-${sticker.palletNo}',
        // Both the page box AND the layout format must be the die-cut, with
        // dynamicLayout off. Left on, picking A4 in the print dialog silently
        // rescales the 100 x 75 mm label and the QR stops scanning.
        format: PalletLabelPdf.pageFormat,
        dynamicLayout: false,
        onLayout: (PdfPageFormat _) => PalletLabelPdf.build(sticker),
      );
    } catch (e) {
      if (mounted) {
        DplSnacks.error(
          context,
          'The pallet is closed as ${sticker.palletNo}, but the print sheet '
          'failed to open. Reprint it from the stored pallet list.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _ScanEvent {
  final String text;
  final bool ok;
  const _ScanEvent({required this.text, required this.ok});
}

class _StartChoice {
  final int partId;
  final int? machineId;
  const _StartChoice({required this.partId, this.machineId});
}

/// Pick the item, and optionally the work point.
class _StartPalletDialog extends ConsumerStatefulWidget {
  const _StartPalletDialog();

  @override
  ConsumerState<_StartPalletDialog> createState() => _StartPalletDialogState();
}

class _StartPalletDialogState extends ConsumerState<_StartPalletDialog> {
  int? _partId;
  int? _machineId;
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Search runs SERVER-side, not over the loaded page.
  ///
  /// `/qa/parts` returns at most 200 rows, and the Maxion master has 128 today
  /// but will grow. Filtering only what happens to have arrived would quietly
  /// stop finding items once it passes the cap — the worst kind of search,
  /// because it looks like it works.
  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) ref.read(qaDirectPartSearchProvider.notifier).set(v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final partsAsync = ref.watch(qaDirectPartsProvider);
    final parts = partsAsync.asData?.value.data ?? const <DplPart>[];
    final machines = ref.watch(qaMachinesProvider).asData?.value.data ?? const [];
    final selected =
        parts.where((p) => p.id == _partId).firstOrNull;

    return AlertDialog(
      title: const Text('Start a pallet'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A dropdown of 128 wheels is a scroll, not a picker. The operator
            // knows the item code off the traveller and wants to type three
            // characters of it.
            TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Item',
                hintText: 'Search item code or name',
                prefixIcon: Icon(Icons.search_rounded),
                isDense: true,
              ),
              onChanged: _onSearch,
            ),
            const SizedBox(height: 8),
            if (selected != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle,
                      size: 16,
                      color: DplColors.success,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        selected.partNumber.isEmpty
                            ? selected.description
                            : selected.partNumber,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: partsAsync.isLoading && parts.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: LinearProgressIndicator(minHeight: 2),
                    )
                  : parts.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            'No items match.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF5D6A7A),
                            ),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: parts.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final p = parts[i];
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              selected: p.id == _partId,
                              title: Text(
                                p.partNumber.isEmpty
                                    ? p.description
                                    : p.partNumber,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13.5,
                                ),
                              ),
                              subtitle: p.name.isEmpty
                                  ? null
                                  : Text(
                                      p.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11.5),
                                    ),
                              onTap: () => setState(() => _partId = p.id),
                            );
                          },
                        ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int?>(
              initialValue: _machineId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Work point (optional)',
                helperText: 'Recorded against the pallet.',
              ),
              items: [
                const DropdownMenuItem<int?>(value: null, child: Text('Not set')),
                ...machines.map(
                  (m) => DropdownMenuItem<int?>(
                    value: m.id,
                    child: Text(m.name.isEmpty ? m.code : m.name),
                  ),
                ),
              ],
              onChanged: (v) => setState(() => _machineId = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _partId == null
              ? null
              : () => Navigator.of(context).pop(
                    _StartChoice(partId: _partId!, machineId: _machineId),
                  ),
          child: const Text('Start'),
        ),
      ],
    );
  }
}

/// Confirms in plain words what the pallet is about to become.
class _ClosePalletDialog extends StatefulWidget {
  final DplPallet pallet;

  const _ClosePalletDialog({required this.pallet});

  @override
  State<_ClosePalletDialog> createState() => _ClosePalletDialogState();
}

class _ClosePalletDialogState extends State<_ClosePalletDialog> {
  final _reasonCtrl = TextEditingController();

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final short = !widget.pallet.isFull;

    return AlertDialog(
      title: const Text('Close this pallet?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.pallet.closePreview,
              style: const TextStyle(fontSize: 13.5, height: 1.4),
            ),
            if (short) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _reasonCtrl,
                decoration: const InputDecoration(
                  labelText: 'Reason (optional)',
                  hintText: 'Item changeover',
                  helperText:
                      'Closing short is normal at a changeover. The reason is '
                      'reported, not refused.',
                  helperMaxLines: 3,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep packing'),
        ),
        FilledButton(
          // Returns '' rather than null when there is no reason — null is the
          // cancel signal and must not also mean "closed without a reason".
          onPressed: () => Navigator.of(context).pop(_reasonCtrl.text.trim()),
          child: const Text('Close pallet'),
        ),
      ],
    );
  }
}
