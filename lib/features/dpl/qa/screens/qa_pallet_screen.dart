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
import '../../models/dpl_spd.dart';
import '../../models/dpl_wheel_trolley.dart';
import '../../models/dpl_part.dart';
import '../services/pallet_label_pdf.dart';
import '../widgets/start_pallet_choice_sheet.dart';
import '../widgets/trolley_picker_sheet.dart';
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

// NO qaTrolleysProvider HERE, deliberately.
//
// There was one, and nothing ever watched it — the park path reads the carts
// directly because it needs them once, at the top of a run, not as reactive
// state, and the merge screen has its own qaTrolleyPlansProvider. An
// autoDispose provider that is never watched is never created, so the
// invalidate that used to follow a park rebuilt precisely nothing while
// reading as though it refreshed the list.

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

  /// The keyed-in way to START a pallet, for when the camera is not available.
  /// Separate from [_scanCtrl], which belongs to the open-pallet view.
  final _startCtrl = TextEditingController();

  bool _busy = false;

  /// The last few scans, newest first. Shown so an operator who looked away
  /// can see what actually landed without opening anything.
  final List<_ScanEvent> _recent = [];

  @override
  void dispose() {
    _scanCtrl.dispose();
    _startCtrl.dispose();
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
              Text(
                'Scan any wheel for the item you are packing. The pallet opens '
                'for that item and the wheel goes straight on.',
                style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _startPallet,
                  // Names what the press actually does now. "Start a pallet"
                  // with a camera behind it reads as a mis-tap.
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                  label: const Text('Scan a wheel to start'),
                ),
              ),
              const SizedBox(height: 12),
              // THE WAY IN WHEN THE CAMERA IS NOT.
              //
              // The button above is the only control this card used to have,
              // and it opens the camera and nothing else — DplQrScanSheet has
              // no manual entry, and its failure state offers only "Retry".
              // So a denied camera permission, a desktop browser, a ring
              // scanner that types instead of using the lens, or a lens too
              // scratched to read a scuffed label all left the operator unable
              // to start a pallet AT ALL, with no message saying why.
              //
              // The pallet's own scan field (see _scanCard) has always
              // accepted a keyed-in serial for exactly this reason. Starting
              // one had no equivalent until now.
              TextField(
                controller: _startCtrl,
                enabled: !_busy,
                // Focused on purpose, and it is what makes a handheld work
                // here. A rugged scanner delivers its decode to whichever
                // field has focus — by typing it in wedge mode, or through
                // HardwareScanScope in intent mode — so an unfocused start
                // view would mean the trigger did nothing at all on the one
                // screen where a shift begins. The open-pallet field below
                // autofocuses for the same reason.
                autofocus: true,
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  hintText: '…or type the wheel serial',
                  prefixIcon: Icon(Icons.keyboard_alt_outlined),
                  isDense: true,
                  helperText: 'A hardware scanner types into here. So can you, '
                      'when the label is too scuffed to read.',
                  helperMaxLines: 3,
                ),
                onSubmitted: _busy ? null : _startPalletTyped,
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
          Text(
            'Oldest first. Fill one of these before starting a fresh pallet.',
            style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
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
                return Text(
                  'None waiting. Nothing has been left part-filled.',
                  style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
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
                        style: TextStyle(
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
                              : DplColors.textSecondary,
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
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    if (pallet.machineName.isNotEmpty)
                      Text(
                        pallet.machineName,
                        style: TextStyle(
                          fontSize: 12,
                          color: DplColors.textSecondary,
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
                backgroundColor: DplColors.neutralBg,
                valueColor: AlwaysStoppedAnimation(
                  pallet.isFull ? DplColors.success : DplColors.primary,
                ),
              ),
            )
          else
            Text(
              'No standard pallet quantity is set for this item, so there is '
              'no target to count against and this will close as a HALF '
              'pallet. Ask a manager to set it under Masters > Packaging Qtys. '
              'Until then, close when the pallet is done.',
              style: TextStyle(
                fontSize: 12,
                // Not const: DplColors members are theme-aware getters now.
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
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          if (full) ...[
            const SizedBox(height: 6),
            Text(
              'All ${pallet.qty} are on. Close it above to print the pallet '
              'label — then start the next one.',
              style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
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
                  : ref
                          .watch(dplPermissionsProvider)
                          .can(DplPermission.labelsScanExternal)
                      // Say it out loud. An operator holding a roll of the old
                      // stickers has no way of knowing the app will take them,
                      // and will go looking for a printer instead.
                      ? 'Scans our labels and the plant\u2019s older ones. Each '
                          'old label is accepted once only.'
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

  /// Scan a wheel to choose the item a new pallet is for.
  ///
  /// Returns null when the operator backed out. Returns a resolution with no
  /// part when the label could not be tied to an item — the caller then falls
  /// back to the picker, and the reason is shown so the operator knows why
  /// they are being asked.
  /// Start a pallet from a serial that was typed, or sent by a hardware
  /// scanner, instead of read through the camera.
  Future<void> _startPalletTyped(String raw) async {
    final code = raw.trim();
    // Cleared FIRST, so the next label can be keyed in while this one is still
    // in flight and a refusal does not leave the old text to be re-submitted.
    _startCtrl.clear();
    if (code.isEmpty) return;
    await _startPallet(typed: code);
  }

  ///
  /// [typed] short-circuits the camera: the operator keyed the serial in, or a
  /// hardware scanner typed it. Everything after that is identical, so there
  /// is one place a label is turned into an item rather than two that drift.
  Future<DplWheelResolution?> _scanForItem({String? typed}) async {
    final perms = ref.read(dplPermissionsProvider);
    var code = typed == null || typed.trim().isEmpty ? null : typed.trim();
    if (code == null) {
      code = await DplQrScanSheet.open(
        context,
        expecting: 'Scan any wheel for this pallet',
        allowExternal: perms.can(DplPermission.labelsScanExternal),
      );
      if (code == null || !mounted) return null;
    }

    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).resolveWheel(code);
    if (!mounted) return null;
    setState(() => _busy = false);

    if (res.isError || res.data == null) {
      // STICKER_VOIDED, ALREADY_ON_ANOTHER_PALLET and EXTERNAL_NOT_ALLOWED all
      // name a situation the operator can act on, so they are shown verbatim.
      DplSnacks.error(context, res.error ?? 'Could not read that wheel label.');
      return null;
    }

    final found = res.data!;
    if (!found.hasPart) {
      DplSnacks.warning(
        context,
        found.reason.isEmpty
            ? 'That label does not name an item — choose it.'
            : found.reason,
      );
    }
    return found;
  }

  /// Open the camera, read one label, and feed it through the same path a
  /// hardware scan takes — so there is one place where a scan is accepted or
  /// refused, not two that can drift.
  Future<void> _scanWithCamera(DplPallet pallet) async {
    final code = await DplQrScanSheet.open(
      context,
      expecting: pallet.customerPartNo,
      // The camera has to accept whatever the keyboard path accepts, or the
      // two disagree about what a valid label is and the operator learns to
      // distrust one of them.
      allowExternal:
          ref.read(dplPermissionsProvider).can(DplPermission.labelsScanExternal),
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
                            ? DplColors.textPrimary
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
            style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
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

  /// Start a pallet.
  ///
  /// SCAN FIRST. The operator is holding a wheel whose label already names the
  /// item, so asking them to find it in a list of 128 is asking a question
  /// they have already answered — and a list is where the wrong item gets
  /// picked, which then mislabels every wheel that follows.
  ///
  /// The picker is still there as a fallback, because an old label whose item
  /// code is not in our master genuinely cannot be resolved, and guessing
  /// would be worse than asking.
  ///
  /// Once the item IS known, the operator is asked what the wheel is joining
  /// — a stored half pallet, a fresh pallet, or the trolley. That question is
  /// asked here, before anything is created, because after a pallet exists the
  /// only way out is a discard, and a discard that releases wheels is a worse
  /// thing to put in an operator's way than a question.
  ///
  /// [half] means the operator already answered it by pressing Fill on the
  /// stored list, so the sheet is skipped.
  Future<void> _startPallet({DplPallet? half, String? typed}) async {
    int? partId = half?.partId;
    int? machineId;

    // The wheel that chose the item. It goes onto the pallet straight after,
    // so the operator never scans the same label twice.
    String? seedCode;

    // Which stored half pallet to bring back. Starts as whatever Fill passed
    // and may be set by the choice sheet below.
    DplPallet? source = half;

    if (half == null) {
      final scanned = await _scanForItem(typed: typed);
      if (!mounted) return;
      if (scanned == null) return;

      partId = scanned.partId;
      machineId = scanned.machineId;
      seedCode = scanned.code;
      var partNo = scanned.customerPartNo;
      var partDesc = scanned.partDescription;

      // resolveWheel answers 0 rather than null when it cannot tell.
      if (partId <= 0) {
        // Could not tell from the label — fall back to the picker rather than
        // opening a pallet for a guess.
        final picked = await showDialog<_StartChoice>(
          context: context,
          builder: (_) => const _StartPalletDialog(),
        );
        if (picked == null || !mounted) return;
        partId = picked.partId;
        machineId = picked.machineId;
        partNo = picked.partNo;
        partDesc = picked.partDescription;
      }

      final decision = await StartPalletChoiceSheet.show(
        context,
        partId: partId,
        customerPartNo: partNo,
        partDescription: partDesc,
        parkedOnTrolleyNo: scanned.trolleyNo,
      );
      // Dismissed. Nothing has been written, and the wheel is still unpacked.
      if (decision == null || !mounted) return;

      switch (decision.kind) {
        case DplStartKind.trolley:
          await _parkOnTrolley(
            partId: partId,
            customerPartNo: partNo,
            code: seedCode,
          );
          return;
        case DplStartKind.productionMerge:
          source = decision.half;
          break;
        case DplStartKind.newPallet:
          break;
      }
    }
    if (partId == null || partId <= 0) return;

    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).openPallet(
          partId: partId,
          machineId: machineId,
          fromHalfPalletId: source?.id,
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

    // The wheel that chose the item goes straight on. Leaving it off would
    // mean scanning the same label twice — and an operator who has already
    // scanned it will reasonably assume it is on there.
    if (seedCode != null && seedCode.isNotEmpty) {
      final opened = res.data;
      if (opened != null && opened.id > 0) {
        await _scan(opened, seedCode);
        return;
      }
    }
    ref.invalidate(qaHalfPalletsProvider);
    _scanFocus.requestFocus();
  }

  /// Park the scanned wheel on a trolley instead of opening a pallet for it.
  ///
  /// Nothing is opened, so there is no pallet to close and no half pallet
  /// created — which is the entire point. The wheels wait on the cart until
  /// somebody merges them into stored half pallets, in whatever combination
  /// completes the most of them.
  ///
  /// The SAME wheel keeps being offered afterwards: an operator who parked one
  /// is almost always about to park the next off the same run, and sending
  /// them back through the three-way choice each time would make the feature
  /// slower than opening a pallet they did not want.
  Future<void> _parkOnTrolley({
    required int partId,
    required String customerPartNo,
    String? code,
  }) async {
    // Which cart, decided ONCE before the loop.
    //
    // With none the server creates the first; with one it uses it; those are
    // the cases that matter and neither asks. Only a plant running two lines
    // into two carts gets a question, and then only once per run rather than
    // once per wheel — the server would otherwise refuse every scan with
    // TROLLEY_NOT_CHOSEN and the operator would have no way forward.
    int? trolleyId;
    setState(() => _busy = true);
    final carts = await ref.read(dplApiServiceProvider).getTrolleys();
    if (!mounted) return;
    setState(() => _busy = false);

    // A FAILED LOOKUP IS NOT AN EMPTY PLANT.
    //
    // `carts.data` is null on a timeout or a 500, and treating that as "no
    // trolleys exist" would send trolleyId: null to a server that answers it
    // by CREATING one — so a dropped connection would mint a phantom cart,
    // and the wheel would land on it instead of on the one the operator is
    // standing next to.
    if (carts.isError) {
      DplSnacks.error(context, carts.error ?? 'Could not load the trolleys.');
      return;
    }

    final active = (carts.data ?? const <DplWheelTrolley>[])
        .where((t) => t.isActive)
        .toList(growable: false);
    if (active.length > 1) {
      final picked = await TrolleyPickerSheet.show(
        context,
        trolleys: active,
        prompt: 'Park $customerPartNo on which trolley?',
      );
      if (picked == null || !mounted) return;
      trolleyId = picked.id;
    }

    var next = code;
    var parked = 0;
    var refused = false;

    while (true) {
      if (next == null || next.isEmpty) {
        next = await DplQrScanSheet.open(
          context,
          expecting: customerPartNo,
          allowExternal: ref
              .read(dplPermissionsProvider)
              .can(DplPermission.labelsScanExternal),
        );
        if (!mounted) return;
        // Backed out. Whatever was parked stays parked — it is on the cart.
        if (next == null || next.isEmpty) break;
      }

      setState(() => _busy = true);
      final res = await ref.read(dplApiServiceProvider).parkWheelOnTrolley(
            trolleyId: trolleyId,
            code: next,
            // Only consulted for an old label nobody has scanned before, where
            // there is no pallet to take the item from.
            partId: partId,
          );
      if (!mounted) return;
      setState(() => _busy = false);

      if (res.isError) {
        // Shown exactly as the server worded it: ALREADY_ON_ANOTHER_PALLET,
        // ITEM_UNKNOWN and the rest each name a situation the operator can act
        // on, and rewording them into something vaguer helps nobody.
        _note(res.error ?? 'Refused', ok: false);
        HapticFeedback.heavyImpact();
        DplSnacks.error(context, res.error ?? 'That wheel was refused.');

        // ONE BAD WHEEL IS NOT THE END OF THE RUN.
        //
        // These refusals are about the wheel in the operator's hand and
        // nothing else: it is already on a cart, already packed, already
        // shipped, voided, or of the wrong item. The right answer is to put it
        // down and scan the next one — so the loop carries on, and only a
        // refusal about the TROLLEY or the request itself stops it, because
        // those would refuse every wheel that followed just the same.
        const perWheel = {
          'ALREADY_ON_THIS_TROLLEY',
          'ALREADY_ON_ANOTHER_TROLLEY',
          'ALREADY_ON_ANOTHER_PALLET',
          'ALREADY_ON_A_TRIP',
          'STICKER_VOIDED',
          'STICKER_NOT_FOUND',
          'WRONG_PART',
          'ITEM_UNKNOWN',
          'EMPTY_SCAN',
        };
        if (perWheel.contains(res.code)) {
          next = null;
          continue;
        }

        refused = true;
        break;
      }

      parked += 1;
      final out = res.data;
      _note(
        'Parked $next on ${out?.trolley.trolleyNo ?? 'the trolley'}',
        ok: true,
      );
      HapticFeedback.selectionClick();
      next = null;
    }

    if (!mounted || parked < 1) return;

    // NOT when the run ended in a refusal. DplSnacks hides the current bar
    // before showing the next, and nothing has been rebuilt since the red one
    // went up — so a success message here would wipe the explanation off the
    // screen before the operator could read a word of it, in the same frame.
    if (refused) return;

    DplSnacks.success(
      context,
      'Parked $parked wheel${parked == 1 ? '' : 's'} on the trolley. '
      'Merge them into half pallets from the Merge screen.',
    );
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
    // A FULL pallet is not asked about.
    //
    // The dialog is not a safety check — it is where the REASON for closing
    // short is collected, and it only shows that field when the pallet is
    // short. On a full pallet it therefore offered nothing but a sentence the
    // operator has already read off the counter (5 / 5, green) and off the
    // button itself, and the only possible answer was yes. On the busiest
    // screen in the system that is a tap per pallet, all shift, for nothing.
    //
    // Short still asks, because closing short at a changeover is exactly the
    // case a supervisor comes back and asks about, and the reason is only
    // capturable while the operator is standing in front of the pallet.
    String? reason = '';
    if (!pallet.isFull) {
      reason = await showDialog<String?>(
        context: context,
        builder: (_) => _ClosePalletDialog(pallet: pallet),
      );
      // The dialog returns null when cancelled and '' when closed with no
      // reason, so an empty string must not be treated as a cancel.
      if (reason == null || !mounted) return;
    }

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

  /// Carried so the choice sheet that follows can NAME the item. Without
  /// them it asks "where does this wheel go?" about nothing in particular,
  /// and the operator has no way to catch a mis-pick before a pallet's worth
  /// is packed under it.
  final String partNo;
  final String partDescription;

  const _StartChoice({
    required this.partId,
    this.machineId,
    this.partNo = '',
    this.partDescription = '',
  });
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
                    Icon(
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
                        style: TextStyle(
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
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            'No items match.',
                            style: TextStyle(
                              fontSize: 12,
                              color: DplColors.textSecondary,
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
                                style: TextStyle(
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
                                      style: TextStyle(fontSize: 11.5),
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
                    _StartChoice(
                      partId: _partId!,
                      machineId: _machineId,
                      partNo: selected?.partNumber ?? '',
                      partDescription: selected?.description ?? '',
                    ),
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
              style: TextStyle(fontSize: 13.5, height: 1.4),
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
