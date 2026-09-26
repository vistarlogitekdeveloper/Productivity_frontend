import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_customer_return.dart';
import '../../models/dpl_logistics.dart';
import '../../models/dpl_part.dart';
import '../common/maxion_kit.dart';
import 'gate_pass_screen.dart' show LogisticsFriendlyEmpty;
import 'logistics_providers.dart';
import 'logistics_scan_page.dart';
import 'reversal_widgets.dart' show askLogisticsNote;

final _dateTime = DateFormat('d MMM yyyy, HH:mm');

/// Customer returns (§8.5): wheels coming back after the truck left the plant.
class DplCustomerReturnsScreen extends ConsumerWidget {
  const DplCustomerReturnsScreen({super.key, this.showAppBar = true});

  final bool showAppBar;

  Future<void> _newReturn(BuildContext context, WidgetRef ref) async {
    final input = await showDialog<({String reason, String? referenceNo, int? consigneeId})>(
      context: context,
      builder: (_) => const _NewReturnDialog(),
    );
    if (input == null || !context.mounted) return;
    final res = await ref.read(dplApiServiceProvider).createReturn(
          reason: input.reason,
          referenceNo: input.referenceNo,
          consigneeId: input.consigneeId,
        );
    if (!context.mounted) return;
    if (res.isError || res.data == null) {
      showFloorError(context, res, fallback: 'Could not open the return.');
      return;
    }
    ref.invalidate(customerReturnsProvider);
    DplSnacks.success(context, 'Return ${res.data!.returnNo} opened.');
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DplCustomerReturnDetailScreen(returnId: res.data!.returnId),
    ));
    ref.invalidate(customerReturnsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(dplPermissionsProvider);
    final canReceive = perms.can(DplPermission.returnsReceive);
    final status = ref.watch(customerReturnsStatusProvider);
    final async = ref.watch(customerReturnsProvider);
    void retry() => ref.invalidate(customerReturnsProvider);

    final list = async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => DplInlineErrorRetry(message: e.toString(), onRetry: retry),
      data: (res) {
        if (res.isError) {
          return DplInlineErrorRetry(
            message: res.floorMessage.isEmpty ? 'Could not load returns.' : res.floorMessage,
            onRetry: retry,
          );
        }
        final items = res.data ?? const <DplCustomerReturn>[];
        if (items.isEmpty) {
          return LogisticsFriendlyEmpty(
            icon: Icons.assignment_return_outlined,
            title: status == 'open' ? 'No open returns' : 'No closed returns',
            message: status == 'open' && canReceive ? 'Tap "New return" when wheels come back from a customer.' : null,
            onRetry: retry,
          );
        }
        return RefreshIndicator(
          onRefresh: () async => retry(),
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(DplSpacing.md, DplSpacing.md, DplSpacing.md, 96),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: DplSpacing.sm),
            itemBuilder: (_, i) {
              final r = items[i];
              return DplCard(
                accentColor: r.isOpen ? DplColors.warning : DplColors.neutral,
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => DplCustomerReturnDetailScreen(returnId: r.returnId),
                  ));
                  ref.invalidate(customerReturnsProvider);
                },
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r.returnNo, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                          const SizedBox(height: 2),
                          Text(r.reason, maxLines: 2, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (r.referenceNo != null && r.referenceNo!.isNotEmpty) 'Ref ${r.referenceNo}',
                              if (r.receivedAt != null) _dateTime.format(r.receivedAt!.toLocal()),
                            ].join(' · '),
                            style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: DplColors.textTertiary),
                  ],
                ),
              );
            },
          ),
        );
      },
    );

    final body = Column(
      children: [
        Container(
          color: Colors.white,
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'open', label: Text('Open'), icon: Icon(Icons.inventory_2_outlined)),
                    ButtonSegment(value: 'closed', label: Text('Closed'), icon: Icon(Icons.task_alt)),
                  ],
                  selected: {status},
                  onSelectionChanged: (s) => ref.read(customerReturnsStatusProvider.notifier).set(s.first),
                ),
              ),
              IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: retry),
            ],
          ),
        ),
        Expanded(child: list),
      ],
    );

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: showAppBar ? DplAppBar(title: 'Customer returns') : null,
      body: body,
      floatingActionButton: canReceive
          ? FloatingActionButton.extended(
              onPressed: () => _newReturn(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('New return'),
            )
          : null,
    );
  }
}

