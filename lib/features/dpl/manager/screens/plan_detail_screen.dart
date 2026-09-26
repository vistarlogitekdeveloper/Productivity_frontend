import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../../../core/widgets/shimmer_skeleton.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_constants.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_pauses_panel.dart';
import '../../core/widgets/shift_chip.dart';
import '../../models/dpl_shift.dart';
import '../providers/dpl_plan_pauses_provider.dart';
import '../providers/dpl_shifts_provider.dart';
import '../../models/dpl_part.dart';
import '../../models/dpl_production_plan.dart';
import '../../models/dpl_production_plan_item.dart';
import '../../models/dpl_supervisor_today.dart';
import '../providers/dpl_plan_detail_provider.dart';
import '../providers/dpl_plan_list_provider.dart';
import '../providers/dpl_viewer_only_provider.dart';
import '../../supervisor/widgets/live_timer_text.dart';
import '../widgets/dpl_manager_footer.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_retry.dart';
import '../widgets/part_search_field.dart';
import '../widgets/plan_item_tile.dart';
import '../widgets/status_badge.dart';

enum _PlanMenu { edit, changeStatus, delete }

class DplPlanDetailScreen extends ConsumerWidget {
  final int planId;

  const DplPlanDetailScreen({super.key, required this.planId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(dplPlanDetailProvider(planId));
    final viewerOnly = ref.watch(dplViewerOnlyProvider);

    return Scaffold(
      appBar: DplAppBar(
        title: 'Plan Detail',
        actions: [
          // Plan-level mutating menu (Edit / Change status / Delete) is
          // stripped entirely for DPL Customer — they see the plan as a
          // read-only document.
          if (!viewerOnly)
            detail.maybeWhen(
              data: (res) {
                if (res.isError || res.data == null) {
                  return const SizedBox.shrink();
                }
                return PopupMenuButton<_PlanMenu>(
                  onSelected: (action) =>
                      _handleMenu(context, ref, res.data!, action),
                  itemBuilder: (_) => [
                    if (DplPlanStatus.isEditable(res.data!.status))
                      const PopupMenuItem(
                        value: _PlanMenu.edit,
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Edit header'),
                        ),
                      ),
                    const PopupMenuItem(
                      value: _PlanMenu.changeStatus,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.swap_horiz_outlined),
                        title: Text('Change status'),
                      ),
                    ),
                    // Plan-level Delete is shown only when nothing on
                    // the plan has been started yet. Once any item is
                    // in progress or completed, the manager has to use
                    // Change status / Carry forward instead.
                    if (res.data!.isDeletable)
                      PopupMenuItem(
                        value: _PlanMenu.delete,
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.delete_outline,
                            color: VistarPalette.bad,
                          ),
                          title: Text(
                            'Delete plan',
                            style: TextStyle(color: VistarPalette.bad),
                          ),
                        ),
                      ),
                  ],
                );
              },
              orElse: () => const SizedBox.shrink(),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(dplPlanDetailProvider(planId));
          await ref.read(dplPlanDetailProvider(planId).future);
        },
        child: detail.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: SkeletonList(count: 5),
          ),
          error: (e, _) => ListView(
            children: [
              DplErrorRetry(
                message: e.toString(),
                onRetry: () =>
                    ref.invalidate(dplPlanDetailProvider(planId)),
              ),
            ],
          ),
          data: (res) {
            if (res.isError) {
              return ListView(
                children: [
                  DplErrorRetry(
                    message: res.error ?? 'Failed to load plan.',
                    onRetry: () =>
                        ref.invalidate(dplPlanDetailProvider(planId)),
                  ),
                ],
              );
            }
            final plan = res.data!;
            return _PlanBody(plan: plan);
          },
        ),
      ),
      bottomNavigationBar: const DplManagerFooter(),
    );
  }

  Future<void> _handleMenu(
    BuildContext context,
    WidgetRef ref,
    DplProductionPlan plan,
    _PlanMenu action,
  ) async {
    switch (action) {
      case _PlanMenu.edit:
        await _showEditHeader(context, ref, plan);
        break;
      case _PlanMenu.changeStatus:
        await _showChangeStatus(context, ref, plan);
        break;
      case _PlanMenu.delete:
        await _confirmDelete(context, ref, plan);
        break;
    }
  }

  Future<void> _showChangeStatus(
    BuildContext context,
    WidgetRef ref,
    DplProductionPlan plan,
  ) async {
    final result = await showModalBottomSheet<_ChangeStatusResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ChangeStatusSheet(currentStatus: plan.status),
    );
    if (result == null) return;

    final res = await ref.read(dplApiServiceProvider).changePlanStatus(
          plan.id,
          status: result.status,
          reason: result.reason,
        );
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to change status.');
      return;
    }
    DplSnack.success(
      context,
      'Plan moved to ${DplPlanStatus.label(result.status)}.',
    );
    ref.invalidate(dplPlanDetailProvider(planId));
    ref.invalidate(dplPlanListProvider);
  }


  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    DplProductionPlan plan,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Plan?'),
        content: Text(
          'Delete the draft plan for ${plan.machineName.isEmpty ? "Machine #${plan.machineId}" : plan.machineName}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: VistarPalette.badSolid),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final res = await ref.read(dplApiServiceProvider).deletePlan(plan.id);
    if (!context.mounted) return;

    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to delete plan.');
      return;
    }
    DplSnack.success(context, 'Plan deleted.');
    ref.invalidate(dplPlanListProvider);
    if (context.canPop()) context.pop();
  }

  Future<void> _showEditHeader(
    BuildContext context,
    WidgetRef ref,
    DplProductionPlan plan,
  ) async {
    final releasedCtrl =
        TextEditingController(text: plan.planReleasedBy);
    final approvedCtrl =
        TextEditingController(text: plan.planApprovedBy);
    final remarksCtrl = TextEditingController(text: plan.remarks ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Edit Plan Header'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: releasedCtrl,
                decoration:
                    const InputDecoration(labelText: 'Plan Released By'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: approvedCtrl,
                decoration:
                    const InputDecoration(labelText: 'Plan Approved By'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: remarksCtrl,
                decoration: const InputDecoration(labelText: 'Remarks'),
                maxLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (saved != true) return;

    final res = await ref.read(dplApiServiceProvider).updatePlan(
          plan.id,
          DplUpdatePlanRequest(
            planReleasedBy: releasedCtrl.text.trim(),
            planApprovedBy: approvedCtrl.text.trim(),
            remarks: remarksCtrl.text.trim(),
          ),
        );

    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to update plan.');
      return;
    }
    DplSnack.success(context, 'Plan updated.');
    ref.invalidate(dplPlanDetailProvider(planId));
  }
}

class _PlanBody extends ConsumerWidget {
  final DplProductionPlan plan;
  const _PlanBody({required this.plan});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fmt = NumberFormat.decimalPattern();
    final dateFmt = DateFormat('EEEE, dd MMM yyyy');
    final pct = (plan.completionPct * 100).round();
    // DPL Customer is a viewer — collapse it into the existing
    // `readOnly` / `canEdit` flags so every downstream button
    // (Add item, item tap, long-press, status menu, carry forward,
    // delete) auto-disables without per-call gating.
    final viewerOnly = ref.watch(dplViewerOnlyProvider);
    final canEdit =
        !viewerOnly && DplPlanStatus.isEditable(plan.status);
    final readOnly =
        viewerOnly || DplPlanStatus.isReadOnly(plan.status);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: DplColors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      plan.machineName.isEmpty
                          ? 'Machine #${plan.machineId}'
                          : plan.machineName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  DplStatusBadge(status: plan.status),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                dateFmt.format(plan.planDate),
                style: TextStyle(color: DplColors.textSecondary),
              ),
              if (plan.shiftLabel.isNotEmpty) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DplShiftChip(label: plan.shiftLabel),
                ),
              ],
              const SizedBox(height: 12),
              _kvRow('Supervisor', plan.supervisorName),
              _kvRow('Released by', plan.planReleasedBy),
              _kvRow('Approved by', plan.planApprovedBy),
              if ((plan.remarks ?? '').isNotEmpty)
                _kvRow('Remarks', plan.remarks!),
              const SizedBox(height: 12),
              Row(
                children: [
                  _bigKv('Plan', fmt.format(plan.effectiveTotalPlanQty)),
                  const SizedBox(width: 16),
                  _bigKv('Actual', fmt.format(plan.effectiveTotalActualQty)),
                  const SizedBox(width: 16),
                  _bigKv('Completion', '$pct%'),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: plan.completionPct,
                  minHeight: 6,
                  backgroundColor: VistarPalette.surface3,
                ),
              ),
            ],
          ),
        ),
        if (plan.activeDowntime != null) ...[
          const SizedBox(height: 12),
          _PlanActiveDowntimeCard(downtime: plan.activeDowntime!),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            const Text(
              'Plan Items',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            if (canEdit)
              FilledButton.tonalIcon(
                icon: const Icon(Icons.add),
                label: const Text('Add item'),
                onPressed: () => _addItem(context, ref, plan),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (plan.items.isEmpty)
          const DplEmptyState(
            icon: Icons.list_alt_outlined,
            title: 'No items yet',
            message: 'Add items to this plan to track production.',
          )
        else
          // In-progress first, pending sorted by plan_no, completed last.
          ...plan.items.sortedForExecution().map(
            (i) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: DplPlanItemTile(
                item: i,
                // Only PENDING items are tap-to-edit. Once an item is
                // in-progress or completed, the manager has to use
                // the ⋮ menu (Change status / Carry forward / Delete)
                // — direct edits at that point are usually mistakes.
                onTap: (readOnly || i.status != 'pending')
                    ? null
                    : () => _editItem(context, ref, plan, i),
                onLongPress: (readOnly || i.status != 'pending')
                    ? null
                    : () => _confirmDeleteItem(context, ref, plan, i),
                onEdit: (readOnly || i.status != 'pending')
                    ? null
                    : () => _editItem(context, ref, plan, i),
                onChangeStatus: readOnly
                    ? null
                    : () => _showChangeItemStatus(context, ref, plan, i),
                onCarryForward: readOnly
                    ? null
                    : () => _showCarryForward(context, ref, plan, i),
                onDelete: (readOnly || i.status != 'pending')
                    ? null
                    : () => _confirmDeleteItem(context, ref, plan, i),
              ),
            ),
          ),
        const SizedBox(height: 22),
        const Text(
          'Pauses',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        _ManagerPausesSection(planId: plan.id),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _kvRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                color: DplColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bigKv(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: DplColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }

  Future<void> _addItem(
    BuildContext context,
    WidgetRef ref,
    DplProductionPlan plan,
  ) async {
    final item = await showDialog<DplProductionPlanItem>(
      context: context,
      builder: (_) => _PlanItemDialog(
        title: 'Add item',
        defaultPlanNo: plan.items.length + 1,
        defaultSequence: plan.items.length + 1,
        machineName: plan.machineName,
      ),
    );
    if (item == null) return;

    final res = await ref
        .read(dplApiServiceProvider)
        .addPlanItem(plan.id, item);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to add item.');
      return;
    }
    DplSnack.success(context, 'Item added.');
    ref.invalidate(dplPlanDetailProvider(plan.id));
  }

  Future<void> _editItem(
    BuildContext context,
    WidgetRef ref,
    DplProductionPlan plan,
    DplProductionPlanItem existing,
  ) async {
    final item = await showDialog<DplProductionPlanItem>(
      context: context,
      builder: (_) => _PlanItemDialog(
        title: 'Edit item',
        existing: existing,
        defaultPlanNo: existing.planNo,
        defaultSequence: existing.sequence,
        machineName: plan.machineName,
      ),
    );
    if (item == null) return;

    if (DplPlanStatus.inProgress == plan.status) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Plan in progress'),
          content: const Text(
              'This plan is in progress. Editing items may affect supervisor flow. Continue?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    final res = await ref
        .read(dplApiServiceProvider)
        .updatePlanItem(plan.id, existing.id, item);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to update item.');
      return;
    }
    DplSnack.success(context, 'Item updated.');
    ref.invalidate(dplPlanDetailProvider(plan.id));
  }

  Future<void> _showCarryForward(
    BuildContext context,
    WidgetRef ref,
    DplProductionPlan plan,
    DplProductionPlanItem item,
  ) async {
    final result = await showModalBottomSheet<_CarryForwardResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CarryForwardSheet(item: item),
    );
    if (result == null) return;

    // Pure-move shortcut: when the source has produced nothing yet AND
    // the user is carrying the full plan qty, this is really a "move
    // to shift" — not a split. Reassign the existing row's shift_id
    // via the standard item-update endpoint instead of creating a
    // duplicate that would double the plan total. Single API call,
    // atomic, no orphan rows possible.
    final isPureMove =
        item.actualQty == 0 && result.planQty == item.planQty;
    if (isPureMove) {
      final res = await ref.read(dplApiServiceProvider).updatePlanItem(
            plan.id,
            item.id,
            item.copyWith(shiftId: result.shiftId),
          );
      if (!context.mounted) return;
      if (res.isError) {
        DplSnack.error(
          context,
          res.error ?? 'Failed to move item to the next shift.',
        );
        return;
      }
      DplSnack.success(context, 'Item moved to the next shift.');
      ref.invalidate(dplPlanDetailProvider(plan.id));
      return;
    }

    final res = await ref.read(dplApiServiceProvider).carryForwardItem(
          plan.id,
          item.id,
          shiftId: result.shiftId,
          planQty: result.planQty,
          completeSource: result.completeSource,
        );
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(
        context,
        res.error ?? 'Failed to carry item forward.',
      );
      return;
    }
    DplSnack.success(
      context,
      'Carried ${result.planQty} to the next shift.',
    );
    ref.invalidate(dplPlanDetailProvider(plan.id));
  }

  Future<void> _showChangeItemStatus(
    BuildContext context,
    WidgetRef ref,
    DplProductionPlan plan,
    DplProductionPlanItem item,
  ) async {
    final result = await showModalBottomSheet<_ChangeStatusResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ChangeItemStatusSheet(item: item),
    );
    if (result == null) return;

    final res = await ref
        .read(dplApiServiceProvider)
        .changePlanItemStatus(
          plan.id,
          item.id,
          status: result.status,
          reason: result.reason,
        );
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to change item status.');
      return;
    }
    DplSnack.success(
      context,
      'Item moved to ${_humanItemStatus(result.status)}.',
    );
    ref.invalidate(dplPlanDetailProvider(plan.id));
  }

  Future<void> _confirmDeleteItem(
    BuildContext context,
    WidgetRef ref,
    DplProductionPlan plan,
    DplProductionPlanItem item,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete item?'),
        content: Text('Remove item #${item.planNo} from this plan?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: VistarPalette.badSolid,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final res = await ref
        .read(dplApiServiceProvider)
        .deletePlanItem(plan.id, item.id);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to delete item.');
      return;
    }
    DplSnack.success(context, 'Item deleted.');
    ref.invalidate(dplPlanDetailProvider(plan.id));
  }
}

