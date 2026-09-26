import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../manager/widgets/status_badge.dart';
import '../../models/dpl_supervisor_today.dart';
import 'live_timer_text.dart';

/// Big, tappable machine card used on the Supervisor Dashboard.
/// Shows plan/actual/completion, supervisor status, and a sticky red
/// downtime sub-banner when a downtime is active.
class MachineTileLarge extends StatelessWidget {
  final SupervisorPlanSummary plan;
  final VoidCallback onTap;

  const MachineTileLarge({
    super.key,
    required this.plan,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final pct = (plan.completionPct * 100).round();
    final down = plan.activeDowntime;
    final isPhone = MediaQuery.of(context).size.width < 600;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(isPhone ? 14 : 18),
        child: Ink(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(isPhone ? 14 : 18),
            border: Border.all(color: VistarPalette.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.all(isPhone ? 11 : 16),
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
                            style: TextStyle(
                              fontSize: isPhone ? 16 : 20,
                              fontWeight: FontWeight.w900,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DplStatusBadge(status: plan.status),
                      ],
                    ),
                    SizedBox(height: isPhone ? 8 : 14),
                    Row(
                      children: [
                        Expanded(
                          child: _kv(
                            label: 'Plan',
                            value: fmt.format(plan.totalPlanQty),
                            color: VistarPalette.info,
                            isPhone: isPhone,
                          ),
                        ),
                        Expanded(
                          child: _kv(
                            label: 'Actual',
                            value: fmt.format(plan.totalActualQty),
                            color: VistarPalette.ok,
                            isPhone: isPhone,
                          ),
                        ),
                        Expanded(
                          child: _kv(
                            label: 'Completion',
                            value: '$pct%',
                            color: VistarPalette.warn,
                            isPhone: isPhone,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: isPhone ? 6 : 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: plan.completionPct,
                        minHeight: isPhone ? 5 : 8,
                        backgroundColor: VistarPalette.surface3,
                      ),
                    ),
                    SizedBox(height: isPhone ? 6 : 10),
                    Text(
                      '${plan.itemsCompleted} done · '
                      '${plan.itemsInProgress} running · '
                      '${plan.itemsPending} pending',
                      style: TextStyle(
                        color: VistarPalette.txt2,
                        fontWeight: FontWeight.w600,
                        fontSize: isPhone ? 11 : 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (down != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: VistarPalette.badSolid,
                    borderRadius: BorderRadius.vertical(
                      bottom: Radius.circular(17),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          color: Colors.white, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'DOWNTIME: ${down.reasonName.isEmpty ? "Active" : down.reasonName}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      LiveTimerText(
                        startTime: down.startTime,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv({
    required String label,
    required String value,
    required Color color,
    required bool isPhone,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: isPhone ? 10 : 11,
            color: VistarPalette.txt2,
            fontWeight: FontWeight.w600,
            height: 1.1,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        SizedBox(height: isPhone ? 2 : 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              fontSize: isPhone ? 18 : 22,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}
