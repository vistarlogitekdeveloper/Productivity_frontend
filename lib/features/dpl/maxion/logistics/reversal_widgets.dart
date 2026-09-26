import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_logistics.dart';
import '../common/maxion_kit.dart';
import 'gate_pass_screen.dart' show LogisticsFriendlyEmpty;
import 'logistics_providers.dart';

/// Asks a manager to reverse a dispatched slip (§8.4).
///
/// The reason (at least 5 characters, as the server requires) is collected and
/// sent from inside the sheet, so a refusal (ALREADY_REQUESTED,
/// SHIPMENT_LEFT_PLANT) is shown where the operator is looking and the typed
/// reason survives a retry.
Future<void> showRequestReversalSheet(
  BuildContext context,
  WidgetRef ref, {
  required int slipId,
  required String slipNo,
}) async {
  if (!ref.read(dplPermissionsProvider).can(DplPermission.slipsReverse)) {
    DplSnacks.error(context, 'You are not allowed to request a reversal.');
    return;
  }
  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _RequestReversalSheet(slipId: slipId, slipNo: slipNo),
  );
  if (done == true && context.mounted) {
    DplSnacks.success(context, 'Reversal requested for $slipNo. A manager must approve it.');
    ref.invalidate(pendingReversalsProvider);
  }
}

class _RequestReversalSheet extends ConsumerStatefulWidget {
  const _RequestReversalSheet({required this.slipId, required this.slipNo});

  final int slipId;
  final String slipNo;

  @override
  ConsumerState<_RequestReversalSheet> createState() => _RequestReversalSheetState();
}

class _RequestReversalSheetState extends ConsumerState<_RequestReversalSheet> {
  final _reason = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _valid => _reason.text.trim().length >= 5;