class _NewReturnDialog extends ConsumerStatefulWidget {
  const _NewReturnDialog();

  @override
  ConsumerState<_NewReturnDialog> createState() => _NewReturnDialogState();
}

class _NewReturnDialogState extends ConsumerState<_NewReturnDialog> {
  final _reason = TextEditingController();
  final _ref = TextEditingController();
  int? _consigneeId;

  @override
  void dispose() {
    _reason.dispose();
    _ref.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final consignees = ref.watch(logisticsConsigneesProvider).value?.data ?? const <DplConsignee>[];
    final ok = _reason.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('New customer return'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _reason,
              autofocus: true,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Reason (required)',
                hintText: 'e.g. Rim damage found at customer',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ref,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Customer reference',
                hintText: 'Their rejection note / RTV no',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int?>(
              initialValue: _consigneeId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Consignee', border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem<int?>(value: null, child: Text('— not specified —')),
                for (final c in consignees)
                  DropdownMenuItem<int?>(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _consigneeId = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: ok
              ? () => Navigator.of(context).pop((
                    reason: _reason.text.trim(),
                    referenceNo: _ref.text.trim().isEmpty ? null : _ref.text.trim(),
                    consigneeId: _consigneeId,
                  ))
              : null,
          child: const Text('Open return'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Detail
// ---------------------------------------------------------------------------

/// One return: receive wheels into quarantine, then QA restocks or scraps them.
class DplCustomerReturnDetailScreen extends ConsumerStatefulWidget {
  const DplCustomerReturnDetailScreen({super.key, required this.returnId, this.showAppBar = true});

  final int returnId;
  final bool showAppBar;

  @override
  ConsumerState<DplCustomerReturnDetailScreen> createState() => _DplCustomerReturnDetailScreenState();
}

class _DplCustomerReturnDetailScreenState extends ConsumerState<DplCustomerReturnDetailScreen> {
  final _scanCtrl = TextEditingController();
  final _scanFocus = FocusNode();
  final Set<int> _selected = {};
  bool _busy = false;

  @override
  void dispose() {
    _scanCtrl.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  void _reload() => ref.invalidate(customerReturnProvider(widget.returnId));

  /// Receives one wheel. Shared by the hardware field and the camera page.
  Future<LogisticsScanOutcome> _receive(String code) async {
    final res = await ref.read(dplApiServiceProvider).scanReturnedWheel(widget.returnId, code.trim());
    if (res.isError) {
      return (ok: false, message: res.floorMessage.isEmpty ? 'Could not receive that wheel.' : res.floorMessage);
    }
    _reload();
    final serial = res.data?['serial_no']?.toString() ?? code.trim();
    return (ok: true, message: 'Received $serial — held for QA.');
  }

  Future<void> _scanTyped(String v) async {
    final code = v.trim();
    if (code.isEmpty || _busy) return;
    setState(() => _busy = true);
    final out = await _receive(code);
    if (!mounted) return;
    setState(() => _busy = false);
    _scanCtrl.clear();
    if (out.ok) {
      HapticFeedback.lightImpact();
      DplSnacks.success(context, out.message);
    } else {
      HapticFeedback.heavyImpact();
      DplSnacks.error(context, out.message);
    }
    _scanFocus.requestFocus();
  }

  Future<void> _scanWithCamera() async {
    await Navigator.of(context).push(MaterialPageRoute<int>(
      builder: (_) => LogisticsContinuousScanPage(title: 'Scan returned wheels', onCode: _receive),
    ));
    if (mounted) _reload();
  }

  Future<void> _addManual() async {
    final input = await showDialog<({int partId, int qty, String? note})>(
      context: context,
      builder: (_) => const _ManualLineDialog(),
    );
    if (input == null || !mounted) return;
    setState(() => _busy = true);
    final res = await ref
        .read(dplApiServiceProvider)
        .addReturnManualLine(widget.returnId, partId: input.partId, qty: input.qty, note: input.note);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.isError) {
      showFloorError(context, res, fallback: 'Could not add the line.');
      return;
    }
    _reload();
    DplSnacks.success(context, 'Added ${input.qty} wheel(s) without a label.');
  }

  Future<void> _remove(DplReturnLine l) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this line?'),
        content: Text(l.serialNo ?? '${l.customerPartNo ?? 'Part ${l.partId}'} × ${l.qty}'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DplColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final res = await ref.read(dplApiServiceProvider).removeReturnLine(widget.returnId, l.lineId);
    if (!mounted) return;
    if (res.isError) {
      showFloorError(context, res, fallback: 'Could not remove the line.');
      return;
    }
    _selected.remove(l.lineId);
    _reload();
  }

  Future<void> _decide(String disposition) async {
    if (_selected.isEmpty) return;
    final scrap = disposition == 'scrap';
    final n = _selected.length;
    final note = await askLogisticsNote(
      context,
      title: scrap ? 'Scrap $n line(s)?' : 'Restock $n line(s)?',
      message: scrap
          ? 'The labels are voided with this return number in the reason. This cannot be undone.'
          : 'The wheels become ordinary loose stock and can be packed again.',
      confirmLabel: scrap ? 'Scrap' : 'Restock',
      required: scrap,
      confirmColor: scrap ? DplColors.error : DplColors.success,
    );
    if (note == null || (scrap && note.isEmpty) || !mounted) return;
    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).decideReturn(
          widget.returnId,
          disposition: disposition,
          lineIds: _selected.toList()..sort(),
          note: note.isEmpty ? null : note,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.isError) {
      showFloorError(context, res, fallback: 'Could not record the decision.');
      return;
    }
    setState(_selected.clear);
    _reload();
    final labels = int.tryParse('${res.data?['labels_to_print'] ?? 0}') ?? 0;
    final decided = int.tryParse('${res.data?['decided'] ?? n}') ?? n;
    DplSnacks.success(context, scrap ? 'Scrapped $decided line(s).' : 'Restocked $decided line(s).');
    if (labels > 0) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.print_outlined, size: 36, color: DplColors.primary),
          title: Text('Print $labels new label${labels == 1 ? '' : 's'} for the manual lines'),
          content: Text(
            'These $labels wheel(s) came back without a label from this system, so they have no serial yet. '
            'Print $labels part label(s) from direct print before they are packed again.',
          ),
          actions: [FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))],
        ),
      );
    }
  }

  Future<void> _close() async {
    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).closeReturn(widget.returnId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.isError) {
      showFloorError(context, res, fallback: 'Could not close the return.');
      return;
    }
    _reload();
    ref.invalidate(customerReturnsProvider);
    DplSnacks.success(context, 'Return closed.');
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(customerReturnProvider(widget.returnId));
    final title = async.value?.data?.returnNo ?? 'Return';

    final body = async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => DplInlineErrorRetry(message: e.toString(), onRetry: _reload),
      data: (res) {
        if (res.isError || res.data == null) {
          return DplInlineErrorRetry(
            message: res.floorMessage.isEmpty ? 'Could not load the return.' : res.floorMessage,
            onRetry: _reload,
          );
        }
        return _content(res.data!);
      },
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(title: title),
      body: body,
    );
  }

  Widget _content(DplCustomerReturn r) {
    final perms = ref.watch(dplPermissionsProvider);
    final canReceive = r.isOpen && perms.can(DplPermission.returnsReceive);
    final canDecide = r.isOpen && perms.can(DplPermission.returnsDisposition);
    final pendingIds = r.lines.where((l) => l.isPending).map((l) => l.lineId).toSet();
    _selected.removeWhere((id) => !pendingIds.contains(id));

    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.all(DplSpacing.md),
              children: [
                ReturnHeaderCard(ret: r),
                if (canReceive) ...[
                  const SizedBox(height: DplSpacing.md),
                  _scanCard(),
                ],
                const SizedBox(height: DplSpacing.md),
                if (canDecide && pendingIds.isNotEmpty) _decisionBar(pendingIds),
                if (r.lines.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Nothing received yet.',
                        textAlign: TextAlign.center, style: TextStyle(color: DplColors.textSecondary)),
                  ),
                for (final l in r.lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: DplSpacing.sm),
                    child: ReturnLineTile(
                      line: l,
                      selected: _selected.contains(l.lineId),
                      onSelected: canDecide && l.isPending
                          ? (v) => setState(() => v ? _selected.add(l.lineId) : _selected.remove(l.lineId))
                          : null,
                      onRemove: canReceive && l.isPending && !_busy ? () => _remove(l) : null,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (canReceive)
          SafeArea(
            top: false,
            child: Container(
              color: Colors.white,
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: FilledButton.icon(
                onPressed: _busy ? null : _close,
                icon: const Icon(Icons.lock_outline, size: 18),
                label: Text(r.pending > 0 ? 'Close return (${r.pending} pending)' : 'Close return'),
              ),
            ),
          ),
      ],
    );
  }

  Widget _scanCard() {
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Receive wheels', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 10),
          TextField(
            controller: _scanCtrl,
            focusNode: _scanFocus,
            enabled: !_busy,
            autofocus: true,
            textInputAction: TextInputAction.done,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Scan, or type the serial',
              prefixIcon: Icon(Icons.qr_code_scanner_rounded),
              helperText: 'Our labels and adopted Ekatm labels. Each wheel goes on hold until QA decides.',
              helperMaxLines: 2,
            ),
            onSubmitted: _scanTyped,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _scanWithCamera,
                  icon: const Icon(Icons.photo_camera_outlined, size: 18),
                  label: const Text('Camera'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _addManual,
                  icon: const Icon(Icons.edit_note, size: 18),
                  label: const Text('Add manual line'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _decisionBar(Set<int> pendingIds) {
    final all = pendingIds.isNotEmpty && _selected.length == pendingIds.length;
    final n = _selected.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: DplSpacing.sm),
      child: DplCard(
        padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
        child: Row(
          children: [
            Checkbox(
              value: all ? true : (n == 0 ? false : null),
              tristate: true,
              onChanged: (_) => setState(() {
                if (all) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(pendingIds);
                }
              }),
            ),
            Expanded(child: Text(n == 0 ? 'Select pending lines' : '$n selected')),
            TextButton(
              onPressed: n == 0 || _busy ? null : () => _decide('scrap'),
              style: TextButton.styleFrom(foregroundColor: DplColors.error),
              child: const Text('Scrap'),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: n == 0 || _busy ? null : () => _decide('restock'),
              style: FilledButton.styleFrom(backgroundColor: DplColors.success),
              child: const Text('Restock'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Return number, status, reason and the pending / restocked / scrapped tally.
class ReturnHeaderCard extends StatelessWidget {
  const ReturnHeaderCard({super.key, required this.ret});

  final DplCustomerReturn ret;

  @override
  Widget build(BuildContext context) {
    final r = ret;
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(r.returnNo, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18))),
              DispositionPill(
                label: r.isOpen ? 'Open' : 'Closed',
                color: r.isOpen ? DplColors.warning : DplColors.neutral,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(r.reason),
          const SizedBox(height: 4),
          Text(
            [
              if (r.consigneeName != null) r.consigneeName!,
              if (r.referenceNo != null && r.referenceNo!.isNotEmpty) 'Ref ${r.referenceNo}',
              if (r.receivedAt != null) _dateTime.format(r.receivedAt!.toLocal()),
            ].join(' · '),
            style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            DplCountChip(label: 'Total', count: r.totalQty),
            DplCountChip(label: 'Pending', count: r.pending, color: DplColors.warning),
            DplCountChip(label: 'Restocked', count: r.restocked, color: DplColors.success),
            DplCountChip(label: 'Scrapped', count: r.scrapped, color: DplColors.error),
          ]),
        ],
      ),
    );
  }
}

/// A small coloured status pill.
class DispositionPill extends StatelessWidget {
  const DispositionPill({super.key, required this.label, required this.color});

  factory DispositionPill.forLine(DplReturnLine l) => switch (l.disposition) {
        'restocked' => DispositionPill(label: 'Restocked', color: DplColors.success),
        'scrapped' => DispositionPill(label: 'Scrapped', color: DplColors.error),
        _ => DispositionPill(label: 'Pending QA', color: DplColors.warning),
      };

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(DplRadius.pill),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 11.5)),
      );
}

