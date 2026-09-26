import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_dispatch_slip.dart';
import '../providers/dispatch_slips_provider.dart';
import '../providers/production_summary_provider.dart';

/// Which approval action to perform — drives the title, button label,
/// and which API method gets called.
enum DispatchSlipApprovalAction { qaApprove, qaReject, pdiApprove, pdiReject }

extension on DispatchSlipApprovalAction {
  bool get isReject =>
      this == DispatchSlipApprovalAction.qaReject ||
      this == DispatchSlipApprovalAction.pdiReject;
  String get title {
    switch (this) {
      case DispatchSlipApprovalAction.qaApprove:
        return 'Approve QA';
      case DispatchSlipApprovalAction.qaReject:
        return 'Reject (QA)';
      case DispatchSlipApprovalAction.pdiApprove:
        return 'Approve PDI';
      case DispatchSlipApprovalAction.pdiReject:
        return 'Reject (PDI)';
    }
  }

  String get cta {
    switch (this) {
      case DispatchSlipApprovalAction.qaApprove:
      case DispatchSlipApprovalAction.pdiApprove:
        return 'Approve';
      case DispatchSlipApprovalAction.qaReject:
      case DispatchSlipApprovalAction.pdiReject:
        return 'Reject';
    }
  }

  String get successMessage {
    switch (this) {
      case DispatchSlipApprovalAction.qaApprove:
        return 'QA approved — slip moved to PDI.';
      case DispatchSlipApprovalAction.qaReject:
        return 'Slip rejected by QA.';
      case DispatchSlipApprovalAction.pdiApprove:
        return 'PDI approved — slip ready to print.';
      case DispatchSlipApprovalAction.pdiReject:
        return 'Slip rejected by PDI.';
    }
  }
}

/// Shared bottom sheet for QA-approve / QA-reject / PDI-approve /
/// PDI-reject. Approve actions show an optional remarks field;
/// reject actions require a reason. On success it invalidates the
/// dispatch slip list + production summary so badges update without a
/// manual refresh and returns the updated slip to the caller.
class DispatchSlipActionSheet extends ConsumerStatefulWidget {
  final DplDispatchSlip slip;
  final DispatchSlipApprovalAction action;

  const DispatchSlipActionSheet({
    super.key,
    required this.slip,
    required this.action,
  });

  static Future<DplDispatchSlip?> show(
    BuildContext context, {
    required DplDispatchSlip slip,
    required DispatchSlipApprovalAction action,
  }) {
    return showModalBottomSheet<DplDispatchSlip?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DispatchSlipActionSheet(slip: slip, action: action),
    );
  }

  @override
  ConsumerState<DispatchSlipActionSheet> createState() =>
      _DispatchSlipActionSheetState();
}

class _DispatchSlipActionSheetState
    extends ConsumerState<DispatchSlipActionSheet> {
  final _formKey = GlobalKey<FormState>();
  final _textCtrl = TextEditingController();
  bool _submitting = false;
  String? _serverError;

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _serverError = null;
    });

    final svc = ref.read(dplApiServiceProvider);
    final text = _textCtrl.text.trim();
    final id = widget.slip.id;
    late final dynamic res;
    switch (widget.action) {
      case DispatchSlipApprovalAction.qaApprove:
        res = await svc.qaApproveDispatchSlip(id, remarks: text);
        break;
      case DispatchSlipApprovalAction.qaReject:
        res = await svc.qaRejectDispatchSlip(id, reason: text);
        break;
      case DispatchSlipApprovalAction.pdiApprove:
        res = await svc.pdiApproveDispatchSlip(id, remarks: text);
        break;
      case DispatchSlipApprovalAction.pdiReject:
        res = await svc.pdiRejectDispatchSlip(id, reason: text);
        break;
    }

    if (!mounted) return;

    if (res.isError) {
      setState(() {
        _submitting = false;
        _serverError = res.error ?? 'Action failed.';
      });
      return;
    }

    ref.invalidate(dplDispatchSlipsProvider);
    ref.invalidate(dplDispatchSlipDetailProvider(id));
    ref.invalidate(dplProductionSummaryProvider);
    ref.invalidate(dplBucketSlipCountsProvider);

    DplSnacks.success(context, widget.action.successMessage);
    Navigator.of(context).pop(res.data as DplDispatchSlip);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final isReject = widget.action.isReject;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Container(
        decoration: BoxDecoration(
          color: DplColors.cardBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: DplShadows.sheet,
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: DplColors.divider,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '${widget.action.title} — ${widget.slip.slipNo}',
                    style: DplText.h3(),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${widget.slip.machineLabel} • ${widget.slip.partLabel}',
                    style: TextStyle(
                      color: DplColors.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _textCtrl,
                    autofocus: true,
                    maxLines: 3,
                    maxLength: 280,
                    decoration: InputDecoration(
                      labelText: isReject ? 'Reason (required)' : 'Remarks',
                      hintText: isReject
                          ? 'Visual defect on sample, contamination, etc.'
                          : 'Optional notes',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    validator: isReject
                        ? (v) {
                            final trimmed = (v ?? '').trim();
                            if (trimmed.isEmpty) {
                              return 'A reason is required for rejection.';
                            }
                            if (trimmed.length < 4) {
                              return 'Please write a clearer reason.';
                            }
                            return null;
                          }
                        : null,
                  ),
                  if (_serverError != null) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: DplColors.errorBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: DplColors.error),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 18,
                            color: DplColors.error,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _serverError!,
                              style: TextStyle(
                                color: DplColors.error,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _submitting
                              ? null
                              : () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: FilledButton.icon(
                          style: isReject
                              ? FilledButton.styleFrom(
                                  backgroundColor: DplColors.error,
                                  foregroundColor: Colors.white,
                                )
                              : null,
                          onPressed: _submitting ? null : _submit,
                          icon: _submitting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Icon(
                                  isReject
                                      ? Icons.cancel_outlined
                                      : Icons.check_circle_outline,
                                ),
                          label:
                              Text(_submitting ? 'Submitting…' : widget.action.cta),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Confirms physical dispatch (Dispatch role). Returns the updated slip.
class MarkDispatchedConfirmDialog {
  static Future<DplDispatchSlip?> show(
    BuildContext context,
    WidgetRef ref, {
    required DplDispatchSlip slip,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text('Mark as dispatched?'),
        content: Text(
          'This subtracts ${slip.qty} from the available qty on '
          '${slip.machineLabel}. The slip becomes terminal.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Mark dispatched'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return null;

    final res = await ref
        .read(dplApiServiceProvider)
        .markDispatchSlipDispatched(slip.id);
    if (!context.mounted) return null;

    if (res.isError) {
      DplSnacks.error(context, res.error ?? 'Failed to mark dispatched.');
      return null;
    }

    ref.invalidate(dplDispatchSlipsProvider);
    ref.invalidate(dplDispatchSlipDetailProvider(slip.id));
    ref.invalidate(dplProductionSummaryProvider);
    ref.invalidate(dplBucketSlipCountsProvider);
    DplSnacks.success(context, 'Slip ${slip.slipNo} dispatched.');
    return res.data;
  }
}
