import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:printing/printing.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_machine.dart';
import '../../models/dpl_part.dart';
import '../../models/dpl_part_sticker.dart';
import '../../models/dpl_shift.dart';
import '../providers/qa_production_provider.dart' show qaCurrentShiftProvider;
import '../services/batch_quantity.dart';
import '../services/sticker_label_format.dart';
import '../widgets/label_format_picker.dart';

/// Every active machine, regardless of whether anything is planned on it.
///
/// The Production tab lists machines that have a plan for the chosen date and
/// shift. This flow has no plan, so it lists them all — which is the point:
/// the operator is printing for what is physically in front of them, not for
/// what somebody scheduled.
final qaMachinesProvider =
    FutureProvider.autoDispose<DplApiResponse<List<DplMachine>>>((ref) async {
  return ref.watch(dplApiServiceProvider).getQaMachines();
});


/// The shift master, for the direct-print shift picker.
///
/// Maxion's own Production Sticker screen asks for the shift because labels
/// for a run are routinely printed once the shift has rolled over — the wheels
/// were made on A, the printing happens at the start of B. Left to the clock,
/// the label would claim B for a wheel made on A, on a physical sticker nobody
/// can correct afterwards.
final qaShiftsProvider =
    FutureProvider.autoDispose<DplApiResponse<List<DplShift>>>((ref) async {
  return ref.watch(dplApiServiceProvider).getShifts();
});
/// The part-search term, shared by the direct-print tab and the pallet
/// screen's "start a pallet" picker. Public because both read it — the search
/// runs SERVER-side, so filtering has to go through one provider rather than
/// each screen sifting whatever page it happens to hold.
final qaDirectPartSearchProvider =
    NotifierProvider.autoDispose<QaDirectPartSearch, String>(
  QaDirectPartSearch.new,
);

class QaDirectPartSearch extends Notifier<String> {
  @override
  String build() => '';
  void set(String v) => state = v;
}

final qaDirectPartsProvider =
    FutureProvider.autoDispose<DplApiResponse<List<DplPart>>>((ref) async {
  final q = ref.watch(qaDirectPartSearchProvider);
  return ref.watch(dplApiServiceProvider).getQaParts(q: q);
});

/// Print labels with no production plan behind them.
///
/// Maxion Wheels Dispatch SSR v3.0 §5.2 — the pack point prints "one at a
/// time, or a full pallet worth in one go". There is no plan item here and so
/// no recorded actual quantity to check against: the operator picks a machine
/// and a part, says how many, and that many labels exist.
///
/// THE RULE THIS FLOW DOES NOT HAVE
/// The plan-driven screen refuses to print more labels than the supervisor
/// recorded as produced. Nothing does that here. The SSR replaces it with the
/// shift-end reconciliation of labels printed but never used, so the control
/// is after the fact rather than before it. The screen says so plainly rather
/// than letting an operator assume they are still being caught.
///
/// The server gates this whole flow on `labels.print_batch`, granted per
/// organization by an administrator; a plant without it never sees this tab.
class QaDirectPrintScreen extends ConsumerStatefulWidget {
  final bool showAppBar;

  const QaDirectPrintScreen({super.key, this.showAppBar = true});

  @override
  ConsumerState<QaDirectPrintScreen> createState() =>
      _QaDirectPrintScreenState();
}

class _QaDirectPrintScreenState extends ConsumerState<QaDirectPrintScreen> {
  final _qtyCtrl = TextEditingController(text: '1');
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  int? _machineId;
  /// Null means "let the server read the clock", which is what this screen
  /// did before the picker existed.
  String? _shiftCode;

  /// True once the operator has chosen or cleared the shift themselves. The
  /// preselect never overrides a deliberate choice.
  bool _shiftTouched = false;

  /// The shift these labels will claim.
  ///
  /// DERIVED, not stored. Until the operator touches the field this follows
  /// whatever shift the server says is running; after that it is exactly what
  /// they chose, including the deliberate "use the clock" of null.
  ///
  /// Doing it this way rather than writing the running shift into state on a
  /// listener avoids two bugs. A listener only fires on a CHANGE, so a
  /// provider already resolved by the first build would never preselect at
  /// all; and a later rebuild would quietly put the running shift back over a
  /// choice the operator had deliberately made.
  String? get _effectiveShift {
    if (_shiftTouched) return _shiftCode;
    // `read`, not `watch`: this is also called from _printNow, and watching
    // outside a build throws. `_shiftCard` watches the same provider, so the
    // value is already cached here and the screen still rebuilds when the
    // running shift arrives.
    final running = ref.read(qaCurrentShiftProvider).value?.data?.code.trim();
    return (running == null || running.isEmpty) ? null : running;
  }

