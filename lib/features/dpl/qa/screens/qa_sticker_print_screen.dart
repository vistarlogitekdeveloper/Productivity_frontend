import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:printing/printing.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../core/widgets/dpl_stat_tile.dart';
import '../../manager/providers/dpl_plan_detail_provider.dart';
import '../../models/dpl_part.dart';
import '../../models/dpl_part_sticker.dart';
import '../providers/qa_production_provider.dart';
import '../services/batch_quantity.dart';
import '../services/part_sticker_label_pdf.dart';

/// Choose how many stickers to print, issue them, print them.
///
/// The ordering here is deliberate and is the whole safety story:
///
///   1. Ask the SERVER to issue N serials. It takes the count under a row lock
///      on the plan item and refuses anything above `actual_qty`.
///   2. Render the PDF from the serials it returned.
///   3. Open the print sheet.
///
/// It cannot be the other way round. The OS print sheet returns a bool that is
/// false on user-cancel, and a cancel after a successful spool is
/// indistinguishable from a cancel before one — so "print, then record" would
/// either lose labels that physically exist or double-count ones that do not.
/// Issuing first means the database is never short of what is on the floor.
///
/// The cost of that choice is a cancelled print leaves serials issued, so the
/// screen offers "Void this batch" immediately afterwards: the quantity comes
/// back, the serial numbers are retired, and nothing is silently reused.
class QaStickerPrintScreen extends ConsumerStatefulWidget {
  final int planId;
  final int planItemId;
  final DplPart part;
  final String substratePartNo;
  final String? rawPayload;

  const QaStickerPrintScreen({
    super.key,
    required this.planId,
    required this.planItemId,
    required this.part,
    required this.substratePartNo,
    this.rawPayload,
  });

  @override
  ConsumerState<QaStickerPrintScreen> createState() =>
      _QaStickerPrintScreenState();
}

class _QaStickerPrintScreenState extends ConsumerState<QaStickerPrintScreen> {
  bool _busy = false;

  /// Set once the server has issued a label. Until it is cleared the screen is
  /// in "printed, awaiting confirmation" mode.
  DplStickerIssueResult? _issued;

  /// How many to issue on the next press.
  ///
  /// Only reachable when this organization holds `labels.print_batch`; without
  /// it the screen is hard-wired to one and there is no field to change it.
  final _qtyCtrl = TextEditingController(text: '1');

