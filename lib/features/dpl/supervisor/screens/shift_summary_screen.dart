import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../../../core/widgets/shimmer_skeleton.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_refresh_icon_button.dart';
import '../../manager/widgets/empty_state.dart';
import '../../manager/widgets/error_retry.dart';
import '../../models/dpl_shift_summary.dart';
import '../providers/shift_summary_provider.dart';
import '../providers/today_plans_provider.dart';
import '../widgets/supervisor_error_helper.dart';

class ShiftSummaryScreen extends ConsumerStatefulWidget {
  const ShiftSummaryScreen({super.key});

  @override
  ConsumerState<ShiftSummaryScreen> createState() =>
      _ShiftSummaryScreenState();
}

class _ShiftSummaryScreenState extends ConsumerState<ShiftSummaryScreen> {
  final _remarksCtrl = TextEditingController();
  bool _isSubmitting = false;

  /// Dates the supervisor has submitted in this session, keyed yyyy-MM-dd.
  /// Survives within the running app so the "Submitted" state stays
  /// visible if they refresh or switch dates back. Backend is still the
  /// source of truth — switching to a date they haven't submitted in
  /// this session falls back to the live data.
  final Set<String> _submittedKeys = {};

  static String _ymdKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _remarksCtrl.dispose();
    super.dispose();
  }

  /// Submit blockers derived from the loaded summary + live today data.
  List<String> _submitBlockers(DplShiftSummary summary) {
    final issues = <String>[];

    if (summary.machines.isEmpty) {
      issues.add('No machines have any plans for today.');
    }
    if (summary.hasIncompleteItems) {
      issues.add('Complete all running items first.');
    }

    final today = ref.read(todayPlansProvider).asData?.value;
    if (today != null && today.isOk && today.data != null) {
      final hasActiveDowntime =
          today.data!.plans.any((p) => p.activeDowntime != null);
      if (hasActiveDowntime) {
        issues.add('Resolve all active downtimes first.');
      }
      final hasRunning = today.data!.plans.any((p) => p.itemsInProgress > 0);
      if (hasRunning) {
        issues.add('Stop all in-progress items first.');
      }
    }

    return issues;
  }

  Future<void> _confirmAndSubmit(DplShiftSummary summary) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Submit Shift?'),
        content: const Text(
          'Once submitted, you cannot edit today\'s production data. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    if (!mounted) return;
    setState(() => _isSubmitting = true);

    final res = await ref.read(dplApiServiceProvider).submitShift(
          summary.date,
          remarks: _remarksCtrl.text,
        );

    if (!mounted) return;
    setState(() => _isSubmitting = false);

    if (res.isError) {
      handleSupervisorError(
        context,
        res,
        fallback: 'Failed to submit shift.',
      );
      return;
    }
    setState(() {
      _submittedKeys.add(_ymdKey(summary.date));
      _remarksCtrl.clear();
    });
    DplSnack.success(
      context,
      'Shift submitted: ${res.data?.plansSubmitted ?? 0} plan(s).',
    );
    ref.invalidate(shiftSummaryProvider);
    ref.invalidate(todayPlansProvider);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(shiftSummaryProvider);
    final dateFmt = DateFormat('EEEE, dd MMM yyyy');
    final date = ref.watch(shiftSummaryDateProvider);

    return Scaffold(
      appBar: DplAppBar(
        title: 'End of Shift — ${dateFmt.format(date)}',
        actions: [
          DplRefreshIconButton(
            onRefresh: () async {
              ref.invalidate(shiftSummaryProvider);
              try {
                await ref.read(shiftSummaryProvider.future);
              } catch (_) {}
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(shiftSummaryProvider);
          await ref.read(shiftSummaryProvider.future);
        },
        child: async.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: SkeletonList(count: 4),
          ),
          error: (e, _) => ListView(
            children: [
              DplErrorRetry(
                message: e.toString(),
                onRetry: () => ref.invalidate(shiftSummaryProvider),
              ),
            ],
          ),
          data: (res) {
            if (res.isError) {
              return ListView(
                children: [
                  DplErrorRetry(
                    message: res.error ?? 'Failed to load shift summary.',
                    onRetry: () => ref.invalidate(shiftSummaryProvider),
                  ),
                ],
              );
            }
            final summary = res.data ?? DplShiftSummary.empty(date);
            final alreadySubmitted =
                _submittedKeys.contains(_ymdKey(summary.date));
            return _SummaryBody(
              summary: summary,
              remarksCtrl: _remarksCtrl,
              isSubmitting: _isSubmitting,
              alreadySubmitted: alreadySubmitted,
              blockers: _submitBlockers(summary),
              onSubmit: () => _confirmAndSubmit(summary),
            );
          },
        ),
      ),
    );
  }
}

class _SummaryBody extends StatelessWidget {
  final DplShiftSummary summary;
  final TextEditingController remarksCtrl;
  final bool isSubmitting;
  final bool alreadySubmitted;
  final List<String> blockers;
  final VoidCallback onSubmit;

