import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_constants.dart';
import '../../manager/widgets/error_retry.dart';
import '../../models/dpl_downtime_reason.dart';
import '../providers/downtime_provider.dart';
import '../providers/machine_plan_provider.dart';
import '../providers/today_plans_provider.dart';
import 'supervisor_error_helper.dart';

/// Modal bottom sheet for opening a downtime against a machine.
///
/// Reusable from:
///   * MachinePlanScreen — `planItemId` left null (general downtime)
///   * PlanExecutionScreen — `planItemId` pre-filled
class DowntimeEntrySheet extends ConsumerStatefulWidget {
  final int planId;
  final int machineId;
  final String machineName;
  final int? planItemId;
  final String? planItemLabel;

  const DowntimeEntrySheet({
    super.key,
    required this.planId,
    required this.machineId,
    required this.machineName,
    this.planItemId,
    this.planItemLabel,
  });

  @override
  ConsumerState<DowntimeEntrySheet> createState() => _DowntimeEntrySheetState();
}

class _DowntimeEntrySheetState extends ConsumerState<DowntimeEntrySheet> {
  int? _reasonId;
  final _remarksCtrl = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _remarksCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_reasonId == null) return;

    setState(() => _isSubmitting = true);
    final res = await ref.read(dplApiServiceProvider).startDowntime(
          planId: widget.planId,
          machineId: widget.machineId,
          reasonId: _reasonId!,
          planItemId: widget.planItemId,
          remarks: _remarksCtrl.text,
        );
    if (!mounted) return;
    setState(() => _isSubmitting = false);

    if (res.isError) {
      handleSupervisorError(
        context,
        res,
        fallback: 'Failed to start downtime.',
      );
      return;
    }
    DplSnack.success(context, 'Downtime started.');
    ref.invalidate(machinePlanProvider(widget.planId));
    ref.invalidate(planDowntimesProvider(widget.planId));
    ref.invalidate(todayPlansProvider);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final reasonsAsync = ref.watch(supervisorDowntimeReasonsProvider);
    final hasReasons = reasonsAsync.asData?.value.data?.isNotEmpty ?? false;
    final canSave = !_isSubmitting && _reasonId != null && hasReasons;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Report Downtime',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'Refresh reasons',
                icon: const Icon(Icons.refresh),
                onPressed: () =>
                    ref.invalidate(supervisorDowntimeReasonsProvider),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _readonlyRow(
            icon: Icons.precision_manufacturing_outlined,
            label: 'Machine',
            value: widget.machineName,
          ),
          const SizedBox(height: 8),
          _readonlyRow(
            icon: Icons.list_alt_outlined,
            label: 'Item',
            value: widget.planItemLabel ?? 'General (no specific item)',
          ),
          const SizedBox(height: 12),
          _ReasonPicker(
            reasonsAsync: reasonsAsync,
            selectedId: _reasonId,
            onChanged: (v) => setState(() => _reasonId = v),
            onRefresh: () =>
                ref.invalidate(supervisorDowntimeReasonsProvider),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _remarksCtrl,
            maxLines: 2,
            maxLength: 300,
            decoration: const InputDecoration(
              labelText: 'Remarks (optional)',
              prefixIcon: Icon(Icons.note_outlined),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: OutlinedButton(
                    onPressed: _isSubmitting
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    icon: _isSubmitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(
                      _isSubmitting ? 'Saving...' : 'Start Downtime',
                    ),
                    onPressed: canSave ? _save : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: VistarPalette.warnSolid,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: VistarPalette.surface3,
                      disabledForegroundColor: VistarPalette.txt3,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _readonlyRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: VistarPalette.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Row(
        children: [
          Icon(icon, color: VistarPalette.txt2, size: 18),
          const SizedBox(width: 10),
          Text(
            '$label: ',
            style: TextStyle(
              color: VistarPalette.txt2,
              fontWeight: FontWeight.w600,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w800),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders the reason dropdown plus loading / error / empty states.
class _ReasonPicker extends StatelessWidget {
  final AsyncValue reasonsAsync;
  final int? selectedId;
  final ValueChanged<int> onChanged;
  final VoidCallback onRefresh;

  const _ReasonPicker({
    required this.reasonsAsync,
    required this.selectedId,
    required this.onChanged,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return reasonsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (e, _) => _empty(
        icon: Icons.error_outline,
        title: 'Could not load reasons',
        message: '$e',
      ),
      data: (res) {
        if (res.isError) {
          return _empty(
            icon: Icons.error_outline,
            title: 'Could not load reasons',
            message:
                res.error?.toString() ?? 'Please refresh and try again.',
          );
        }
        final reasons = (res.data as List<DplDowntimeReason>?) ??
            const <DplDowntimeReason>[];

        if (reasons.isEmpty) {
          return _empty(
            icon: Icons.report_off_outlined,
            title: 'No downtime reasons available',
            message: 'A manager needs to add reasons from '
                'Settings → Downtime Reasons before you can report a '
                'downtime. Tap refresh once they have.',
          );
        }

        final planned = reasons
            .where((r) => r.category == DplDowntimeCategory.planned)
            .toList();
        final unplanned = reasons
            .where((r) => r.category != DplDowntimeCategory.planned)
            .toList();

        // Defensive: if a stale selection no longer exists, ignore it.
        final hasSelection =
            selectedId != null && reasons.any((r) => r.id == selectedId);

        return DropdownButtonFormField<int>(
          initialValue: hasSelection ? selectedId : null,
          decoration: const InputDecoration(
            labelText: 'Reason',
            prefixIcon: Icon(Icons.report_outlined),
          ),
          items: [
            if (planned.isNotEmpty) ...[
              DropdownMenuItem<int>(
                enabled: false,
                value: -1,
                child: Text(
                  'Planned',
                  style: TextStyle(
                    color: VistarPalette.info,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              ...planned.map((r) => DropdownMenuItem<int>(
                    value: r.id,
                    child: Text(r.name),
                  )),
            ],
            if (unplanned.isNotEmpty) ...[
              DropdownMenuItem<int>(
                enabled: false,
                value: -2,
                child: Text(
                  'Unplanned',
                  style: TextStyle(
                    color: VistarPalette.warn,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              ...unplanned.map((r) => DropdownMenuItem<int>(
                    value: r.id,
                    child: Text(r.name),
                  )),
            ],
          ],
          onChanged: (v) {
            if (v == null || v < 0) return;
            onChanged(v);
          },
        );
      },
    );
  }

  Widget _empty({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VistarPalette.warnBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VistarPalette.warnLine),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: VistarPalette.warn),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: VistarPalette.warnInk,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: TextStyle(
                    color: VistarPalette.warnInk,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Refresh'),
                  style: TextButton.styleFrom(
                    foregroundColor: VistarPalette.warnInk,
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
