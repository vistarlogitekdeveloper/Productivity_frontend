import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_pallet.dart';
import '../../models/dpl_spd.dart';
import '../../models/dpl_wheel_trolley.dart';
import '../widgets/wheel_transfer_board.dart';
import '../services/pallet_label_pdf.dart';
import 'dpl_qr_scan_sheet.dart';
import 'qa_trolley_merge_screen.dart';

/// What every active trolley could fill right now, one plan per cart.
///
/// Fetched together rather than per-cart on demand, because the merge screen
/// opens on this and a plant has a handful of carts, not hundreds. Each plan
/// is read-only on the server: it takes no lock and writes nothing, so leaving
/// this screen open cannot hold up the floor.
///
/// A cart whose plan fails is DROPPED rather than surfaced as an error. The
/// suggestion is an extra; a merge screen that refuses to load because one
/// trolley misbehaved would stop the work it exists to help with.
final qaTrolleyPlansProvider =
    FutureProvider.autoDispose<List<DplTrolleyPlan>>((ref) async {
  final api = ref.watch(dplApiServiceProvider);

  if (!ref.watch(dplPermissionsProvider).can(DplPermission.palletTrolley)) {
    return const <DplTrolleyPlan>[];
  }

  final carts = await api.getTrolleys();
  if (carts.isError) return const <DplTrolleyPlan>[];

  final plans = <DplTrolleyPlan>[];
  for (final t in carts.data ?? const <DplWheelTrolley>[]) {
    if (!t.isActive || t.isEmpty) continue;
    final plan = await api.getTrolleyPlan(t.id);
    if (plan.isError || plan.data == null) continue;
    plans.add(plan.data!);
  }
  return plans;
});