class _PlanItemDialog extends ConsumerStatefulWidget {
  final String title;
  final DplProductionPlanItem? existing;
  final int defaultPlanNo;
  final int defaultSequence;
  /// Optional — scopes the part autocomplete to a specific machine via
  /// the backend's `?machine_name=` query param.
  final String? machineName;

  const _PlanItemDialog({
    required this.title,
    required this.defaultPlanNo,
    required this.defaultSequence,
    this.existing,
    this.machineName,
  });

  @override
  ConsumerState<_PlanItemDialog> createState() => _PlanItemDialogState();
}

class _PlanItemDialogState extends ConsumerState<_PlanItemDialog> {
  late final TextEditingController _planNoCtrl;
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _seqCtrl;
  late final TextEditingController _remarksCtrl;
  DplPart? _selectedPart;
  int? _shiftId;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _planNoCtrl =
        TextEditingController(text: (e?.planNo ?? widget.defaultPlanNo).toString());
    _qtyCtrl =
        TextEditingController(text: (e?.planQty ?? 0).toString());
    _seqCtrl = TextEditingController(
        text: (e?.sequence ?? widget.defaultSequence).toString());
    _remarksCtrl = TextEditingController(text: e?.remarks ?? '');
    _shiftId = e?.shiftId;
    if (e != null && e.partId > 0) {
      _selectedPart = DplPart(
        id: e.partId,
        partNumber: e.partNumber,
        description: e.partDescription,
        name: e.partName,
      );
    }
  }

  @override
  void dispose() {
    _planNoCtrl.dispose();
    _qtyCtrl.dispose();
    _seqCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final partId = _selectedPart?.id ?? 0;
    final planNo = int.tryParse(_planNoCtrl.text.trim()) ?? 0;
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    final seq = int.tryParse(_seqCtrl.text.trim()) ?? 0;

    if (partId <= 0) {
      setState(() => _error = 'Please select a part.');
      return;
    }
    if (planNo <= 0) {
      setState(() => _error = 'Plan number must be greater than 0.');
      return;
    }
    if (qty <= 0) {
      setState(() => _error = 'Plan qty must be greater than 0.');
      return;
    }

    Navigator.of(context).pop(
      DplProductionPlanItem(
        id: widget.existing?.id ?? 0,
        planNo: planNo,
        partId: partId,
        partNumber: _selectedPart?.partNumber ?? '',
        partDescription: _selectedPart?.description ?? '',
        partName: _selectedPart?.name ?? '',
        planQty: qty,
        sequence: seq,
        shiftId: _shiftId,
        remarks: _remarksCtrl.text.trim().isEmpty
            ? null
            : _remarksCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: VistarPalette.badBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: VistarPalette.badLine),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: VistarPalette.badInk,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _planNoCtrl,
                      keyboardType: TextInputType.number,
                      decoration:
                          const InputDecoration(labelText: 'Plan No'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _seqCtrl,
                      keyboardType: TextInputType.number,
                      decoration:
                          const InputDecoration(labelText: 'Sequence'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              DplPartSearchField(
                machineName: widget.machineName,
                initialPart: _selectedPart,
                onChanged: (p) => setState(() => _selectedPart = p),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _qtyCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Plan Qty'),
              ),
              const SizedBox(height: 10),
              _ShiftDropdown(
                value: _shiftId,
                onChanged: (v) => setState(() => _shiftId = v),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _remarksCtrl,
                decoration:
                    const InputDecoration(labelText: 'Remarks (optional)'),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.existing == null ? 'Add' : 'Save'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Pauses section (manager-side, read-only)
// ---------------------------------------------------------------------------

class _ManagerPausesSection extends ConsumerWidget {
  final int planId;
  const _ManagerPausesSection({required this.planId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dplManagerPlanPausesProvider(planId));
    void retry() => ref.invalidate(dplManagerPlanPausesProvider(planId));

    return async.when(
      loading: () => const DplPausesPanel(
        pauses: [],
        loading: true,
        onRetry: _noop,
      ),
      error: (e, _) => DplPausesPanel(
        pauses: const [],
        error: e.toString(),
        onRetry: retry,
      ),
      data: (res) {
        if (res.isError) {
          return DplPausesPanel(
            pauses: const [],
            error: res.error ?? 'Failed to load pauses.',
            onRetry: retry,
          );
        }
        return DplPausesPanel(
          pauses: res.data ?? const [],
          onRetry: retry,
        );
      },
    );
  }
}

void _noop() {}

// ---------------------------------------------------------------------------
// Change Status sheet
// ---------------------------------------------------------------------------

class _ChangeStatusResult {
  final String status;
  final String reason;
  const _ChangeStatusResult(this.status, this.reason);
}

class _ChangeStatusSheet extends StatefulWidget {
  final String currentStatus;
  const _ChangeStatusSheet({required this.currentStatus});

  @override
  State<_ChangeStatusSheet> createState() => _ChangeStatusSheetState();
}

class _ChangeStatusSheetState extends State<_ChangeStatusSheet> {
  late String _status;
  final _reasonCtrl = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _status = widget.currentStatus;
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _reasonCtrl.text.trim();
    if (reason.isEmpty) {
      setState(() => _error = 'Reason is required.');
      return;
    }
    if (_status == widget.currentStatus) {
      setState(() => _error =
          'Pick a different status, or this is a no-op.');
      return;
    }
    Navigator.of(context).pop(_ChangeStatusResult(_status, reason));
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: 16 + media.viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: DplColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Text(
            'Change Plan Status',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            'Currently ${DplPlanStatus.label(widget.currentStatus)}. '
            'Any status transition is allowed; both fields are required.',
            style: TextStyle(color: DplColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 14),
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: VistarPalette.badBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: VistarPalette.badLine),
              ),
              child: Text(
                _error!,
                style: TextStyle(
                  color: VistarPalette.badInk,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          DropdownButtonFormField<String>(
            initialValue: _status,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'New Status',
              prefixIcon: Icon(Icons.swap_horiz_outlined),
            ),
            items: [
              for (final s in DplPlanStatus.all)
                DropdownMenuItem(
                  value: s,
                  child: Text(DplPlanStatus.label(s)),
                ),
            ],
            onChanged: (v) => setState(() => _status = v ?? _status),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _reasonCtrl,
            maxLines: 3,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Reason (required)',
              hintText: 'Why is the status changing? Logged to audit.',
              prefixIcon: Icon(Icons.notes_outlined),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Apply'),
                    onPressed: _submit,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shift dropdown for the Add/Edit Item dialog
// ---------------------------------------------------------------------------

class _ShiftDropdown extends ConsumerWidget {
  final int? value;
  final ValueChanged<int?> onChanged;

  const _ShiftDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dplShiftsProvider);
    final loading = async.isLoading;
    final shifts = async.asData?.value.data ?? const <DplShift>[];

    // Keep the previously-stored shift visible even if it's been
    // deactivated in masters, so editing a started item doesn't
    // silently drop its shift assignment.
    final ids = <int>{
      for (final s in shifts) s.id,
      ?value,
    };

    return DropdownButtonFormField<int?>(
      initialValue: ids.contains(value) ? value : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Shift',
        prefixIcon: const Icon(Icons.access_time),
        helperText: loading
            ? 'Loading shifts…'
            : 'Optional. If left blank, the supervisor\'s first START '
                'auto-tags the shift.',
      ),
      items: [
        const DropdownMenuItem<int?>(
          value: null,
          child: Text('Auto (set on first START)'),
        ),
        for (final s in shifts)
          DropdownMenuItem<int?>(
            value: s.id,
            child: Text(
              '${s.name}'
              '${s.windowLabel.isEmpty ? '' : '  •  ${s.windowLabel}'}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        // Stale fallback so the current selection is never lost.
        if (value != null &&
            !shifts.any((s) => s.id == value))
          DropdownMenuItem<int?>(
            value: value,
            child: Text('Shift #$value (inactive)'),
          ),
      ],
      onChanged: loading ? null : onChanged,
    );
  }
}

// ---------------------------------------------------------------------------
// Change Item Status sheet
// ---------------------------------------------------------------------------

/// Maps a raw item status enum to a human label. Mirrors
/// `DplPlanStatus.label` but for item-level statuses (only three are
/// valid for items).
String _humanItemStatus(String status) {
  switch (status) {
    case 'pending':
      return 'Pending';
    case 'in_progress':
      return 'In Progress';
    case 'completed':
      return 'Completed';
    default:
      if (status.isEmpty) return '-';
      return status[0].toUpperCase() + status.substring(1);
  }
}

class _ChangeItemStatusSheet extends StatefulWidget {
  final DplProductionPlanItem item;
  const _ChangeItemStatusSheet({required this.item});

  @override
  State<_ChangeItemStatusSheet> createState() =>
      _ChangeItemStatusSheetState();
}

class _ChangeItemStatusSheetState extends State<_ChangeItemStatusSheet> {
  static const _statuses = ['pending', 'in_progress', 'completed'];

  late String _status;
  final _reasonCtrl = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _status = widget.item.status;
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _reasonCtrl.text.trim();
    if (reason.isEmpty) {
      setState(() => _error = 'Reason is required.');
      return;
    }
    if (_status == widget.item.status) {
      setState(() => _error =
          'Pick a different status, or this is a no-op.');
      return;
    }
    Navigator.of(context).pop(_ChangeStatusResult(_status, reason));
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final item = widget.item;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: 16 + media.viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: DplColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Text(
            'Change Item Status',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            'Plan #${item.planNo} '
            '${item.partDescription.isEmpty ? '' : '— ${item.partDescription}'}',
            style: TextStyle(color: DplColors.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            'Currently ${_humanItemStatus(item.status)}. '
            'Both fields are required.',
            style: TextStyle(color: DplColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 14),
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: VistarPalette.badBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: VistarPalette.badLine),
              ),
              child: Text(
                _error!,
                style: TextStyle(
                  color: VistarPalette.badInk,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          DropdownButtonFormField<String>(
            initialValue: _status,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'New Status',
              prefixIcon: Icon(Icons.swap_horiz_outlined),
            ),
            items: [
              for (final s in _statuses)
                DropdownMenuItem(
                  value: s,
                  child: Text(_humanItemStatus(s)),
                ),
            ],
            onChanged: (v) => setState(() => _status = v ?? _status),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _reasonCtrl,
            maxLines: 3,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Reason (required)',
              hintText: 'Why is this item being overridden? Logged to audit.',
              prefixIcon: Icon(Icons.notes_outlined),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Apply'),
                    onPressed: _submit,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Carry-forward-to-next-shift sheet
// ---------------------------------------------------------------------------

class _CarryForwardResult {
  final int shiftId;
  final int planQty;
  final bool completeSource;
  const _CarryForwardResult({
    required this.shiftId,
    required this.planQty,
    required this.completeSource,
  });
}

class _CarryForwardSheet extends ConsumerStatefulWidget {
  final DplProductionPlanItem item;
  const _CarryForwardSheet({required this.item});

  @override
  ConsumerState<_CarryForwardSheet> createState() =>
      _CarryForwardSheetState();
}

class _CarryForwardSheetState extends ConsumerState<_CarryForwardSheet> {
  late final TextEditingController _qtyCtrl;
  int? _shiftId;
  // Default OFF — managers wanted "carry-forward" to mean *only* shift the
  // leftover to the next plan, without closing the current item. Power
  // users who actually want to close the source can still tick the box
  // below before submitting.
  bool _completeSource = false;
  String? _error;

  int get _leftover => widget.item.planQty - widget.item.actualQty;

  /// True when the source has produced nothing yet AND the typed carry
  /// qty equals the full plan qty. In that case the action is really
  /// a *move* — the handler will reassign the existing row's shift_id
  /// rather than create a duplicate, so the sheet should advertise it
  /// as such (different title, no "Also close" checkbox).
  bool get _isPureMove {
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    return widget.item.actualQty == 0 &&
        qty > 0 &&
        qty == widget.item.planQty;
  }

  @override
  void initState() {
    super.initState();
    _qtyCtrl = TextEditingController(text: _leftover.toString());
    // Rebuild on qty edits so the Move/Carry mode flips live as the
    // manager types — otherwise the title and button would lie about
    // what `_submit` is about to do.
    _qtyCtrl.addListener(_onQtyChanged);
  }

  void _onQtyChanged() => setState(() {});

  @override
  void dispose() {
    _qtyCtrl.removeListener(_onQtyChanged);
    _qtyCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) {
      setState(() => _error = 'Carry qty must be greater than 0.');
      return;
    }
    if (qty > _leftover) {
      setState(() =>
          _error = "Carry qty can't exceed the leftover ($_leftover).");
      return;
    }
    if (_shiftId == null) {
      setState(() => _error = 'Pick the target shift.');
      return;
    }
    if (_shiftId == widget.item.shiftId) {
      setState(() => _error =
          'Target shift is the same as the source - pick a different one.');
      return;
    }
    Navigator.of(context).pop(_CarryForwardResult(
      shiftId: _shiftId!,
      planQty: qty,
      completeSource: _completeSource,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final item = widget.item;
    final shiftsAsync = ref.watch(dplShiftsProvider);
    final shifts = shiftsAsync.asData?.value.data ?? const <DplShift>[];
    final loadingShifts = shiftsAsync.isLoading;
    final isPureMove = _isPureMove;

    // Suggest the "next" shift in the masters list. Cheap heuristic:
    // first active shift whose id isnt the source. The manager can
    // change it. If none exists, dropdown stays empty.
    if (_shiftId == null && shifts.isNotEmpty) {
      final candidate = shifts.firstWhere(
        (s) => s.id != item.shiftId,
        orElse: () => shifts.first,
      );
      _shiftId = candidate.id;
    }

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: 16 + media.viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: DplColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            isPureMove ? 'Move to Next Shift' : 'Carry to Next Shift',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            'Plan #${item.planNo}'
            '${item.partDescription.isEmpty ? "" : " - ${item.partDescription}"}',
            style: TextStyle(color: DplColors.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            'Source: plan ${item.planQty} actual ${item.actualQty} '
            'leftover $_leftover',
            style: TextStyle(color: DplColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 14),
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: VistarPalette.badBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: VistarPalette.badLine),
              ),
              child: Text(
                _error!,
                style: TextStyle(
                  color: VistarPalette.badInk,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          TextField(
            controller: _qtyCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Carry qty',
              helperText: 'Defaults to the full leftover ($_leftover).',
              prefixIcon: const Icon(Icons.swap_vert),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<int?>(
            initialValue: _shiftId,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Target Shift',
              prefixIcon: const Icon(Icons.access_time),
              helperText: loadingShifts ? 'Loading shifts...' : null,
            ),
            items: [
              for (final s in shifts)
                DropdownMenuItem<int?>(
                  value: s.id,
                  child: Text(
                    '${s.name}'
                    '${s.windowLabel.isEmpty ? "" : "  -  ${s.windowLabel}"}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: loadingShifts
                ? null
                : (v) => setState(() => _shiftId = v),
          ),
          const SizedBox(height: 6),
          // In pure-move mode the source row is reassigned, not split,
          // so there's nothing to "also close" — hide the checkbox to
          // keep the sheet honest. Show a one-line explainer instead
          // so the manager understands the existing item is the one
          // that's moving.
          if (isPureMove)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'Nothing produced yet, so this item will be moved to the '
                'target shift. No duplicate will be created.',
                style: TextStyle(fontSize: 11, color: DplColors.textSecondary),
              ),
            )
          else
            CheckboxListTile(
              value: _completeSource,
              onChanged: (v) =>
                  setState(() => _completeSource = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text(
                'Also close this item as completed',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              subtitle: Text(
                'By default the leftover is just shifted to the next plan and '
                'this item stays open at its current actual quantity. Tick this '
                'to additionally mark the current item as completed.',
                style: TextStyle(fontSize: 11, color: DplColors.textSecondary),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    icon: Icon(isPureMove
                        ? Icons.swap_horiz_outlined
                        : Icons.skip_next_outlined),
                    label: Text(isPureMove ? 'Move' : 'Carry Forward'),
                    onPressed: _submit,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Per-plan live-downtime strip on the manager plan detail screen.
/// Sized + styled like the green "Started 10:39 - Running 13:52"
/// running strip on plan items, but in red to flag the downtime.
class _PlanActiveDowntimeCard extends StatelessWidget {
  final ActiveDowntime downtime;
  const _PlanActiveDowntimeCard({required this.downtime});

  @override
  Widget build(BuildContext context) {
    final reason = downtime.reasonName.trim().isEmpty
        ? 'Downtime'
        : downtime.reasonName.trim();
    final color = VistarPalette.bad;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: VistarPalette.badBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Downtime: $reason  -  ',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          LiveTimerText(
            startTime: downtime.startTime,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