  DplPart? _part;
  bool _busy = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _qtyCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) ref.read(qaDirectPartSearchProvider.notifier).set(v);
    });
  }

  /// No `remaining` to clamp against on this flow, so the only ceiling is the
  /// server's 500-per-batch. Passing it as `remainingQty` reuses the same
  /// resolver the plan-driven screen uses rather than duplicating the parsing
  /// and the floor-of-one.
  int get _count => BatchQuantity.resolve(
        typed: _qtyCtrl.text,
        remainingQty: BatchQuantity.maxPerBatch,
        batch: true,
      );

  @override
  Widget build(BuildContext context) {
    final body = ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
      children: [
        _noticeCard(),
        const SizedBox(height: 12),
        _machineCard(),
        const SizedBox(height: 12),
        _shiftCard(),
        const SizedBox(height: 12),
        _partCard(),
        const SizedBox(height: 12),
        LabelFormatPicker(enabled: !_busy),
        _qtyCard(),
      ],
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: AppBar(title: const Text('Print labels')),
      body: body,
    );
  }

  /// Says out loud that the production check does not apply here.
  ///
  /// An operator who has used the plan-driven screen has been refused by it
  /// before and will reasonably assume the same net is underneath them. It is
  /// not, and finding that out from a pile of spare labels is worse than
  /// reading one sentence.
  Widget _noticeCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DplColors.warningBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VistarPalette.warnLine),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: DplColors.warning),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'These labels are not checked against recorded production. '
              'Whatever quantity you enter is what gets printed, so print only '
              'what you are actually packing.',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                fontWeight: FontWeight.w600,
                color: VistarPalette.warnInk,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _machineCard() {
    final async = ref.watch(qaMachinesProvider);

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '1. Machine (station)',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 10),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
            error: (e, _) => DplInlineErrorRetry(
              message: e.toString(),
              onRetry: () => ref.invalidate(qaMachinesProvider),
            ),
            data: (res) {
              if (res.isError) {
                return DplInlineErrorRetry(
                  message: res.error ?? 'Failed to load machines.',
                  onRetry: () => ref.invalidate(qaMachinesProvider),
                );
              }
              final machines = res.data ?? const <DplMachine>[];
              if (machines.isEmpty) {
                return Text(
                  'No machines are set up for this organization yet. A manager '
                  'adds them under Masters.',
                  style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
                );
              }
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in machines)
                    ChoiceChip(
                      selected: _machineId == m.id,
                      onSelected: _busy
                          ? null
                          : (_) => setState(() => _machineId = m.id),
                      label: Text(m.name.isEmpty
                          ? m.code
                          : m.name),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// Production shift — Maxion's "Production Shift".
  ///
  /// Preselected to whatever is running now, so the operator printing during
  /// the shift they are in does nothing. It exists for the case that is not
  /// that: printing a run's labels after the shift has rolled over.
  Widget _shiftCard() {
    // Watched purely to establish the dependency: `_effectiveShift` reads it,
    // and without this the chips would not repaint when the running shift
    // finally arrives from the server.
    ref.watch(qaCurrentShiftProvider);
    final async = ref.watch(qaShiftsProvider);

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '2. Production shift',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
              if (_effectiveShift != null)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _shiftTouched = true;
                            _shiftCode = null;
                          }),
                  child: const Text('Use the clock'),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            _effectiveShift == null
                ? 'Left to the clock — the server stamps whichever shift is '
                    'running when you press print.'
                : 'Every label in this run will say shift $_effectiveShift.',
            style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
          ),
          const SizedBox(height: 10),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
            // A shift master that will not load must not block a print. The
            // server still resolves one from the clock, which is what this
            // screen did before the picker existed.
            error: (e, _) => DplInlineErrorRetry(
              message: e.toString(),
              onRetry: () => ref.invalidate(qaShiftsProvider),
            ),
            data: (res) {
              if (res.isError) {
                return DplInlineErrorRetry(
                  message: res.error ?? 'Failed to load shifts.',
                  onRetry: () => ref.invalidate(qaShiftsProvider),
                );
              }
              final shifts = (res.data ?? const <DplShift>[])
                  .where((s) => s.isActive)
                  .toList(growable: false);
              if (shifts.isEmpty) {
                return Text(
                  'No shifts are set up for this organization yet. A manager '
                  'adds them under Masters; until then the clock decides.',
                  style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
                );
              }
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in shifts)
                    ChoiceChip(
                      selected: _effectiveShift == s.code,
                      onSelected: _busy
                          ? null
                          : (_) {
                              // Read the answer BEFORE the flag flips. Once
                              // _shiftTouched is true the getter stops
                              // consulting the running shift, so tapping the
                              // already-selected chip would fail to clear it.
                              final was = _effectiveShift;
                              setState(() {
                                _shiftTouched = true;
                                _shiftCode = was == s.code ? null : s.code;
                              });
                            },
                      label: Text(
                        s.name.isEmpty ? s.code : '${s.code} · ${s.name}',
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

  Widget _partCard() {
    final async = ref.watch(qaDirectPartsProvider);
    final selected = _part;

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '3. Item',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 10),
          if (selected != null) ...[
            // Once chosen, the part is shown as a committed choice rather than
            // a highlighted row in a long list — what gets printed onto a
            // physical piece should not be something you have to scroll to
            // re-read.
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: DplColors.primaryTint,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selected.partNumber.isNotEmpty
                              ? selected.partNumber
                              : selected.description,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        if (selected.name.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            selected.name,
                            style: TextStyle(
                              fontSize: 12,
                              color: DplColors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed:
                        _busy ? null : () => setState(() => _part = null),
                    child: const Text('Change'),
                  ),
                ],
              ),
            ),
          ] else ...[
            TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: 'Search part number or name',
                prefixIcon: Icon(Icons.search_rounded),
                isDense: true,
              ),
              onChanged: _onSearch,
            ),
            const SizedBox(height: 10),
            async.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(minHeight: 2),
              ),
              error: (e, _) => DplInlineErrorRetry(
                message: e.toString(),
                onRetry: () => ref.invalidate(qaDirectPartsProvider),
              ),
              data: (res) {
                if (res.isError) {
                  return DplInlineErrorRetry(
                    message: res.error ?? 'Failed to load parts.',
                    onRetry: () => ref.invalidate(qaDirectPartsProvider),
                  );
                }
                final parts = res.data ?? const <DplPart>[];
                if (parts.isEmpty) {
                  return Text(
                    'No parts match.',
                    style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
                  );
                }
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: parts.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final p = parts[i];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          p.partNumber.isNotEmpty
                              ? p.partNumber
                              : p.description,
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
                        onTap: _busy ? null : () => setState(() => _part = p),
                      );
                    },
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _qtyCard() {
    final ready = _part != null && !_busy;
    final count = _count;

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '4. Sticker qty',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 130,
                child: TextField(
                  controller: _qtyCtrl,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Quantity',
                    isDense: true,
                    prefixIcon: Icon(Icons.tag, size: 18),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final preset
                        in BatchQuantity.presets(BatchQuantity.maxPerBatch))
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _qtyCtrl.text = '$preset'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text('$preset'),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if ((int.tryParse(_qtyCtrl.text.trim()) ?? 1) >
              BatchQuantity.maxPerBatch) ...[
            const SizedBox(height: 8),
            Text(
              'At most ${BatchQuantity.maxPerBatch} per press — that is what '
              'will be printed. Press again for the rest.',
              style: TextStyle(
                color: DplColors.warning,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: ready ? _printNow : null,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_outlined, size: 18),
              label: Text(
                _busy
                    ? 'Printing…'
                    : _part == null
                        ? 'Pick a part first'
                        : 'Print $count label${count == 1 ? '' : 's'}',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _printNow() async {
    final part = _part;
    if (part == null) return;

    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).issueDirectQaStickers(
          partId: part.id,
          machineId: _machineId,
          shiftCode: _effectiveShift,
          count: _count,
        );
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError || res.data == null) {
      DplSnacks.error(
        context,
        // DIRECT_PRINT_NOT_ALLOWED already names the situation and the remedy.
        res.error ?? 'Failed to print the labels.',
      );
      return;
    }

    final issued = res.data!;
    if (issued.stickers.isEmpty) {
      DplSnacks.warning(context, 'Nothing was issued.');
      return;
    }

    // Serials are issued BEFORE the print sheet opens, for the same reason as
    // the plan-driven flow: a cancel after a successful spool is
    // indistinguishable from a cancel before one, so recording first is what
    // keeps the database from being short of what is physically on the floor.
    await _print(issued.stickers, part);
    if (!mounted) return;
    DplSnacks.success(
      context,
      '${issued.stickers.length} label'
      '${issued.stickers.length == 1 ? '' : 's'} issued '
      '(${issued.stickers.first.serialNo} – ${issued.stickers.last.serialNo}).',
    );
  }

  Future<void> _print(List<DplPartSticker> stickers, DplPart part) async {
    final layout = ref.read(effectiveStickerLabelFormatProvider);
    setState(() => _busy = true);
    try {
      await Printing.layoutPdf(
        name: 'Labels-${part.partNumber}',
        // Both the page box AND the layout format must be the die-cut, and
        // dynamicLayout must be off: left on, picking A4 in the print dialog
        // silently rescales the label.
        format: layout.rollFormat,
        dynamicLayout: false,
        onLayout: (PdfPageFormat _) =>
            layout.buildRoll(stickers, part: part),
      );
    } catch (e) {
      if (mounted) {
        DplSnacks.error(
          context,
          'The labels were issued but the print sheet failed to open. '
          'Use Reprint from the sticker list rather than issuing them again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