/// Combining two part-filled pallets — SSR Module 5.
///
/// Scan one pallet, scan another, and the app fills the first to its standard
/// quantity from the second. Four wheels and three, against a standard of five,
/// come out as a FULL pallet of five and a half pallet of two — which is what
/// physically happens on the floor, because six wheels do not fit on a shroud
/// built for five.
///
/// The existing "combine" operation empties the source whatever the size. That
/// is right while two halves fit inside one standard quantity and wrong the
/// moment they do not, so this is a separate operation rather than a change to
/// that one.
///
/// BOTH LABELS ARE REPRINTED. §5: the pallet QR "is reprinted when the pallet
/// changes, for example on a merge", and here both pallets changed. The server
/// decides which — when the source is emptied it stops being a pallet, and a
/// label for something that no longer exists is worse than no label.
class QaPalletMergeScreen extends ConsumerStatefulWidget {
  const QaPalletMergeScreen({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  ConsumerState<QaPalletMergeScreen> createState() =>
      _QaPalletMergeScreenState();
}

class _QaPalletMergeScreenState extends ConsumerState<QaPalletMergeScreen> {
  final _scanCtrl = TextEditingController();
  final _scanFocus = FocusNode();

  bool _busy = false;

  /// The pallets, in the order they were scanned. Neither is "the target" any
  /// more — the operator decides which wheels go where, in either direction.
  DplPallet? _target;
  DplPallet? _source;

  /// What is physically on each, loaded once both are scanned.
  DplPalletWheels? _leftWheels;
  DplPalletWheels? _rightWheels;

  /// sticker id -> the pallet it is currently assigned to. Starts as where the
  /// wheels actually are and diverges as the operator drags; the diff against
  /// [_origin] is what gets sent.
  final Map<int, int> _assignment = <int, int>{};
  final Map<int, int> _origin = <int, int>{};

  /// Only the wheels that actually changed side. Sending the whole assignment
  /// would make the server write every row for a single drag.
  Map<int, int> get _moves {
    final out = <int, int>{};
    for (final e in _assignment.entries) {
      if (_origin[e.key] != e.value) out[e.key] = e.value;
    }
    return out;
  }

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
        // The suggestion, offered BEFORE anything is scanned.
        //
        // This is the whole point of parking wheels loose: at some point
        // somebody starts a merging session, and the question is which half
        // pallets these wheels should go into. Answering it by hand means
        // reading a rack of half pallets and doing arithmetic; the plan does
        // it, and prefers the combination that COMPLETES the most pallets
        // rather than the one that empties the cart fastest.
        if (_target == null) ...[
          const SizedBox(height: 12),
          _trolleyPlanCard(),
        ],
        // Only shown while the second pallet is still being scanned. Once the
        // board is up it repeats the board's own headers, and its old labels
        // ("filling" / "taking from") contradict a screen where direction is
        // the operator's to choose.
        if (_target != null && _source == null) ...[
          const SizedBox(height: 12),
          _palletCard(_target!, 'First pallet', isTarget: true),
        ],
        if (_leftWheels != null && _rightWheels != null) ...[
          const SizedBox(height: 12),
          WheelTransferBoard(
            left: _leftWheels!,
            right: _rightWheels!,
            assignment: _assignment,
            enabled: !_busy,
            onMove: (stickerId, toPalletId) =>
                setState(() => _assignment[stickerId] = toPalletId),
          ),
          const SizedBox(height: 12),
          _commitCard(),
        ],
      ],
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: AppBar(title: const Text('Merge pallets')),
      body: body,
    );
  }

  // -------------------------------------------------------------------------
  // Scanning
  // -------------------------------------------------------------------------

  String get _prompt {
    if (_target == null) return 'Scan the pallet you want to FILL';
    if (_source == null) return 'Now scan the pallet to take wheels FROM';
    return 'Both scanned';
  }

  Widget _scanCard() {
    final perms = ref.watch(dplPermissionsProvider);
    final canCamera = perms.can(DplPermission.palletScanCamera);
    final canTrolley = perms.can(DplPermission.palletTrolley);
    final done = _target != null && _source != null;

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _prompt,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              if (_target != null)
                TextButton(
                  onPressed: _busy ? null : _startOver,
                  child: const Text('Start over'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _scanCtrl,
            focusNode: _scanFocus,
            enabled: !_busy && !done,
            // NOT autofocused: the handheld delivers here by position, and a
            // soft keyboard on entry hides the suggestion list this screen
            // opens on.
            textInputAction: TextInputAction.done,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              hintText: done
                  ? 'Both pallets scanned'
                  : 'Scan, or type the pallet number',
              prefixIcon: const Icon(Icons.qr_code_scanner_rounded),
              isDense: true,
              helperText: done
                  ? null
                  : 'The number is printed under the code, so a damaged label '
                      'can be keyed in by hand.',
              helperMaxLines: 3,
            ),
            onSubmitted: _busy ? null : _resolve,
          ),
          if (canCamera && !done) ...[
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

          // The OTHER way to fill the pallet that has just been scanned.
          //
          // Offered only at the SECOND scan — with a target in hand and no
          // source yet — because that is the one moment the question "where
          // are these wheels coming from?" is open. The camera button above is
          // shown at the first scan too, so `!done` alone would put this in
          // front of an operator who has not yet said what they are filling.
          if (canTrolley && _target != null && _source == null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _fillFromTrolley,
                icon: const Icon(Icons.shopping_cart_outlined, size: 18),
                label: const Text('Or fill it from a trolley'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// What the trolleys could fill right now.
  ///
  /// Only rendered when the plant has the trolley at all, and quietly absent
  /// when no cart holds anything — a permanent empty card on the busiest merge
  /// screen would be noise, and the operator would learn to skip past it.
  Widget _trolleyPlanCard() {
    if (!ref.watch(dplPermissionsProvider).can(DplPermission.palletTrolley)) {
      return const SizedBox.shrink();
    }

    final async = ref.watch(qaTrolleyPlansProvider);
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (plans) {
        final withWork = plans.where((p) => p.hasWork).toList();
        if (withWork.isEmpty) return const SizedBox.shrink();

        return DplCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.shopping_cart_outlined,
                    size: 18,
                    color: DplColors.primary,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Suggested from the trolleys',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: 'Refresh',
                    onPressed: () => ref.invalidate(qaTrolleyPlansProvider),
                  ),
                ],
              ),
              Text(
                // Says what it is optimising for. A suggestion an operator
                // cannot second-guess is one they either follow blindly or
                // ignore, and both are worse than understanding it.
                'Chosen to COMPLETE as many half pallets as possible. Where '
                'two plans complete the same number, the older pallets win.',
                style: TextStyle(fontSize: 11.5, color: DplColors.textSecondary),
              ),
              const SizedBox(height: 10),
              for (final plan in withWork) ..._planRows(plan),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _planRows(DplTrolleyPlan plan) {
    return [
      Text(
        '${plan.trolley.label} · ${plan.trolley.wheelQty} on it',
        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      ),
      const SizedBox(height: 4),
      for (final item in plan.items.where((i) => i.hasWork)) ...[
        for (final step in item.steps)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${step.palletNo} · take ${step.take}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
              ),
            ),
            subtitle: Text(
              '${item.customerPartNo} · ${step.qty} of ${step.standardQty ?? '?'} '
              'on it · ${step.ageDays} days old → becomes FULL',
              style: TextStyle(
                fontSize: 11.5,
                color: step.isOld ? DplColors.error : DplColors.textSecondary,
                fontWeight: step.isOld ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            // Jumps straight into the fill for that pallet. The plan is a
            // suggestion, so this is a shortcut to the screen where the
            // operator still scans each wheel — not a one-tap commit.
            onTap: _busy ? null : () => _fillFromPlan(step),
          ),
        if (item.leftover > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '${item.leftover} ${item.customerPartNo} stay on the trolley — '
              'not enough to complete anything else.',
              style: TextStyle(fontSize: 11, color: DplColors.textSecondary),
            ),
          ),
        // The one it could NOT help is named. Silence about a 45-day-old half
        // pallet reads as "the system has not noticed it".
        for (final skip in item.ignored.where((s) => s.isOld))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '${skip.palletNo} has been standing ${skip.ageDays} days and '
              '${skip.why}.',
              style: TextStyle(
                fontSize: 11,
                color: DplColors.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    ];
  }

  /// Open the fill screen for a pallet the plan suggested.
  ///
  /// Resolves the pallet first rather than trusting the plan's snapshot: it
  /// may be seconds old, and the fill screen needs the pallet's real count to
  /// work out how much room is left.
  Future<void> _fillFromPlan(DplTrolleyPlanStep step) async {
    setState(() => _busy = true);
    final res = await ref
        .read(dplApiServiceProvider)
        .resolvePalletForPutaway(step.palletNo);
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError || res.data == null) {
      DplSnacks.error(context, res.error ?? 'Could not find ${step.palletNo}.');
      ref.invalidate(qaTrolleyPlansProvider);
      return;
    }

    setState(() => _target = res.data!.pallet);
    await _fillFromTrolley();
    if (!mounted) return;
    ref.invalidate(qaTrolleyPlansProvider);
  }

  void _startOver() {
    setState(() {
      _target = null;
      _source = null;
      _leftWheels = null;
      _rightWheels = null;
      _assignment.clear();
      _origin.clear();
      _scanCtrl.clear();
    });
    _scanFocus.requestFocus();
  }

  /// Load what is on both pallets and seed the board.
  ///
  /// Runs once both are scanned, because a board with one column is not a
  /// board — and because the wheel lists are the expensive part of this screen
  /// and fetching one that may be discarded is wasted.
  Future<void> _loadWheels() async {
    final a = _target;
    final b = _source;
    if (a == null || b == null) return;

    setState(() => _busy = true);
    final api = ref.read(dplApiServiceProvider);
    final left = await api.getPalletWheels(a.id);
    final right = await api.getPalletWheels(b.id);
    if (!mounted) return;
    setState(() => _busy = false);

    if (left.isError || left.data == null || right.isError || right.data == null) {
      DplSnacks.error(
        context,
        left.error ?? right.error ?? 'Failed to load the wheels.',
      );
      return;
    }

    setState(() {
      _leftWheels = left.data;
      _rightWheels = right.data;
      _assignment.clear();
      _origin.clear();
      for (final w in left.data!.sellable) {
        _assignment[w.id] = a.id;
        _origin[w.id] = a.id;
      }
      for (final w in right.data!.sellable) {
        _assignment[w.id] = b.id;
        _origin[w.id] = b.id;
      }
    });
  }

  Future<void> _scanWithCamera() async {
    final code = await DplQrScanSheet.open(context, kind: DplScanKind.pallet);
    if (code == null || !mounted) return;
    await _resolve(code);
  }

  /// Fill the scanned pallet from a trolley instead of from another pallet.
  ///
  /// A separate screen rather than a third column on the transfer board: the
  /// board's job is choosing WHICH of a visible set moves, and the operator
  /// chooses that here by physically picking a wheel up off a cart. Scanning
  /// is the gesture, so a scan-and-tally list is the right shape, and the
  /// board's copy ("Empty — this pallet stops existing", "a full pallet is
  /// N") is wrong for a cart in every particular.
  Future<void> _fillFromTrolley() async {
    final target = _target;
    if (target == null) return;

    final result = await Navigator.of(context).push<DplTrolleyMergeResult>(
      MaterialPageRoute(
        builder: (_) => QaTrolleyMergeScreen(target: target),
      ),
    );
    if (result == null || !mounted) return;

    DplSnacks.success(
      context,
      'Moved ${result.moved} onto ${result.pallet.palletNo}'
      '${result.isFull ? ' — it is a FULL pallet now' : ''}.'
      '${result.wasRenamed ? ' It was ${result.renamedFrom}.' : ''}',
    );

    // The count changed and the number may have, so the label on the shroud is
    // wrong on at least one count. Printed here rather than left as a button
    // the operator can forget — a pallet whose label disagrees with what is on
    // it is worse than one with no label at all.
    for (final id in result.reprint) {
      if (!mounted) return;
      await _printLabel(id);
    }
    if (!mounted) return;
    _startOver();
  }

  Future<void> _resolve(String raw) async {
    final code = raw.trim();
    if (code.isEmpty) return;

    setState(() => _busy = true);
    final res =
        await ref.read(dplApiServiceProvider).resolvePalletForPutaway(code);
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError || res.data == null) {
      DplSnacks.error(context, res.error ?? 'Could not read that pallet label.');
      _reFocus();
      return;
    }

    final found = res.data!;
    final pallet = found.pallet;

    // The label in their hand carries the old number. Say so, or the different
    // number on screen reads as the scanner misreading — and the next thing
    // they do is scan it again.
    if (found.wasRenamed) {
      DplSnacks.warning(
        context,
        '${found.renamedFrom} was merged and is now ${pallet.palletNo}. '
        'That label is out of date — reprint it.',
      );
    }

    // Caught here rather than by the server so the operator is told while the
    // scanner is still in their hand, and the second scan is not wasted.
    if (_target != null && pallet.id == _target!.id) {
      DplSnacks.warning(
        context,
        '${pallet.palletNo} is already the pallet being filled. Scan the other '
        'one.',
      );
      _reFocus();
      return;
    }
    if (_target != null && pallet.partId != _target!.partId) {
      DplSnacks.error(
        context,
        '${pallet.palletNo} holds a different item. Only pallets of the same '
        'item can be combined.',
      );
      _reFocus();
      return;
    }

    setState(() {
      if (_target == null) {
        _target = pallet;
      } else {
        _source = pallet;
      }
      _scanCtrl.clear();
    });
    _reFocus();

    // Both in hand: fetch what is on them so the board has something to show.
    if (_target != null && _source != null) await _loadWheels();
  }

  void _reFocus() {
    _scanCtrl.clear();
    if (_target == null || _source == null) _scanFocus.requestFocus();
  }

  // -------------------------------------------------------------------------
  // What was scanned
  // -------------------------------------------------------------------------

  Widget _palletCard(DplPallet p, String label, {required bool isTarget}) {
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: isTarget ? DplColors.primary : DplColors.textSecondary,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  p.palletNo,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                  ),
                ),
              ),
              Text(
                p.countLabel,
                style: TextStyle(
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
            style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
          ),
          if (p.locationCode.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'On ${p.locationCode}',
              style: TextStyle(fontSize: 11.5, color: DplColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Preview and commit
  // -------------------------------------------------------------------------

  /// What the press will do, in wheels, before it happens.
  ///
  /// Recomputed from the board rather than asked of the server: the operator
  /// is deciding whether to press at all, and a round trip per drag would make
  /// the board feel broken. The server re-derives all of it and is the
  /// authority; this is a promise, not a calculation anyone relies on.
  Widget _commitCard() {
    final moves = _moves;
    final a = _leftWheels!.pallet;
    final b = _rightWheels!.pallet;

    int countFor(int palletId) =>
        _assignment.values.where((v) => v == palletId).length;

    final aAfter = countFor(a.id);
    final bAfter = countFor(b.id);
    final aStd = a.standardQty ?? 0;
    final bStd = b.standardQty ?? 0;
    final over = (aStd > 0 && aAfter > aStd) || (bStd > 0 && bAfter > bStd);
    final emptied = [
      if (aAfter < 1) a.palletNo,
      if (bAfter < 1) b.palletNo,
    ];
    final labels = [a.palletNo, b.palletNo].length - emptied.length;

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'What this will do',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 8),
          if (moves.isEmpty)
            Text(
              'Nothing has moved yet. Drag a wheel across, or use the arrow '
              'on a row.',
              style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
            )
          else if (over)
            Text(
              'One pallet has more wheels than fit on it. Move some back '
              'before merging.',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: DplColors.error,
              ),
            )
          else ...[
            Text(
              '${moves.length} wheel${moves.length == 1 ? '' : 's'} move. '
              '$labels label${labels == 1 ? '' : 's'} will be printed.',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: DplColors.textSecondary,
              ),
            ),
            if (emptied.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '${emptied.join(' and ')} ends up empty and stops being a '
                'pallet.',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: DplColors.warning,
                ),
              ),
            ],
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_busy || moves.isEmpty || over) ? null : _merge,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.merge_rounded, size: 18),
              label: Text(_busy ? 'Merging…' : 'Merge & print labels'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _merge() async {
    final a = _leftWheels!.pallet;
    final b = _rightWheels!.pallet;
    final moves = _moves;
    if (moves.isEmpty) return;

    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).redistributeWheels(
          palletAId: a.id,
          palletBId: b.id,
          moves: moves,
        );
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError || res.data == null) {
      // OVER_CAPACITY, PART_MISMATCH, WHEEL_MOVED and the rest each name a
      // different remedy, and the server words them precisely.
      DplSnacks.error(context, res.error ?? 'Failed to move those wheels.');
      return;
    }

    final out = res.data!;
    DplSnacks.success(
      context,
      '${out.moved} wheel${out.moved == 1 ? '' : 's'} moved. '
      '${out.pallets.map((p) => '${p.palletNo} ${p.qty}').join(', ')}',
    );

    // Print whatever the server said is stale, in order. Sequential rather
    // than parallel: two print dialogs racing each other is how an operator
    // ends up dismissing one without noticing.
    for (final id in out.reprint) {
      if (!mounted) return;
      await _printLabel(id);
    }

    if (!mounted) return;
    _startOver();
  }

  Future<void> _printLabel(int palletId) async {
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
        'the merge DID happen; reprint from Pallets built.',
      );
      return;
    }

    final sticker = res.data!;
    try {
      await Printing.layoutPdf(
        name: 'Pallet-${sticker.palletNo}',
        format: PalletLabelPdf.pageFormat,
        dynamicLayout: false,
        onLayout: (PdfPageFormat _) => PalletLabelPdf.build(sticker),
      );
    } catch (_) {
      if (mounted) {
        DplSnacks.error(
          context,
          'The merge is saved, but the print sheet for ${sticker.palletNo} '
          'failed to open. Reprint it from Pallets built.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
