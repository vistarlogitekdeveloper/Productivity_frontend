import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_scan_panel.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_pallet.dart';
import '../../models/dpl_spd.dart';
import '../../models/dpl_wheel_trolley.dart';
import '../services/pallet_label_pdf.dart';
import '../services/wheel_scan_match.dart';
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

/// Combining two part-filled pallets — SSR Module 5 — BY SCANNING.
///
///   1. Scan both pallet stickers.
///   2. Choose which pallet to merge INTO.
///   3. Scan wheel labels off the other pallet, one at a time. Every scan
///      moves that wheel onto the chosen pallet there and then.
///   4. Finish: the labels of whatever changed are printed.
///
/// Scanning is the gesture because it is the physical act: the operator lifts
/// a wheel off one pallet and puts it on the other, and the scan is the record
/// that THAT wheel moved. An earlier version showed both pallets' wheel lists
/// and moved rows by dragging, which records a decision made on a screen, not
/// what was carried — the list said a wheel moved whether or not anyone
/// picked it up.
///
/// Each scan is its own server move (`/qa/pallets/redistribute` with one
/// wheel), so a scan that is refused — wrong pallet, pallet full — changes
/// nothing, and an operator called away mid-merge leaves both pallets
/// correct, just not finished.
///
/// LABELS ARE PRINTED AT THE END, not per scan. Both pallets' counts (and the
/// filled pallet's number, renumbered as merged) change with every wheel, so
/// a label per scan would be a stack of stale labels. The server says which
/// pallets still exist to be labelled: a pallet that gave every wheel away
/// stops being a pallet and gets none.
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

  /// Step 3's field: wheel labels, not pallet stickers. A separate field so a
  /// pallet sticker scanned by mistake at this point is read as a wheel and
  /// refused, instead of restarting the pallet scan.
  final _wheelCtrl = TextEditingController();
  final _wheelFocus = FocusNode();

  bool _busy = false;

  /// The two pallets, in the order they were scanned. Kept current: every
  /// move replaces them with the server's answer, because a merge renumbers
  /// the pallet being filled.
  DplPallet? _first;
  DplPallet? _second;

  /// Which of the two the operator chose to merge INTO. Null until chosen.
  int? _targetId;

  /// What is on each pallet right now, keyed by pallet id. Loaded once both
  /// are scanned and updated locally after every successful move.
  final Map<int, List<DplWheel>> _wheels = <int, List<DplWheel>>{};

  /// The wheels moved in this session, newest first, for the on-screen tally.
  final List<String> _moved = <String>[];

  /// The pallets the LAST move said need a label. Every move changes both
  /// pallets, so the last answer is the current one.
  List<int> _reprint = const <int>[];

  /// Scans are applied one at a time, in order. A handheld trigger fires
  /// faster than a round trip, and two moves in flight would each be decided
  /// against counts the other is about to change.
  Future<void> _scanChain = Future<void>.value();

  DplPallet? get _target => _targetId == null
      ? null
      : (_first?.id == _targetId ? _first : _second);

  DplPallet? get _source => _targetId == null
      ? null
      : (_first?.id == _targetId ? _second : _first);

  int _countOn(DplPallet? p) =>
      p == null ? 0 : (_wheels[p.id] ?? const <DplWheel>[]).length;

  bool get _targetFull {
    final t = _target;
    final std = t?.standardQty ?? 0;
    return t != null && std > 0 && _countOn(t) >= std;
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _scanFocus.dispose();
    _wheelCtrl.dispose();
    _wheelFocus.dispose();
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
        if (_first == null) ...[
          const SizedBox(height: 12),
          _trolleyPlanCard(),
        ],
        // Step 2: both scanned, wheels loaded, direction not yet chosen.
        if (_second != null && _targetId == null && _wheels.length == 2) ...[
          const SizedBox(height: 12),
          _chooseTargetCard(),
        ],
        // Step 3: scanning wheels across.
        if (_targetId != null) ...[
          const SizedBox(height: 12),
          _progressCard(),
          const SizedBox(height: 12),
          _wheelScanCard(),
          if (_moved.isNotEmpty) ...[
            const SizedBox(height: 12),
            _movedCard(),
          ],
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

  /// Step 1: the two pallet stickers.
  ///
  /// Once both are in, this shrinks to one line with "Start over": the cards
  /// below already show both pallets, and a scan panel that can no longer
  /// take a scan is just height pushing the next step off a phone screen.
  Widget _scanCard() {
    final perms = ref.watch(dplPermissionsProvider);
    final canCamera = perms.can(DplPermission.palletScanCamera);
    final canTrolley = perms.can(DplPermission.palletTrolley);

    if (_second != null) {
      return DplCard(
        child: Row(
          children: [
            Icon(Icons.check_circle_rounded, color: DplColors.success, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${_first!.palletNo} + ${_second!.palletNo}',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: _busy ? null : _startOver,
              child: const Text('Start over'),
            ),
          ],
        ),
      );
    }

    return DplScanPanel(
      step: 'Step 1 of 3',
      title: _first == null
          ? 'Scan the first pallet sticker'
          : 'Now scan the second pallet sticker',
      subtitle: _first == null
          ? 'Scan both pallets you want to combine. You choose which one to '
              'fill next.'
          : 'First: ${_first!.palletNo} (${_first!.countLabel}). Scan the '
              'other pallet of the same item.',
      cameraLabel: 'Scan pallet sticker',
      onCamera: canCamera ? _scanWithCamera : null,
      controller: _scanCtrl,
      focusNode: _scanFocus,
      hint: 'or type the pallet number',
      onSubmitted: _resolve,
      busy: _busy,
      trailing: _first == null
          ? null
          : TextButton(
              onPressed: _busy ? null : _startOver,
              child: const Text('Start over'),
            ),
      footer: [
        // The OTHER way to fill the pallet just scanned — offered only at the
        // second scan, the one moment "where are these wheels coming from?"
        // is open.
        if (canTrolley && _first != null)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _fillFromTrolley,
              icon: const Icon(Icons.shopping_cart_outlined, size: 18),
              label: const Text('Or fill it from a trolley'),
            ),
          ),
      ],
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

    setState(() => _first = res.data!.pallet);
    await _fillFromTrolley();
    if (!mounted) return;
    ref.invalidate(qaTrolleyPlansProvider);
  }

  void _startOver() {
    setState(() {
      _first = null;
      _second = null;
      _targetId = null;
      _wheels.clear();
      _moved.clear();
      _reprint = const <int>[];
      _scanCtrl.clear();
      _wheelCtrl.clear();
    });
    _scanFocus.requestFocus();
  }

  /// Load what is on both pallets.
  ///
  /// Runs once both are scanned: matching a scanned wheel label to a wheel on
  /// the source needs the list, and fetching one for a pallet that may be
  /// discarded at the second scan is wasted.
  Future<void> _loadWheels() async {
    final a = _first;
    final b = _second;
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
      _wheels
        ..clear()
        ..[a.id] = List<DplWheel>.of(left.data!.sellable)
        ..[b.id] = List<DplWheel>.of(right.data!.sellable);
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
    final target = _first;
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
    if (_first != null && pallet.id == _first!.id) {
      DplSnacks.warning(
        context,
        '${pallet.palletNo} is already scanned. Scan the other pallet.',
      );
      _reFocus();
      return;
    }
    if (_first != null && pallet.partId != _first!.partId) {
      DplSnacks.error(
        context,
        '${pallet.palletNo} holds a different item. Only pallets of the same '
        'item can be combined.',
      );
      _reFocus();
      return;
    }

    setState(() {
      if (_first == null) {
        _first = pallet;
      } else {
        _second = pallet;
      }
      _scanCtrl.clear();
    });
    _reFocus();

    // Both in hand: fetch what is on them, so wheel scans can be matched.
    if (_first != null && _second != null) await _loadWheels();
  }

  void _reFocus() {
    _scanCtrl.clear();
    if (_first == null || _second == null) _scanFocus.requestFocus();
  }


  // -------------------------------------------------------------------------
  // Step 2 — which pallet to merge INTO
  // -------------------------------------------------------------------------

  Widget _chooseTargetCard() {
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'STEP 2 OF 3',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              color: DplColors.primary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Merge into which pallet?',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 4),
          Text(
            'Then scan the wheels off the OTHER pallet, one at a time, as you '
            'move them across.',
            style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
          ),
          const SizedBox(height: 12),
          for (final p in [_first!, _second!]) ...[
            _targetOption(p),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _targetOption(DplPallet p) {
    final count = _countOn(p);
    final std = p.standardQty;
    final room = std == null || std <= 0 ? null : std - count;
    return Material(
      color: DplColors.primaryTint,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: _busy ? null : () => _chooseTarget(p),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.palletNo,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$count${std == null ? '' : ' / $std'} wheels'
                      '${room == null ? '' : ' · room for $room'}'
                      '${p.locationCode.isEmpty ? '' : ' · on ${p.locationCode}'}',
                      style: TextStyle(
                        fontSize: 12,
                        color: DplColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                'Merge into this',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: DplColors.primary,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, color: DplColors.primary),
            ],
          ),
        ),
      ),
    );
  }

  void _chooseTarget(DplPallet p) {
    final std = p.standardQty ?? 0;
    if (std > 0 && _countOn(p) >= std) {
      DplSnacks.warning(
        context,
        '${p.palletNo} is already full. Choose the other pallet to fill.',
      );
      return;
    }
    setState(() => _targetId = p.id);
    // The next thing the operator does is pick a wheel up and scan it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _wheelFocus.requestFocus();
    });
  }

  // -------------------------------------------------------------------------
  // Step 3 — scanning wheels across
  // -------------------------------------------------------------------------

  Widget _progressCard() {
    final t = _target!;
    final s = _source!;
    final tCount = _countOn(t);
    final sCount = _countOn(s);
    final std = t.standardQty;

    Widget side(String label, DplPallet p, String count, {required bool into}) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
                color: into ? DplColors.primary : DplColors.textSecondary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              p.palletNo,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
            Text(
              count,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
            ),
          ],
        ),
      );
    }

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              side('Taking from', s, '$sCount left', into: false),
              Padding(
                padding: const EdgeInsets.only(top: 18, right: 12),
                child: Icon(Icons.arrow_forward_rounded,
                    color: DplColors.primary),
              ),
              side(
                'Merging into',
                t,
                std == null ? '$tCount' : '$tCount / $std',
                into: true,
              ),
            ],
          ),
          if (_targetFull || sCount == 0) ...[
            const SizedBox(height: 10),
            Text(
              _targetFull
                  ? '${t.palletNo} is FULL. Finish to print the labels.'
                  : '${s.palletNo} is empty — every wheel has moved. Finish to '
                      'print the label.',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: DplColors.success,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _wheelScanCard() {
    final canCamera =
        ref.watch(dplPermissionsProvider).can(DplPermission.palletScanCamera);
    final s = _source!;
    final stop = _targetFull || _countOn(s) == 0;

    final finish = SizedBox(
      width: double.infinity,
      child: _moved.isEmpty
          ? OutlinedButton.icon(
              onPressed: _busy ? null : _finish,
              icon: const Icon(Icons.close_rounded, size: 18),
              label: const Text('Cancel — nothing moved'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            )
          : FilledButton.icon(
              onPressed: _busy ? null : _finish,
              icon: const Icon(Icons.print_rounded, size: 18),
              label: Text('Finish & print labels (${_moved.length} moved)'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
    );

    // Full, or nothing left to take: the scanner has nothing more to do, so
    // the only thing on screen is the way out.
    if (stop) return DplCard(child: finish);

    return Column(
      children: [
        DplScanPanel(
          step: 'Step 3 of 3',
          title: 'Scan wheels from ${s.palletNo}',
          subtitle: 'Lift each wheel across and scan its label. It moves onto '
              '${_target!.palletNo} as you scan.',
          cameraLabel: 'Scan wheel label',
          onCamera: canCamera ? _scanWheelWithCamera : null,
          controller: _wheelCtrl,
          focusNode: _wheelFocus,
          hint: 'or type the wheel serial',
          onSubmitted: _queueWheelScan,
          capitalize: false,
          // Not disabled while a move is in flight: scans queue up behind it
          // (_scanChain), and a field that greys out between every wheel
          // would drop a fast trigger's next read.
        ),
        const SizedBox(height: 12),
        DplCard(child: finish),
      ],
    );
  }

  Widget _movedCard() {
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Moved (${_moved.length})',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 6),
          for (final label in _moved.take(20))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Icon(Icons.check_circle_rounded,
                      size: 16, color: DplColors.success),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(fontSize: 12.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          if (_moved.length > 20)
            Text(
              '…and ${_moved.length - 20} more',
              style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
            ),
        ],
      ),
    );
  }

  Future<void> _scanWheelWithCamera() async {
    final code = await DplQrScanSheet.open(context, kind: DplScanKind.wheel);
    if (code == null || !mounted) return;
    _queueWheelScan(code);
  }

  /// Applied strictly one after another — see [_scanChain].
  void _queueWheelScan(String raw) {
    _wheelCtrl.clear();
    _scanChain = _scanChain.then((_) => _moveScannedWheel(raw));
  }

  /// One scan = one wheel moved onto the chosen pallet, on the server, now.
  Future<void> _moveScannedWheel(String raw) async {
    if (!mounted) return;
    final code = raw.trim();
    final t = _target;
    final s = _source;
    if (code.isEmpty || t == null || s == null) return;

    // Already on the pallet being filled: a repeat trigger, or a wheel the
    // operator already carried across. Information, not an error.
    final onTarget = matchScannedWheel(code, _wheels[t.id] ?? const []);
    if (onTarget != null) {
      DplSnacks.warning(
        context,
        '${onTarget.serialNo} is already on ${t.palletNo}.',
      );
      _wheelFocus.requestFocus();
      return;
    }

    final wheel = matchScannedWheel(code, _wheels[s.id] ?? const []);
    if (wheel == null) {
      DplSnacks.error(
        context,
        'That label is not on ${s.palletNo}. Scan a wheel from ${s.palletNo}.',
      );
      _wheelFocus.requestFocus();
      return;
    }
    if (_targetFull) {
      DplSnacks.warning(
        context,
        '${t.palletNo} is already full. Finish to print the labels.',
      );
      return;
    }

    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).redistributeWheels(
          palletAId: t.id,
          palletBId: s.id,
          moves: {wheel.id: t.id},
        );
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError || res.data == null) {
      // OVER_CAPACITY, WHEEL_MOVED, a rack with no room for one more — the
      // server names each precisely, and nothing moved.
      DplSnacks.error(context, res.error ?? 'Could not move that wheel.');
      _wheelFocus.requestFocus();
      return;
    }

    final out = res.data!;
    setState(() {
      _wheels[s.id]?.removeWhere((w) => w.id == wheel.id);
      (_wheels[t.id] ??= <DplWheel>[]).add(wheel);
      _moved.insert(0, wheel.serialNo);
      _reprint = out.reprint;
      // The filled pallet is renumbered as merged, and either may have
      // changed type — keep showing what the server now says they are.
      for (final p in out.pallets) {
        if (p.id == _first?.id) _first = p;
        if (p.id == _second?.id) _second = p;
      }
    });
    _wheelFocus.requestFocus();
  }

  /// Print the labels of what changed, then start again.
  Future<void> _finish() async {
    // Let any scan still in flight land first, so its label is not missed.
    await _scanChain;
    if (!mounted) return;

    if (_moved.isEmpty) {
      _startOver();
      return;
    }

    final t = _target;
    final s = _source;
    DplSnacks.success(
      context,
      '${_moved.length} wheel${_moved.length == 1 ? '' : 's'} merged into '
      '${t?.palletNo ?? 'the pallet'}'
      '${s == null || _countOn(s) == 0 ? '.' : '. ${s.palletNo} keeps ${_countOn(s)}.'}',
    );

    // Sequential, not parallel: two print sheets racing each other is how an
    // operator dismisses one without noticing.
    for (final id in _reprint) {
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
