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
import '../services/batch_quantity.dart';
import '../services/part_sticker_label_pdf.dart';

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
        _partCard(),
        const SizedBox(height: 12),
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
            '1. Machine',
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

  Widget _partCard() {
    final async = ref.watch(qaDirectPartsProvider);
    final selected = _part;

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '2. Part',
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
            '3. How many',
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
    await _print(issued.stickers);
    if (!mounted) return;
    DplSnacks.success(
      context,
      '${issued.stickers.length} label'
      '${issued.stickers.length == 1 ? '' : 's'} issued '
      '(${issued.stickers.first.serialNo} – ${issued.stickers.last.serialNo}).',
    );
  }

  Future<void> _print(List<DplPartSticker> stickers) async {
    setState(() => _busy = true);
    try {
      await Printing.layoutPdf(
        name: 'Labels-${_part?.partNumber ?? 'direct'}',
        // Both the page box AND the layout format must be the die-cut, and
        // dynamicLayout must be off: left on, picking A4 in the print dialog
        // silently rescales a 50x25 mm label.
        format: PartStickerLabelPdf.rollFormat,
        dynamicLayout: false,
        onLayout: (PdfPageFormat _) =>
            PartStickerLabelPdf.buildRoll(stickers),
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