  @override
  void initState() {
    super.initState();
    // Re-read what this organization is allowed to do, on entering the screen
    // that decides it.
    //
    // This screen is pushed by Navigator from the plan-detail ROUTE, which
    // sits outside the QA shell — so the shell's own refresh never runs for
    // it. Without this, an administrator who revoked `labels.print_batch`
    // changed nothing the operator could see: the quantity field kept
    // rendering from a permission list cached at login, and the first they
    // knew of it was the server refusing the press with
    // BATCH_PRINT_NOT_ALLOWED.
    //
    // Deferred past the first frame because it touches providers, and
    // fire-and-forget because a failed refresh must leave the cached list
    // alone rather than blanking the screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(dplPermissionsProvider.notifier).refresh();
    });
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    super.dispose();
  }

  static const int _maxPerBatch = BatchQuantity.maxPerBatch;

  /// What the next press will issue. See [BatchQuantity] for the rules.
  int _requestedCount(DplStickerSummary summary, {required bool batch}) =>
      BatchQuantity.resolve(
        typed: _qtyCtrl.text,
        remainingQty: summary.remainingQty,
        batch: batch,
      );

  int _ceilingFor(DplStickerSummary summary) =>
      BatchQuantity.ceiling(summary.remainingQty);

  @override
  Widget build(BuildContext context) {
    final issued = _issued;

    // Once a batch is issued the screen renders from the server's own reply
    // and stops depending on the summary provider. That provider is
    // invalidated at the same moment, and routing this state through its
    // loading branch would blink the "Void this batch" button out of
    // existence exactly when the operator is deciding whether to use it.
    if (issued != null) {
      return Scaffold(
        appBar: const DplAppBar(title: 'QA · Print Labels'),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
          children: [
            _partCard(),
            const SizedBox(height: 12),
            _allowanceCard(issued.summary),
            const SizedBox(height: 12),
            _printedCard(issued),
          ],
        ),
      );
    }

    final summaryAsync = ref.watch(qaStickerSummaryProvider(widget.planItemId));

    return Scaffold(
      appBar: const DplAppBar(title: 'QA · Print Labels'),
      body: summaryAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => DplInlineErrorRetry(
          message: e.toString(),
          onRetry: () =>
              ref.invalidate(qaStickerSummaryProvider(widget.planItemId)),
        ),
        data: (res) {
          if (res.isError || res.data == null) {
            return DplInlineErrorRetry(
              message: res.error ?? 'Failed to read the sticker count.',
              onRetry: () =>
                  ref.invalidate(qaStickerSummaryProvider(widget.planItemId)),
            );
          }
          return _body(res.data!);
        },
      ),
    );
  }

  /// Pre-issue state only — the post-issue view is built directly in [build].
  Widget _body(DplStickerSummary summary) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
      children: [
        _partCard(),
        const SizedBox(height: 12),
        _allowanceCard(summary),
        const SizedBox(height: 12),
        _issueCard(summary),
      ],
    );
  }

  Widget _partCard() {
    final p = widget.part;
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Customer part reference',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: VistarPalette.txt2,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            p.partNumber.isEmpty ? p.description : p.partNumber,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          if (p.description.isNotEmpty || p.name.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              [
                if (p.description.isNotEmpty) p.description,
                if (p.name.isNotEmpty) p.name,
              ].join(' · '),
              style: TextStyle(
                color: VistarPalette.txt2,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
          const Divider(height: 18),
          Row(
            children: [
              Icon(Icons.inventory_2_outlined,
                  size: 15, color: VistarPalette.txt2),
              const SizedBox(width: 6),
              Text(
                'Substrate ${widget.substratePartNo.isEmpty ? (p.substratePartNo.isEmpty ? '—' : p.substratePartNo) : widget.substratePartNo}',
                style: TextStyle(
                  color: VistarPalette.txt,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _allowanceCard(DplStickerSummary summary) {
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: DplStatTile(
                  label: 'Produced',
                  value: '${summary.actualQty}',
                ),
              ),
              Expanded(
                child: DplStatTile(
                  label: 'Printed',
                  value: '${summary.printedQty}',
                ),
              ),
              Expanded(
                child: DplStatTile(
                  label: 'Left',
                  value: '${summary.remainingQty}',
                  valueColor: summary.remainingQty > 0
                      ? VistarPalette.ok
                      : VistarPalette.txt3,
                ),
              ),
            ],
          ),
          if (summary.wasReset) ...[
            const SizedBox(height: 10),
            _notice(
              icon: Icons.replay_rounded,
              color: VistarPalette.warn,
              text:
                  "This item's recorded quantity was reset to zero because the "
                  'plan was reopened, but ${summary.printedQty} label'
                  '${summary.printedQty == 1 ? ' is' : 's are'} still issued '
                  'against it. Ask the supervisor to record the actual quantity '
                  'again, or void those labels if that run was cancelled.',
            ),
          ] else if (summary.noProductionYet) ...[
            const SizedBox(height: 10),
            _notice(
              icon: Icons.hourglass_empty_rounded,
              color: VistarPalette.warn,
              text:
                  'No production has been recorded against this item yet, so '
                  'no labels can be printed. The supervisor records the actual '
                  'quantity when the item is stopped.',
            ),
          ] else if (!summary.canPrint) ...[
            const SizedBox(height: 10),
            _notice(
              icon: Icons.check_circle_outline_rounded,
              color: VistarPalette.ok,
              text:
                  'All ${summary.actualQty} labels for this item have already '
                  'been printed.',
            ),
          ],
        ],
      ),
    );
  }

  /// How labels come out of this screen, which depends on the plant.
  ///
  /// WITHOUT `labels.print_batch` (every organization by default): one label
  /// per press, no quantity input. The operator prints a label, applies it to
  /// the part in front of them, and presses again. A quantity field here
  /// invites printing a stack and matching them to parts afterwards, which is
  /// the situation the serials exist to prevent.
  ///
  /// WITH it: a quantity field. A plant that packs a pallet at a time cannot
  /// work one press at a time, and forcing it to is how people end up printing
  /// from somewhere else entirely.
  ///
  /// An administrator decides which, per organization, from the Access screen.
  /// The server re-checks on every issue, so this is presentation only — a
  /// stale client that sends a batch anyway is refused with
  /// `BATCH_PRINT_NOT_ALLOWED`.
  Widget _issueCard(DplStickerSummary summary) {
    final canPrint = summary.canPrint;
    final batch =
        ref.watch(dplPermissionsProvider).can(DplPermission.labelsPrintBatch);
    final count = _requestedCount(summary, batch: batch);

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            batch ? 'Print labels' : 'Print the next label',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            !canPrint
                ? 'Nothing left to print for this item.'
                : batch
                    ? 'Enter how many to print. ${summary.remainingQty} left '
                        'for this item — you cannot print more than that.'
                    : 'One label is issued each time you press. '
                        '${summary.remainingQty} left for this item.',
            style: TextStyle(
              color: VistarPalette.txt2,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
          if (batch && canPrint) ...[
            const SizedBox(height: 14),
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
                      labelText: 'How many',
                      isDense: true,
                      prefixIcon: Icon(Icons.tag, size: 18),
                    ),
                    // Rebuilds so the button label and the clamp notice below
                    // track what has been typed.
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final preset in _presetsFor(_ceilingFor(summary)))
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => setState(
                                    () => _qtyCtrl.text = '$preset',
                                  ),
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
                _ceilingFor(summary)) ...[
              const SizedBox(height: 8),
              Text(
                // Two different reasons to clamp, and the operator needs to
                // know which: "there are only 12 parts" is a different
                // situation from "the printer takes 500 at a time".
                summary.remainingQty <= _maxPerBatch
                    ? 'Only ${summary.remainingQty} left — that is what will '
                        'be printed.'
                    : 'At most $_maxPerBatch per press — that is what will be '
                        'printed. Press again for the rest.',
                style: TextStyle(
                  color: VistarPalette.warn,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (!canPrint || _busy)
                  ? null
                  : () => _issueAndPrint(summary, count: count),
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_outlined, size: 18),
              label: Text(
                _busy
                    ? 'Issuing…'
                    : 'Issue & print $count label${count == 1 ? '' : 's'}',
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<int> _presetsFor(int ceilingQty) => BatchQuantity.presets(ceilingQty);

  Widget _printedCard(DplStickerIssueResult issued) {
    final first = issued.stickers.isEmpty ? null : issued.stickers.first;
    final last = issued.stickers.isEmpty ? null : issued.stickers.last;
    // Straight from the server's reply, so it already accounts for this batch.
    final remaining = issued.summary.remainingQty;

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_rounded,
                  color: VistarPalette.ok, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${issued.stickers.length} label'
                  '${issued.stickers.length == 1 ? '' : 's'} issued',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          if (first != null && last != null) ...[
            const SizedBox(height: 6),
            Text(
              issued.stickers.length == 1
                  ? 'Serial ${first.serialNo}'
                  : 'Serials ${first.serialNo} → ${last.serialNo}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: VistarPalette.txt,
              ),
            ),
          ],
          const SizedBox(height: 12),
          _notice(
            icon: Icons.info_outline_rounded,
            color: VistarPalette.info,
            text: issued.stickers.length == 1
                ? 'This serial is recorded against the item. If the label did '
                    'not come out, void it so the quantity is released.'
                : 'These serials are recorded against the item. If the labels '
                    'did not come out, void the batch so the quantity is released.',
          ),
          const SizedBox(height: 12),
          // Primary action is the next label, not "Done": the operator applies
          // the label they just printed and immediately needs another. Making
          // them back out to the plan and re-scan between every single part
          // would make one-at-a-time unusable on the floor.
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy
                  ? null
                  : (remaining > 0 ? () => _nextLabel(issued) : _done),
              icon: Icon(
                remaining > 0 ? Icons.arrow_forward_rounded : Icons.check_rounded,
                size: 18,
              ),
              label: Text(
                remaining > 0
                    ? _nextLabelText(issued.summary, remaining)
                    : 'Done — all labels printed',
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _print(issued, roll: true),
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('Reprint'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _voidBatch(issued),
                  icon: const Icon(Icons.undo_rounded, size: 18),
                  label: const Text('Void'),
                ),
              ),
            ],
          ),
          if (remaining > 0) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy ? null : _done,
                child: const Text('Stop here'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── actions ──

  /// Clear the just-printed card and immediately issue the next label.
  ///
  /// Deliberately does not wait for the summary provider to refetch — the
  /// server's own reply already told us what is left, and a round trip between
  /// every part is exactly the friction one-at-a-time cannot afford.
  /// What the follow-up button promises. It has to name the SAME number the
  /// next press will actually issue, or the operator learns not to trust it.
  String _nextLabelText(DplStickerSummary summary, int remaining) {
    final batch =
        ref.read(dplPermissionsProvider).can(DplPermission.labelsPrintBatch);
    if (!batch) return 'Print next label ($remaining left)';
    final next = _requestedCount(summary, batch: true);
    return 'Print next $next label${next == 1 ? '' : 's'} ($remaining left)';
  }

  Future<void> _nextLabel(DplStickerIssueResult issued) async {
    if (issued.summary.remainingQty <= 0) {
      _done();
      return;
    }
    setState(() => _issued = null);
    // Carry the quantity forward. In batch mode the operator asked for 16;
    // silently dropping to 1 on the follow-up press would look like the field
    // had been ignored, and they would only notice after the print.
    final batch =
        ref.read(dplPermissionsProvider).can(DplPermission.labelsPrintBatch);
    await _issueAndPrint(
      issued.summary,
      count: _requestedCount(issued.summary, batch: batch),
    );
  }

  Future<void> _issueAndPrint(
    DplStickerSummary summary, {
    int count = 1,
  }) async {
    // The local `remaining` check is a courtesy so the button reads honestly;
    // the server re-checks under a row lock on the plan item and is the only
    // thing that actually enforces the cap.
    if (!summary.canPrint) {
      DplSnacks.warning(context, 'Nothing left to print for this item.');
      return;
    }

    setState(() => _busy = true);

    final res = await ref.read(dplApiServiceProvider).issueQaStickers(
          planItemId: widget.planItemId,
          partId: widget.part.id,
          count: count < 1 ? 1 : count,
          substratePartNo: widget.substratePartNo,
          rawPayload: widget.rawPayload,
        );

    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError || res.data == null) {
      // The cap firing is the expected, non-exceptional case — the server
      // message already names how many are actually left, so surface it
      // verbatim rather than inventing our own wording.
      if (res.code == 'BATCH_PRINT_NOT_ALLOWED') {
        // This organization prints one label per press and a stale client
        // asked for more. Correct the screen rather than just complaining:
        // re-reading the permissions removes the quantity field, so the next
        // press does the thing that will actually work.
        DplSnacks.warning(
          context,
          res.error ?? 'This plant prints one label at a time.',
        );
        await ref.read(dplPermissionsProvider.notifier).refresh();
        if (!mounted) return;
        setState(() => _qtyCtrl.text = '1');
        ref.invalidate(qaStickerSummaryProvider(widget.planItemId));
        return;
      }
      if (res.code == 'STICKER_LIMIT_EXCEEDED' ||
          res.code == 'ACTUAL_QTY_RESET' ||
          res.code == 'NO_ACTUAL_QTY') {
        // Expected, non-exceptional states. The server message already explains
        // the situation precisely, so show it verbatim rather than inventing
        // wording that could contradict it.
        DplSnacks.warning(context, res.error ?? 'Cannot print right now.');
      } else if (res.code == 'PART_NOT_ON_PLAN_ITEM' ||
          res.code == 'SUBSTRATE_PART_MISMATCH') {
        // The server refused because the label would not have matched the part
        // on the plan item. Nothing was issued. Send the operator back to the
        // scanner rather than leaving them on a screen for a part they are not
        // allowed to print.
        DplSnacks.error(
          context,
          res.error ??
              'That part does not belong to this plan item. Scan again.',
        );
        Navigator.of(context).pop();
        return;
      } else {
        DplSnacks.error(context, res.error ?? 'Failed to issue labels.');
      }
      // The local count may now be stale — refresh it either way.
      ref.invalidate(qaStickerSummaryProvider(widget.planItemId));
      return;
    }

    final issued = res.data!;
    setState(() => _issued = issued);

    // Plan detail shows printed/left per item, so it is stale the moment a
    // batch is issued.
    ref.invalidate(qaStickerSummaryProvider(widget.planItemId));
    ref.invalidate(dplPlanDetailProvider(widget.planId));

    await _print(issued, roll: true);
  }

  Future<void> _print(DplStickerIssueResult issued, {required bool roll}) async {
    if (issued.stickers.isEmpty) return;
    setState(() => _busy = true);
    try {
      await Printing.layoutPdf(
        name: 'Labels-${widget.part.partNumber}-${issued.batchId}',
        // Both the page box AND the layout format must be the die-cut, and
        // dynamicLayout must be off: left on, the operator picking A4 in the
        // print dialog silently rescales a 50x25 mm label.
        format: roll
            ? PartStickerLabelPdf.rollFormat
            : PdfPageFormat.a4.landscape,
        dynamicLayout: !roll,
        onLayout: (_) => roll
            ? PartStickerLabelPdf.buildRoll(issued.stickers)
            : PartStickerLabelPdf.buildSheet(issued.stickers),
      );
    } on MissingPluginException {
      // Almost always means the running binary predates the `printing` plugin
      // being added. Hot restart cannot fix it; the app must be fully rebuilt.
      if (mounted) {
        DplSnacks.error(
          context,
          'Print not available in this build. Please fully restart the app '
          '(stop + run again) so the print plugin is registered.',
        );
      }
    } catch (e) {
      if (mounted) {
        DplSnacks.error(context, 'Failed to open print sheet: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _voidBatch(DplStickerIssueResult issued) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Void these labels?'),
        content: Text(
          '${issued.stickers.length} label'
          '${issued.stickers.length == 1 ? '' : 's'} will be voided and the '
          'quantity released so you can print again.\n\n'
          'The serial numbers themselves are retired and will never be reused, '
          'so a label found later can still be explained.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Void'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).voidQaStickers(
          stickerIds: issued.stickers.map((s) => s.id).toList(),
          reason: 'Voided by QA after printing',
        );
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError) {
      DplSnacks.error(context, res.error ?? 'Failed to void the labels.');
      return;
    }

    // Names the count, because voiding a batch of sixteen and being told
    // "Label voided" reads as though fifteen are still spoken for.
    final n = issued.stickers.length;
    DplSnacks.success(
      context,
      n == 1
          ? 'Label voided. The quantity is available again.'
          : '$n labels voided. The quantity is available again.',
    );
    setState(() => _issued = null);
    ref.invalidate(qaStickerSummaryProvider(widget.planItemId));
    ref.invalidate(dplPlanDetailProvider(widget.planId));
  }

  void _done() {
    ref.invalidate(qaStickerSummaryProvider(widget.planItemId));
    ref.invalidate(dplPlanDetailProvider(widget.planId));
    Navigator.of(context).pop();
  }

  Widget _notice({
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
