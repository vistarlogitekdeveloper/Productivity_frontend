import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../models/dpl_supervisor_today.dart';
import '../../supervisor/widgets/live_timer_text.dart';
import '../providers/dpl_manager_active_downtimes_provider.dart';
import 'active_downtime_details_sheet.dart';

/// Global sticky red banner shown above the manager's screen content
/// whenever any plan has an active downtime — mirrors the supervisor
/// banner with a live-ticking duration, but routes taps to the
/// manager's plan-detail screen (`/dpl/manager/plans/:id`).
class ManagerDowntimeBanner extends ConsumerWidget {
  const ManagerDowntimeBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downtime = ref.watch(managerFirstActiveDowntimeProvider);
    if (downtime == null) return const SizedBox.shrink();

    final machineLabel = (downtime.machineName ?? '').trim().isEmpty
        ? null
        : downtime.machineName!.trim();
    final reasonLabel = downtime.reasonName.trim().isEmpty
        ? 'Active'
        : downtime.reasonName.trim();
    final headline = machineLabel == null
        ? 'DOWNTIME: $reasonLabel'
        : 'DOWNTIME on $machineLabel: $reasonLabel';
    final subline = _buildSubline(downtime);

    return Material(
      color: VistarPalette.badSolid,
      child: InkWell(
        onTap: () => showManagerActiveDowntimeDetailsSheet(
          context,
          downtime: downtime,
        ),
        child: SafeArea(
          top: false,
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headline,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subline != null)
                        Text(
                          subline,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                LiveTimerText(
                  startTime: downtime.startTime,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.chevron_right,
                  color: Colors.white,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? _buildSubline(ActiveDowntime downtime) {
    final parts = <String>[];
    final supervisor = (downtime.supervisorName ?? '').trim();
    if (supervisor.isNotEmpty) parts.add('Supervisor: $supervisor');
    final shift = (downtime.shiftCode ?? '').trim();
    if (shift.isNotEmpty) parts.add('Shift $shift');
    if (parts.isEmpty) return null;
    return parts.join('  •  ');
  }
}
