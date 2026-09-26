import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../../../core/widgets/shimmer_skeleton.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../manager/widgets/error_retry.dart';
import '../../models/dpl_production_plan_item.dart';
import '../../models/dpl_supervisor_plan_detail.dart';
import '../../models/dpl_supervisor_today.dart';
import '../providers/machine_plan_provider.dart';
import '../providers/today_plans_provider.dart';
import '../widgets/downtime_entry_sheet.dart';
import '../widgets/dpl_supervisor_footer.dart';
import '../widgets/live_timer_text.dart';
import '../widgets/pause_entry_sheet.dart';
import '../widgets/start_stop_button.dart';
import '../widgets/stop_confirm_dialog.dart';
import '../widgets/supervisor_error_helper.dart';
import '../widgets/trolley_photo_modal.dart';

/// The core of Phase 2 — drives the lifecycle of a single plan item
/// through 4 states: Pending → In Progress (± Downtime) → Completed.
class PlanExecutionScreen extends ConsumerStatefulWidget {
  final int planId;
  final int itemId;

  const PlanExecutionScreen({
    super.key,
    required this.planId,
    required this.itemId,
  });

  @override
  ConsumerState<PlanExecutionScreen> createState() =>
      _PlanExecutionScreenState();
}

class _PlanExecutionScreenState extends ConsumerState<PlanExecutionScreen> {
  /// Local mirror of `actual_qty` so the stepper + text field stay
  /// responsive while the debounced PATCH catches up.
  int? _localActualQty;
  late final TextEditingController _qtyCtrl;
  Timer? _qtyDebounce;

  bool _isStarting = false;
  bool _isStopping = false;
  bool _isPausing = false;
  bool _isResumingPause = false;
  bool _wakelockOn = false;

  @override
  void initState() {
    super.initState();
    _qtyCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _qtyDebounce?.cancel();
    _qtyCtrl.dispose();
    _setWakelock(false);
    super.dispose();
  }