  const _SummaryBody({
    required this.summary,
    required this.remarksCtrl,
    required this.isSubmitting,
    required this.alreadySubmitted,
    required this.blockers,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    if (summary.machines.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 60),
          DplEmptyState(
            icon: Icons.summarize_outlined,
            title: 'No production today',
            message: 'No machines have any plans for the selected date.',
          ),
        ],
      );
    }

    final fmt = NumberFormat.decimalPattern();
    final pct = (summary.totals.completionPct * 100).round();
    final canSubmit =
        !alreadySubmitted && !isSubmitting && blockers.isEmpty;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(color: VistarPalette.line),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(child: _big('Plan', fmt.format(summary.totals.planQty),
                      VistarPalette.info)),
                  Expanded(child: _big('Actual', fmt.format(summary.totals.actualQty),
                      VistarPalette.ok)),
                  Expanded(child: _big('Completion', '$pct%',
                      VistarPalette.warn)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.timer_off_outlined,
                      size: 16, color: VistarPalette.txt2),
                  const SizedBox(width: 6),
                  Text(
                    'Total downtime: ${summary.totals.totalDowntimeMinutes} min',
                    style: TextStyle(
                      color: VistarPalette.txt2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        for (final m in summary.machines) _MachineCard(m: m),
        const SizedBox(height: 14),
        if (alreadySubmitted)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: VistarPalette.okBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: VistarPalette.ok),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: VistarPalette.okSolid,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Shift submitted',
                        style: TextStyle(
                          color: VistarPalette.okInk,
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        "Today's production has been locked. "
                        'Pull to refresh if you need the latest view.',
                        style: TextStyle(
                          color: VistarPalette.ok,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )
        else
          TextField(
            controller: remarksCtrl,
            maxLines: 3,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Shift remarks (optional)',
              prefixIcon: Icon(Icons.note_outlined),
            ),
          ),
        const SizedBox(height: 8),
        if (!alreadySubmitted && blockers.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: VistarPalette.warnBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: VistarPalette.warnLine),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cannot submit yet:',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: VistarPalette.warnInk,
                  ),
                ),
                for (final b in blockers)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '• $b',
                      style: TextStyle(
                        color: VistarPalette.warnInk,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 64,
          child: FilledButton.icon(
            style: alreadySubmitted
                ? FilledButton.styleFrom(
                    backgroundColor: VistarPalette.okSolid,
                    disabledBackgroundColor: VistarPalette.okSolid,
                    disabledForegroundColor: Colors.white,
                  )
                : null,
            onPressed: canSubmit ? onSubmit : null,
            icon: isSubmitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Icon(
                    alreadySubmitted
                        ? Icons.lock_outline
                        : Icons.check_circle_outline,
                  ),
            label: Text(
              alreadySubmitted
                  ? 'Submitted'
                  : (isSubmitting ? 'Submitting...' : 'Submit Shift'),
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 16,
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _big(String label, String value, Color color) {
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
            color: color,
            fontWeight: FontWeight.w900,
            fontSize: 22,
          ),
        ),
      ],
    );
  }
}

class _MachineCard extends StatelessWidget {
  final DplShiftMachineSummary m;
  const _MachineCard({required this.m});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final pct = (m.completionPct * 100).round();
    final variance = m.variance;
    final varianceColor = variance == 0
        ? VistarPalette.txt2
        : (variance > 0
            ? VistarPalette.ok
            : VistarPalette.bad);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  m.machineName.isEmpty
                      ? 'Machine #${m.machineId}'
                      : m.machineName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
              Text(
                '$pct%',
                style: TextStyle(
                  color: VistarPalette.warn,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _kv('Plan', fmt.format(m.planQty)),
              const SizedBox(width: 14),
              _kv('Actual', fmt.format(m.actualQty)),
              const SizedBox(width: 14),
              _kv(
                'Variance',
                variance > 0 ? '+$variance' : variance.toString(),
                color: varianceColor,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.timer_off_outlined,
                  size: 14, color: VistarPalette.txt2),
              const SizedBox(width: 4),
              Text(
                'Downtime: ${m.downtimeMinutes} min',
                style: TextStyle(
                  color: VistarPalette.txt2,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              Text(
                'Items: ${m.itemsCompleted}/${m.itemsTotal} done',
                style: TextStyle(
                  color: m.itemsIncomplete > 0
                      ? VistarPalette.warn
                      : VistarPalette.ok,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          if (m.downtimeReasons.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in m.downtimeReasons)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: VistarPalette.warnBg,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: VistarPalette.warnLine),
                    ),
                    child: Text(
                      '${r.reasonName} · ${r.minutes}m',
                      style: TextStyle(
                        color: VistarPalette.warnInk,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(String label, String value, {Color? color}) {
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
            fontWeight: FontWeight.w800,
            fontSize: 15,
            color: color,
          ),
        ),
      ],
    );
  }
}
