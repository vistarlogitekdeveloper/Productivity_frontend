import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_organization_provider.dart';
import '../../models/dpl_supervisor_today.dart';
import '../../supervisor/widgets/live_timer_text.dart';
import '../../supervisor/widgets/supervisor_error_helper.dart';
import '../providers/dpl_dashboard_provider.dart';
import '../providers/dpl_manager_active_downtimes_provider.dart';
import '../providers/dpl_viewer_only_provider.dart';
import 'error_retry.dart';

/// Bottom sheet shown when the manager taps an active-downtime banner
/// (global header banner or per-machine card strip). Surfaces the full
/// context the manager needs without first navigating to the plan:
/// reason + live timer, machine, plan, plan item, the supervisor who
/// opened it, shift, category, started-at.
///
/// Provides two actions:
///   * **Open plan** — pushes `/dpl/manager/plans/:id`.
///   * **Close downtime** — confirms (with an optional reason note) and
///     calls `POST /manager/downtime/:id/close`, the manager-scoped
///     recovery endpoint for orphaned downtimes (supervisor offline,
///     stuck banner, etc.). For the read-only DPL Customer role the
///     button is hidden so they keep the same view-only contract as
///     the rest of the dashboard.
///
/// Open with [showManagerActiveDowntimeDetailsSheet] so callers get a
/// consistent rounded-top, modal-barrier shape.
class ManagerActiveDowntimeDetailsSheet extends ConsumerStatefulWidget {
  final ActiveDowntime downtime;

  const ManagerActiveDowntimeDetailsSheet({
    super.key,
    required this.downtime,
  });

  @override
  ConsumerState<ManagerActiveDowntimeDetailsSheet> createState() =>
      _ManagerActiveDowntimeDetailsSheetState();
}

class _ManagerActiveDowntimeDetailsSheetState
    extends ConsumerState<ManagerActiveDowntimeDetailsSheet> {
  bool _isStopping = false;

  Future<void> _confirmAndStop() async {
    final reason = await _promptForReason();
    if (reason == null || !mounted) return;

    setState(() => _isStopping = true);
    // Backend's audit-log writer can't pull `organization_id` from the
    // JWT on this route, so we pass the active org explicitly to avoid
    // a 500 (`notNull Violation: DplAuditLog.organization_id`).
    final orgId = ref.read(dplActiveOrganizationProvider)?.id;
    final res = await ref.read(dplApiServiceProvider).managerCloseDowntime(
          widget.downtime.id,
          reason: reason,
          organizationId: orgId,
        );
    if (!mounted) return;
    setState(() => _isStopping = false);

    if (res.isError) {
      handleSupervisorError(
        context,
        res,
        fallback: 'Failed to close downtime.',
      );
      return;
    }

    // Refresh the manager surfaces so the global banner, the per-machine
    // strip, and the dashboard KPIs all re-pull immediately.
    ref.invalidate(managerActiveDowntimesProvider);
    ref.invalidate(dplDashboardSummaryProvider);
    DplSnack.success(context, 'Downtime closed.');
    Navigator.of(context).pop();
  }

  /// Confirms the action and lets the manager attach a short note
  /// explaining why they're force-closing (e.g. "supervisor logged off").
  /// Returns the trimmed reason string on confirm (empty string allowed),
  /// or `null` if the manager cancelled.
  Future<String?> _promptForReason() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Close downtime?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Force-close "${widget.downtime.reasonName.isEmpty ? 'Active' : widget.downtime.reasonName}". '
              'Use this when the supervisor went offline without resuming.',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'e.g. Supervisor logged off',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: VistarPalette.badSolid,
            ),
            onPressed: () =>
                Navigator.of(dialogCtx).pop(ctrl.text.trim()),
            child: const Text('Close downtime'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  void _openPlan() {
    final planId = widget.downtime.planId;
    if (planId == null) return;
    Navigator.of(context).pop();
    context.push('/dpl/manager/plans/$planId');
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.downtime;
    final viewerOnly = ref.watch(dplViewerOnlyProvider);
    final reason = d.reasonName.trim().isEmpty ? 'Active' : d.reasonName.trim();
    final startedLocal = d.startTime.toLocal();
    final startedLabel =
        DateFormat('EEE, dd MMM • HH:mm').format(startedLocal);
    final canOpenPlan = d.planId != null;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: VistarPalette.line2,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: VistarPalette.badSolid,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'DOWNTIME ACTIVE',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 11,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          reason,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 6),
                        LiveTimerText(
                          startTime: d.startTime,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DetailRow(
                    icon: Icons.precision_manufacturing_outlined,
                    label: 'Machine',
                    value: (d.machineName ?? '').trim().isEmpty
                        ? (d.machineId == null
                            ? 'Unknown'
                            : 'Machine #${d.machineId}')
                        : d.machineName!.trim(),
                  ),
                  _DetailRow(
                    icon: Icons.assignment_outlined,
                    label: 'Plan',
                    value: d.planId == null ? '—' : 'Plan #${d.planId}',
                  ),
                  _DetailRow(
                    icon: Icons.inventory_2_outlined,
                    label: 'Plan item',
                    value: d.planItemId == null
                        ? 'Machine-wide (no specific item)'
                        : 'Item #${d.planItemId}',
                  ),
                  _DetailRow(
                    icon: Icons.person_outline,
                    label: 'Opened by',
                    value: (d.supervisorName ?? '').trim().isEmpty
                        ? (d.supervisorUserId == null
                            ? 'Unknown'
                            : 'Supervisor #${d.supervisorUserId}')
                        : d.supervisorName!.trim(),
                  ),
                  _DetailRow(
                    icon: Icons.schedule_outlined,
                    label: 'Shift',
                    value: (d.shiftCode ?? '').trim().isEmpty
                        ? '—'
                        : 'Shift ${d.shiftCode!.trim()}',
                  ),
                  _DetailRow(
                    icon: Icons.category_outlined,
                    label: 'Category',
                    value: (d.category ?? '').trim().isEmpty
                        ? '—'
                        : d.category!.trim(),
                  ),
                  _DetailRow(
                    icon: Icons.play_circle_outline,
                    label: 'Started at',
                    value: startedLabel,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: canOpenPlan ? _openPlan : null,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open plan'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  // Stop is a write action — DPL Customer (viewer-only)
                  // never sees it, matching the rest of the dashboard.
                  if (!viewerOnly) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _isStopping ? null : _confirmAndStop,
                        icon: _isStopping
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.stop_circle_outlined),
                        label: const Text('Close downtime'),
                        style: FilledButton.styleFrom(
                          backgroundColor: VistarPalette.badSolid,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Convenience launcher so callers don't have to repeat the shape +
/// barrier config on every tap site.
Future<void> showManagerActiveDowntimeDetailsSheet(
  BuildContext context, {
  required ActiveDowntime downtime,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => ManagerActiveDowntimeDetailsSheet(downtime: downtime),
  );
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: VistarPalette.surface3,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: VistarPalette.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: VistarPalette.txt2,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
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