  Future<void> _setWakelock(bool on) async {
    if (_wakelockOn == on) return;
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
      _wakelockOn = on;
    } catch (_) {
      // Wakelock isn't available on every platform — non-fatal.
    }
  }

  /// Pushes [qty] through a 1.5s debounced PATCH so a stepper isn't
  /// firing dozens of requests.
  void _scheduleActualPush(int qty) {
    _qtyDebounce?.cancel();
    _qtyDebounce = Timer(const Duration(milliseconds: 1500), () async {
      final res = await ref
          .read(dplApiServiceProvider)
          .updateActualQty(widget.planId, widget.itemId, qty);
      if (!mounted) return;
      if (res.isError) {
        handleSupervisorError(
          context,
          res,
          fallback: 'Failed to update qty.',
        );
      }
    });
  }

  void _onLocalQtyChange(int qty) {
    setState(() => _localActualQty = qty < 0 ? 0 : qty);
    _qtyCtrl.text = (qty < 0 ? 0 : qty).toString();
    _qtyCtrl.selection =
        TextSelection.collapsed(offset: _qtyCtrl.text.length);
    _scheduleActualPush(qty < 0 ? 0 : qty);
  }

  Future<void> _start(DplProductionPlanItem item) async {
    setState(() => _isStarting = true);
    final res = await ref
        .read(dplApiServiceProvider)
        .startItem(widget.planId, widget.itemId);
    if (!mounted) return;
    setState(() => _isStarting = false);

    if (res.isError) {
      handleSupervisorError(
        context,
        res,
        fallback: 'Failed to start item.',
      );
      return;
    }
    HapticFeedback.heavyImpact();
    DplSnack.success(context, 'Production started.');
    ref.invalidate(machinePlanProvider(widget.planId));
    ref.invalidate(todayPlansProvider);
  }

  Future<void> _stop(DplProductionPlanItem item) async {
    final initialQty = _localActualQty ?? item.actualQty;
    final result = await showDialog<StopConfirmResult>(
      context: context,
      builder: (_) => StopConfirmDialog(
        planQty: item.planQty,
        initialActualQty: initialQty,
      ),
    );
    if (result == null) return;
    if (!mounted) return;

    // Trolley photo gate — backend requires a fresh photo before
    // accepting the stop call (DPL_TROLLEY_PHOTO_REQUIRED=true). Open
    // the camera; the modal handles upload and returns the persisted
    // photo. Cancelling here aborts the whole stop flow.
    final trolleyPhoto = await showTrolleyPhotoModal(
      context: context,
      planId: widget.planId,
      itemId: widget.itemId,
      remarks: result.remarks,
    );
    if (trolleyPhoto == null) return;
    if (!mounted) return;

    // Flush any pending qty PATCH first, then stop.
    _qtyDebounce?.cancel();

    setState(() => _isStopping = true);
    final res = await ref.read(dplApiServiceProvider).stopItem(
          widget.planId,
          widget.itemId,
          actualQty: result.actualQty,
          remarks: result.remarks,
          trolleyPhotoId: trolleyPhoto.id,
        );
    if (!mounted) return;
    setState(() => _isStopping = false);

    if (res.isError) {
      handleStopWithTrolleyError(
        context,
        res,
        fallback: 'Failed to stop item.',
      );
      return;
    }
    HapticFeedback.heavyImpact();
    DplSnack.success(context, 'Item completed.');
    ref.invalidate(machinePlanProvider(widget.planId));
    ref.invalidate(todayPlansProvider);
  }

  Future<void> _resume(int downtimeId) async {
    final res = await ref
        .read(dplApiServiceProvider)
        .resumeDowntime(downtimeId);
    if (!mounted) return;
    if (res.isError) {
      handleSupervisorError(
        context,
        res,
        fallback: 'Failed to resume.',
      );
      return;
    }
    HapticFeedback.heavyImpact();
    DplSnack.success(context, 'Resumed.');
    ref.invalidate(machinePlanProvider(widget.planId));
    ref.invalidate(todayPlansProvider);
  }

  Future<void> _openPause(DplProductionPlanItem item) async {
    final label =
        'Plan #${item.planNo} — ${item.partDescription.isEmpty ? "Item" : item.partDescription}';
    final result = await showModalBottomSheet<PauseEntryResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => PauseEntrySheet(itemLabel: label),
    );
    if (result == null || !mounted) return;

    setState(() => _isPausing = true);
    final res = await ref.read(dplApiServiceProvider).pauseItem(
          widget.planId,
          widget.itemId,
          reasonText: result.reasonText,
          reasonId: result.reasonId,
          expectedResumeAt: result.expectedResumeAt,
        );
    if (!mounted) return;
    setState(() => _isPausing = false);

    if (res.isError) {
      handleSupervisorError(
        context,
        res,
        fallback: 'Failed to pause item.',
      );
      return;
    }
    HapticFeedback.heavyImpact();
    DplSnack.success(context, 'Item paused.');
    ref.invalidate(machinePlanProvider(widget.planId));
    ref.invalidate(todayPlansProvider);
  }

  Future<void> _resumeItemPause() async {
    setState(() => _isResumingPause = true);
    final res = await ref
        .read(dplApiServiceProvider)
        .resumeItem(widget.planId, widget.itemId);
    if (!mounted) return;
    setState(() => _isResumingPause = false);

    if (res.isError) {
      handleSupervisorError(
        context,
        res,
        fallback: 'Failed to resume item.',
      );
      return;
    }
    HapticFeedback.heavyImpact();
    final mins = res.data?.durationMinutes ?? 0;
    DplSnack.success(
      context,
      mins > 0 ? 'Resumed after ${mins}m.' : 'Resumed.',
    );
    ref.invalidate(machinePlanProvider(widget.planId));
    ref.invalidate(todayPlansProvider);
  }

  Future<void> _openDowntime(
    DplSupervisorPlanDetail detail,
    DplProductionPlanItem item,
  ) async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DowntimeEntrySheet(
        planId: detail.plan.id,
        machineId: detail.plan.machineId,
        machineName: detail.plan.machineName,
        planItemId: item.id,
        planItemLabel: 'Plan #${item.planNo} — ${item.partDescription}',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(machinePlanProvider(widget.planId));

    final appBarTitle = async.maybeWhen(
      data: (res) {
        if (res.isError || res.data == null) return 'Execution';
        final item = res.data!.plan.items.firstWhere(
          (i) => i.id == widget.itemId,
          orElse: () => _emptyItem(),
        );
        return 'Plan #${item.planNo} — '
            '${item.partDescription.isEmpty ? "Item" : item.partDescription}';
      },
      orElse: () => 'Execution',
    );

    return Scaffold(
      appBar: DplAppBar(
        title: appBarTitle,
        actions: const [_LiveClock()],
      ),
      body: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: SkeletonList(count: 4),
        ),
        error: (e, _) => DplErrorRetry(
          message: e.toString(),
          onRetry: () => ref.invalidate(machinePlanProvider(widget.planId)),
        ),
        data: (res) {
          if (res.isError) {
            return DplErrorRetry(
              message: res.error ?? 'Failed to load plan.',
              onRetry: () =>
                  ref.invalidate(machinePlanProvider(widget.planId)),
            );
          }
          final detail = res.data!;
          final item = detail.plan.items.firstWhere(
            (i) => i.id == widget.itemId,
            orElse: () => _emptyItem(),
          );

          // Keep screen awake whenever we're in active production.
          final isRunning = item.status == 'in_progress';
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _setWakelock(isRunning);
          });

          // Initialise local qty mirror from server value.
          if (_localActualQty == null) {
            _localActualQty = item.actualQty;
            _qtyCtrl.text = item.actualQty.toString();
          }

          final activeDowntime =
              detail.activeDowntime?.planItemId == item.id
                  ? detail.activeDowntime
                  : null;

          return _ExecutionBody(
            detail: detail,
            item: item,
            activeDowntime: activeDowntime,
            qtyCtrl: _qtyCtrl,
            localActualQty: _localActualQty ?? item.actualQty,
            isStarting: _isStarting,
            isStopping: _isStopping,
            isPausing: _isPausing,
            isResumingPause: _isResumingPause,
            onStart: () => _start(item),
            onStop: () => _stop(item),
            onLocalQtyChange: (q) {
              // Enforce: actual qty cannot exceed plan qty.
              final capped =
                  q > item.planQty ? item.planQty : (q < 0 ? 0 : q);
              _onLocalQtyChange(capped);
            },
            onOpenDowntime: () => _openDowntime(detail, item),
            onResume: () =>
                _resume(activeDowntime?.id ?? detail.activeDowntime!.id),
            onPause: () => _openPause(item),
            onResumeItemPause: _resumeItemPause,
          );
        },
      ),
      bottomNavigationBar: const DplSupervisorFooter(),
    );
  }

  static DplProductionPlanItem _emptyItem() => const DplProductionPlanItem(
        id: 0,
        planNo: 0,
        partId: 0,
        planQty: 0,
        sequence: 0,
      );
}