/// One return line: kind, serial or part, original pallet, disposition.
class ReturnLineTile extends StatelessWidget {
  const ReturnLineTile({super.key, required this.line, this.selected = false, this.onSelected, this.onRemove});

  final DplReturnLine line;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l = line;
    final wheel = l.kind == 'wheel';
    final part = [
      if (l.customerPartNo != null && l.customerPartNo!.isNotEmpty) l.customerPartNo!,
      if (l.description != null && l.description!.isNotEmpty) l.description!,
    ].join(' · ');
    return DplCard(
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
      onTap: onSelected == null ? null : () => onSelected!(!selected),
      child: Row(
        children: [
          if (onSelected != null)
            Checkbox(value: selected, onChanged: (v) => onSelected!(v ?? false))
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Icon(wheel ? Icons.qr_code_2 : Icons.edit_note, color: DplColors.textSecondary),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        wheel ? (l.serialNo ?? 'Wheel') : (part.isEmpty ? 'Part ${l.partId}' : part),
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(wheel ? 'Wheel' : 'Manual × ${l.qty}',
                        style: TextStyle(fontSize: 11.5, color: DplColors.textSecondary)),
                  ],
                ),
                if (wheel && part.isNotEmpty)
                  Text(part, style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis),
                Text(
                  [
                    'From pallet ${l.originalPalletNo ?? '—'}',
                    if (l.note != null && l.note!.isNotEmpty) l.note!,
                    if (l.dispositionNote != null && l.dispositionNote!.isNotEmpty) 'QA: ${l.dispositionNote}',
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          DispositionPill.forLine(l),
          if (onRemove != null)
            IconButton(
              tooltip: 'Remove line',
              icon: Icon(Icons.delete_outline, color: DplColors.error),
              onPressed: onRemove,
            )
          else
            const SizedBox(width: 6),
        ],
      ),
    );
  }
}