  Future<void> _submit() async {
    if (!_valid) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final res = await ref.read(dplApiServiceProvider).requestReversal(widget.slipId, _reason.text.trim());
    if (!mounted) return;
    if (res.isError) {
      setState(() {
        _busy = false;
        _error = res.floorMessage.isEmpty ? 'Could not request the reversal.' : res.floorMessage;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 4, 18, MediaQuery.of(context).viewInsets.bottom + 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Reverse ${widget.slipNo}?', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 4),
          const Text(
            'Only before the truck leaves. A manager approves it; the wheels then come off the trip and '
            'the pallets go back to stock without a rack.',
            style: TextStyle(color: DplColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _reason,
            autofocus: true,
            enabled: !_busy,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Reason',
              hintText: 'e.g. Customer cancelled the schedule',
              helperText: 'At least 5 characters.',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: DplColors.error, fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _busy || !_valid ? null : _submit,
                  child: _busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Request reversal'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Asks for a note. Returns null when cancelled, '' when optional and left blank.
Future<String?> askLogisticsNote(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String? message,
  bool required = false,
  String hint = 'Note',
  Color? confirmColor,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NoteDialog(
      title: title,
      confirmLabel: confirmLabel,
      message: message,
      required: required,
      hint: hint,
      confirmColor: confirmColor,
    ),
  );
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({
    required this.title,
    required this.confirmLabel,
    required this.required,
    required this.hint,
    this.message,
    this.confirmColor,
  });

  final String title;
  final String confirmLabel;
  final String? message;
  final bool required;
  final String hint;
  final Color? confirmColor;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = !widget.required || _ctrl.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message != null) ...[
            Text(widget.message!),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: widget.required ? '${widget.hint} (required)' : '${widget.hint} (optional)',
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          style: widget.confirmColor == null ? null : FilledButton.styleFrom(backgroundColor: widget.confirmColor),
          onPressed: ok ? () => Navigator.of(context).pop(_ctrl.text.trim()) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Reversal requests waiting for a manager's decision (§8.4).
class DplPendingReversalsScreen extends ConsumerStatefulWidget {
  const DplPendingReversalsScreen({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  ConsumerState<DplPendingReversalsScreen> createState() => _DplPendingReversalsScreenState();
}

class _DplPendingReversalsScreenState extends ConsumerState<DplPendingReversalsScreen> {
  final Set<int> _busy = {};

  Future<void> _approve(DplSlipReversal r) async {
    final note = await askLogisticsNote(
      context,
      title: 'Approve reversal of ${r.slipNo}?',
      message: 'The slip is reversed, its wheels come off the trip and its pallets return to stock with no rack.',
      confirmLabel: 'Approve',
      confirmColor: DplColors.success,
    );
    if (note == null || !mounted) return;
    setState(() => _busy.add(r.slipId));
    final res = await ref.read(dplApiServiceProvider).decideReversal(r.slipId, approve: true, note: note.isEmpty ? null : note);
    if (!mounted) return;
    setState(() => _busy.remove(r.slipId));
    if (res.isError || res.data == null) {
      showFloorError(context, res, fallback: 'Could not approve the reversal.');
      return;
    }
    ref.invalidate(pendingReversalsProvider);
    final out = res.data!;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.undo_rounded, color: DplColors.success, size: 36),
        title: Text('${out.slipNo.isEmpty ? r.slipNo : out.slipNo} reversed'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Wheels returned: ${out.wheelsReturned ?? 0}', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Pallets returned: ${out.palletsReturned.length}', style: const TextStyle(fontWeight: FontWeight.w700)),
            if (out.palletsReturned.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(out.palletsReturned.join(', '), style: const TextStyle(fontSize: 12.5)),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: DplColors.warningBg, borderRadius: BorderRadius.circular(DplRadius.sm)),
              child: const Text(
                'These pallets now have no rack. Put them away again — until then they show as "not put away" in stock by location.',
                style: TextStyle(color: DplColors.warning, fontWeight: FontWeight.w700, fontSize: 12.5),
              ),
            ),
          ],
        ),
        actions: [FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _reject(DplSlipReversal r) async {
    final note = await askLogisticsNote(
      context,
      title: 'Reject reversal of ${r.slipNo}?',
      message: 'The slip stays dispatched. Say why, so the requester knows what to do next.',
      confirmLabel: 'Reject',
      required: true,
      confirmColor: DplColors.error,
    );
    if (note == null || note.isEmpty || !mounted) return;
    setState(() => _busy.add(r.slipId));
    final res = await ref.read(dplApiServiceProvider).decideReversal(r.slipId, approve: false, note: note);
    if (!mounted) return;
    setState(() => _busy.remove(r.slipId));
    if (res.isError) {
      showFloorError(context, res, fallback: 'Could not reject the reversal.');
      return;
    }
    ref.invalidate(pendingReversalsProvider);
    DplSnacks.success(context, 'Reversal of ${r.slipNo} rejected.');
  }

  @override
  Widget build(BuildContext context) {
    final allowed = ref.watch(dplPermissionsProvider).can(DplPermission.slipsReverseApprove);
    final Widget body;
    if (!allowed) {
      body = const LogisticsFriendlyEmpty(
        icon: Icons.lock_outline,
        title: 'Managers only',
        message: 'Approving a shipment reversal needs the slips.reverse_approve permission.',
      );
    } else {
      final async = ref.watch(pendingReversalsProvider);
      void retry() => ref.invalidate(pendingReversalsProvider);
      body = async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => DplInlineErrorRetry(message: e.toString(), onRetry: retry),
        data: (res) {
          if (res.isError) {
            return DplInlineErrorRetry(
              message: res.floorMessage.isEmpty ? 'Could not load reversals.' : res.floorMessage,
              onRetry: retry,
            );
          }
          final items = res.data ?? const <DplSlipReversal>[];
          if (items.isEmpty) {
            return LogisticsFriendlyEmpty(
              icon: Icons.task_alt,
              title: 'Nothing waiting',
              message: 'No shipment reversal is waiting for a decision.',
              onRetry: retry,
            );
          }
          return RefreshIndicator(
            onRefresh: () async => retry(),
            child: ListView.separated(
              padding: const EdgeInsets.all(DplSpacing.md),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: DplSpacing.md),
              itemBuilder: (_, i) => _card(items[i]),
            ),
          );
        },
      );
    }

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(title: 'Shipment reversals'),
      body: body,
    );
  }

  Widget _card(DplSlipReversal r) {
    final busy = _busy.contains(r.slipId);
    final at = r.requestedAt == null ? '' : DateFormat('d MMM, HH:mm').format(r.requestedAt!.toLocal());
    return DplCard(
      accentColor: DplColors.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(r.slipNo, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ),
              if (r.invoiceNo != null && r.invoiceNo!.isNotEmpty)
                Text('Invoice ${r.invoiceNo}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Requested by ${r.requestedBy ?? 'someone'}${at.isEmpty ? '' : ' · $at'}',
            style: const TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(r.reason ?? '—', style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : () => _reject(r),
                  style: OutlinedButton.styleFrom(foregroundColor: DplColors.error),
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('Reject'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy ? null : () => _approve(r),
                  style: FilledButton.styleFrom(backgroundColor: DplColors.success),
                  icon: busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check, size: 18),
                  label: const Text('Approve'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