/// Tiny live clock for the AppBar — supervisors like to glance at it.
class _LiveClock extends StatefulWidget {
  const _LiveClock();

  @override
  State<_LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<_LiveClock> {
  Timer? _ticker;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Center(
        child: Text(
          DateFormat('HH:mm:ss').format(_now),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _ExecutionBody extends StatelessWidget {
  final DplSupervisorPlanDetail detail;
  final DplProductionPlanItem item;
  final ActiveDowntime? activeDowntime;
  final TextEditingController qtyCtrl;
  final int localActualQty;
  final bool isStarting;
  final bool isStopping;
  final bool isPausing;
  final bool isResumingPause;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final ValueChanged<int> onLocalQtyChange;
  final VoidCallback onOpenDowntime;
  final VoidCallback onResume;
  final VoidCallback onPause;
  final VoidCallback onResumeItemPause;

  const _ExecutionBody({
    required this.detail,
    required this.item,
    required this.activeDowntime,
    required this.qtyCtrl,
    required this.localActualQty,
    required this.isStarting,
    required this.isStopping,
    required this.isPausing,
    required this.isResumingPause,
    required this.onStart,
    required this.onStop,
    required this.onLocalQtyChange,
    required this.onOpenDowntime,
    required this.onResume,
    required this.onPause,
    required this.onResumeItemPause,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _HeaderCard(item: item),
        const SizedBox(height: 14),
        _StateBody(
          detail: detail,
          item: item,
          activeDowntime: activeDowntime,
          qtyCtrl: qtyCtrl,
          localActualQty: localActualQty,
          isStarting: isStarting,
          isStopping: isStopping,
          isPausing: isPausing,
          isResumingPause: isResumingPause,
          onStart: onStart,
          onStop: onStop,
          onLocalQtyChange: onLocalQtyChange,
          onOpenDowntime: onOpenDowntime,
          onResume: onResume,
          onPause: onPause,
          onResumeItemPause: onResumeItemPause,
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final DplProductionPlanItem item;
  const _HeaderCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.partDescription.isEmpty
                ? (item.partNumber.isEmpty
                    ? 'Item #${item.id}'
                    : item.partNumber)
                : item.partDescription,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (item.partName.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              item.partName,
              style: TextStyle(color: VistarPalette.txt2),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              _kv('Part #', item.partNumber.isEmpty ? '—' : item.partNumber),
              const SizedBox(width: 14),
              _kv('Plan Qty', item.planQty.toString(),
                  emphasize: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kv(String label, String value, {bool emphasize = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: VistarPalette.txt2,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: emphasize ? 24 : 14,
            color: emphasize ? VistarPalette.info : null,
          ),
        ),
      ],
    );
  }
}

class _StateBody extends StatelessWidget {
  final DplSupervisorPlanDetail detail;
  final DplProductionPlanItem item;
  final ActiveDowntime? activeDowntime;
  final TextEditingController qtyCtrl;
  final int localActualQty;
  final bool isStarting;
  final bool isStopping;
  final bool isPausing;
  final bool isResumingPause;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final ValueChanged<int> onLocalQtyChange;
  final VoidCallback onOpenDowntime;
  final VoidCallback onResume;
  final VoidCallback onPause;
  final VoidCallback onResumeItemPause;

  const _StateBody({
    required this.detail,
    required this.item,
    required this.activeDowntime,
    required this.qtyCtrl,
    required this.localActualQty,
    required this.isStarting,
    required this.isStopping,
    required this.isPausing,
    required this.isResumingPause,
    required this.onStart,
    required this.onStop,
    required this.onLocalQtyChange,
    required this.onOpenDowntime,
    required this.onResume,
    required this.onPause,
    required this.onResumeItemPause,
  });

  @override
  Widget build(BuildContext context) {
    // State D — Completed
    if (item.status == 'completed') {
      return _CompletedView(item: item);
    }

    // State A — Pending
    if (item.status == 'pending' || item.startTime == null) {
      return _PendingView(isStarting: isStarting, onStart: onStart);
    }

    // State C — In Progress + active machine downtime on THIS item
    if (activeDowntime != null) {
      return _DowntimeView(
        item: item,
        downtime: activeDowntime!,
        localActualQty: localActualQty,
        onResume: onResume,
      );
    }

    // State C' — Item-level pause (parallel to downtime, supervisor can
    // jump to another item on the plan while this one is paused).
    if (item.pausedAt != null) {
      return _ItemPausedView(
        item: item,
        localActualQty: localActualQty,
        isResuming: isResumingPause,
        isStopping: isStopping,
        onResume: onResumeItemPause,
        onStop: onStop,
      );
    }

    // State B — In Progress
    return _InProgressView(
      item: item,
      qtyCtrl: qtyCtrl,
      localActualQty: localActualQty,
      isStopping: isStopping,
      isPausing: isPausing,
      onStop: onStop,
      onPause: onPause,
      onLocalQtyChange: onLocalQtyChange,
      onOpenDowntime: onOpenDowntime,
    );
  }
}

class _PendingView extends StatelessWidget {
  final bool isStarting;
  final VoidCallback onStart;

  const _PendingView({required this.isStarting, required this.onStart});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 20),
        Icon(Icons.play_circle_outline,
            size: 88, color: VistarPalette.ok),
        const SizedBox(height: 8),
        const Text(
          'Ready to start',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 20),
        StartStopButton(
          label: 'START PRODUCTION',
          icon: Icons.play_arrow_rounded,
          color: VistarPalette.okSolid,
          onPressed: onStart,
          isBusy: isStarting,
        ),
      ],
    );
  }
}

class _InProgressView extends StatelessWidget {
  final DplProductionPlanItem item;
  final TextEditingController qtyCtrl;
  final int localActualQty;
  final bool isStopping;
  final bool isPausing;
  final VoidCallback onStop;
  final VoidCallback onPause;
  final ValueChanged<int> onLocalQtyChange;
  final VoidCallback onOpenDowntime;

  const _InProgressView({
    required this.item,
    required this.qtyCtrl,
    required this.localActualQty,
    required this.isStopping,
    required this.isPausing,
    required this.onStop,
    required this.onPause,
    required this.onLocalQtyChange,
    required this.onOpenDowntime,
  });

  @override
  Widget build(BuildContext context) {
    final startedAt = DateFormat('hh:mm a')
        .format(item.startTime!.toLocal());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          alignment: Alignment.center,
          child: LiveTimerText(
            startTime: item.startTime!,
            style: const TextStyle(
              fontSize: 56,
              fontWeight: FontWeight.w900,
              fontFamily: 'monospace',
            ),
          ),
        ),
        Center(
          child: Text(
            'Started at $startedAt',
            style: TextStyle(color: VistarPalette.txt2),
          ),
        ),
        const SizedBox(height: 18),
        _ActualQtyStepper(
          qtyCtrl: qtyCtrl,
          localActualQty: localActualQty,
          planQty: item.planQty,
          onChange: onLocalQtyChange,
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  onPressed: onOpenDowntime,
                  icon: const Icon(Icons.report_outlined),
                  label: const Text('Report Downtime'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: VistarPalette.warn,
                    side: BorderSide(
                      color: VistarPalette.warn,
                      width: 1.4,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StartStopButton(
                label: 'STOP',
                icon: Icons.stop_rounded,
                color: VistarPalette.badSolid,
                onPressed: onStop,
                isBusy: isStopping,
                height: 56,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ItemPausedView extends StatelessWidget {
  final DplProductionPlanItem item;
  final int localActualQty;
  final bool isResuming;
  final bool isStopping;
  final VoidCallback onResume;
  final VoidCallback onStop;

  const _ItemPausedView({
    required this.item,
    required this.localActualQty,
    required this.isResuming,
    required this.isStopping,
    required this.onResume,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final pausedAt = DateFormat('hh:mm a').format(item.pausedAt!.toLocal());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: VistarPalette.warnSolid,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              const Text(
                'ITEM PAUSED',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 8),
              LiveTimerText(
                startTime: item.pausedAt!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 44,
                  fontWeight: FontWeight.w900,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Paused at $pausedAt',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: VistarPalette.surface2,
            border: Border.all(color: VistarPalette.line),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.pause_circle_outline,
                  color: VistarPalette.txt2),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'You can start a different item on this plan while '
                  'this one is paused — actual: $localActualQty / '
                  '${item.planQty}',
                  style: TextStyle(
                    color: VistarPalette.txt2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        StartStopButton(
          label: 'RESUME PRODUCTION',
          icon: Icons.play_arrow_rounded,
          color: VistarPalette.okSolid,
          onPressed: onResume,
          isBusy: isResuming,
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 48,
          child: OutlinedButton.icon(
            onPressed: isStopping ? null : onStop,
            icon: const Icon(Icons.stop_rounded),
            label: const Text('Complete & Stop'),
            style: OutlinedButton.styleFrom(
              foregroundColor: VistarPalette.bad,
              side: BorderSide(color: VistarPalette.bad, width: 1.4),
            ),
          ),
        ),
      ],
    );
  }
}

class _DowntimeView extends StatelessWidget {
  final DplProductionPlanItem item;
  final ActiveDowntime downtime;
  final int localActualQty;
  final VoidCallback onResume;

  const _DowntimeView({
    required this.item,
    required this.downtime,
    required this.localActualQty,
    required this.onResume,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: VistarPalette.badSolid,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              const Text(
                'DOWNTIME ACTIVE',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 8),
              LiveTimerText(
                startTime: downtime.startTime,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 44,
                  fontWeight: FontWeight.w900,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 6),
              Text(
                downtime.reasonName.isEmpty
                    ? 'Active downtime'
                    : downtime.reasonName,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: VistarPalette.surface2,
            border: Border.all(color: VistarPalette.line),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.pause_circle_outline,
                  color: VistarPalette.txt2),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Production paused — actual: $localActualQty / ${item.planQty}',
                  style: TextStyle(
                    color: VistarPalette.txt2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        StartStopButton(
          label: 'RESUME PRODUCTION',
          icon: Icons.play_arrow_rounded,
          color: VistarPalette.okSolid,
          onPressed: onResume,
        ),
        const SizedBox(height: 10),
        Text(
          'Resume from downtime before completing the item.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: VistarPalette.txt2,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _CompletedView extends StatelessWidget {
  final DplProductionPlanItem item;
  const _CompletedView({required this.item});

  @override
  Widget build(BuildContext context) {
    final fmtTime = DateFormat('hh:mm a');
    final variance = item.actualQty - item.planQty;
    final varianceColor = variance == 0
        ? VistarPalette.txt2
        : (variance > 0
            ? VistarPalette.ok
            : VistarPalette.bad);

    Duration? netDuration;
    if (item.startTime != null && item.endTime != null) {
      netDuration = item.endTime!
          .difference(item.startTime!) -
          Duration(minutes: item.totalPausedMinutes);
      if (netDuration.isNegative) netDuration = Duration.zero;
    }

    return Column(
      children: [
        Icon(Icons.check_circle_outline,
            size: 88, color: VistarPalette.ok),
        const SizedBox(height: 8),
        const Text(
          'Completed',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: VistarPalette.line),
          ),
          child: Column(
            children: [
              _row('Start',
                  item.startTime == null ? '—' : fmtTime.format(item.startTime!.toLocal())),
              _row('End',
                  item.endTime == null ? '—' : fmtTime.format(item.endTime!.toLocal())),
              _row(
                'Total Paused',
                '${item.totalPausedMinutes} min',
              ),
              if (netDuration != null)
                _row(
                  'Net Duration',
                  '${netDuration.inHours}h ${netDuration.inMinutes.remainder(60)}m',
                ),
              const Divider(height: 22),
              _row('Plan', item.planQty.toString()),
              _row('Actual', item.actualQty.toString()),
              _row(
                'Variance',
                variance > 0 ? '+$variance' : variance.toString(),
                valueColor: varianceColor,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton.tonalIcon(
            onPressed: () {
              if (Navigator.of(context).canPop()) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back to Machine Plan'),
          ),
        ),
      ],
    );
  }

  Widget _row(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: VistarPalette.txt2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActualQtyStepper extends StatelessWidget {
  final TextEditingController qtyCtrl;
  final int localActualQty;
  final int planQty;
  final ValueChanged<int> onChange;

  const _ActualQtyStepper({
    required this.qtyCtrl,
    required this.localActualQty,
    required this.planQty,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final atCap = localActualQty >= planQty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Column(
        children: [
          Text(
            'Actual Qty',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
              color: VistarPalette.txt2,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _stepBtn(
                icon: Icons.remove,
                onTap: () => onChange(localActualQty - 1),
              ),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: Center(
                    child: TextField(
                      controller: qtyCtrl,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        fontFamily: 'monospace',
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                      ),
                      onChanged: (v) {
                        final n = int.tryParse(v.trim()) ?? 0;
                        onChange(n);
                      },
                    ),
                  ),
                ),
              ),
              _stepBtn(
                icon: Icons.add,
                onTap: atCap ? null : () => onChange(localActualQty + 1),
                disabled: atCap,
              ),
            ],
          ),
          Text(
            'Plan: $planQty',
            style: TextStyle(
              color: VistarPalette.txt2,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (atCap) ...[
            const SizedBox(height: 6),
            Text(
              'Actual qty cannot exceed Plan qty ($planQty).',
              style: TextStyle(
                color: VistarPalette.bad,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stepBtn({
    required IconData icon,
    required VoidCallback? onTap,
    bool disabled = false,
  }) {
    return Material(
      color: disabled ? VistarPalette.surface3 : VistarPalette.infoBg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.lightImpact();
                onTap();
              },
        child: Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          child: Icon(
            icon,
            color: disabled
                ? VistarPalette.txt3
                : VistarPalette.info,
            size: 26,
          ),
        ),
      ),
    );
  }
}