/// Part + qty + note for Ekatm-era wheels that carry no label from this system.
class _ManualLineDialog extends ConsumerStatefulWidget {
  const _ManualLineDialog();

  @override
  ConsumerState<_ManualLineDialog> createState() => _ManualLineDialogState();
}

class _ManualLineDialogState extends ConsumerState<_ManualLineDialog> {
  final _search = TextEditingController();
  final _partId = TextEditingController();
  final _qty = TextEditingController(text: '1');
  final _note = TextEditingController();
  List<DplPart> _results = const [];
  String? _searchError;
  String? _picked;
  bool _searching = false;

  @override
  void dispose() {
    for (final c in [_search, _partId, _qty, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _find() async {
    final q = _search.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    // /returns/parts is open to anyone who can receive returns (dispatch
    // included); the part id can still be typed if the search is unavailable.
    final res = await ref.read(dplApiServiceProvider).searchReturnParts(q: q);
    if (!mounted) return;
    setState(() {
      _searching = false;
      if (res.isError) {
        _results = const [];
        _searchError = 'Part search is not available here — type the part id instead.';
      } else {
        _results = (res.data ?? const <DplPart>[]).take(6).toList();
        if (_results.isEmpty) _searchError = 'No part matches "$q".';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final partId = int.tryParse(_partId.text.trim());
    final qty = int.tryParse(_qty.text.trim());
    final ok = partId != null && partId > 0 && qty != null && qty > 0;
    return AlertDialog(
      title: const Text('Add manual line'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('For wheels that came back without one of our labels.',
                style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary)),
            const SizedBox(height: 10),
            TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _find(),
              decoration: InputDecoration(
                isDense: true,
                labelText: 'Find part',
                border: const OutlineInputBorder(),
                suffixIcon: _searching
                    ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2))
                    : IconButton(icon: const Icon(Icons.search), onPressed: _find),
              ),
            ),
            if (_searchError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_searchError!, style: TextStyle(fontSize: 12, color: DplColors.textSecondary)),
              ),
            for (final p in _results)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(p.partNumber.isEmpty ? p.description : p.partNumber),
                subtitle: Text([p.description, p.name].where((s) => s.isNotEmpty).join(' · ')),
                trailing: Text('#${p.id}'),
                onTap: () => setState(() {
                  _partId.text = '${p.id}';
                  _picked = p.partNumber.isEmpty ? p.description : p.partNumber;
                  _results = const [];
                }),
              ),
            const SizedBox(height: 10),
            TextField(
              controller: _partId,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() => _picked = null),
              decoration: InputDecoration(
                isDense: true,
                labelText: 'Part id',
                helperText: _picked,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _qty,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(isDense: true, labelText: 'Qty', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _note,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(isDense: true, labelText: 'Note (optional)', border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: ok
              ? () => Navigator.of(context).pop((
                    partId: partId,
                    qty: qty,
                    note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                  ))
              : null,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
