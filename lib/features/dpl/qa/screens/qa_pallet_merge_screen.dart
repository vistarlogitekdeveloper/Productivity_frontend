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
import '../widgets/wheel_transfer_board.dart';
import '../services/pallet_label_pdf.dart';
import 'dpl_qr_scan_sheet.dart';

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
    final canCamera =
        ref.watch(dplPermissionsProvider).can(DplPermission.palletScanCamera);
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
                  style: const TextStyle(
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
            autofocus: true,
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
        ],
      ),
    );
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
              color: isTarget ? DplColors.primary : const Color(0xFF6B7280),
              letterSpacing: 0.4,
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
            const Text(
              'Nothing has moved yet. Drag a wheel across, or use the arrow '
              'on a row.',
              style: TextStyle(fontSize: 12.5, color: Color(0xFF5D6A7A)),
            )
          else if (over)
            const Text(
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
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF5D6A7A),
              ),
            ),
            if (emptied.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '${emptied.join(' and ')} ends up empty and stops being a '
                'pallet.',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFD97706),
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
