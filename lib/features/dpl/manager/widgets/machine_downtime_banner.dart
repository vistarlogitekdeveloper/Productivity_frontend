import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../models/dpl_supervisor_today.dart';
import '../../supervisor/widgets/live_timer_text.dart';
import '../providers/dpl_manager_active_downtimes_provider.dart';
import 'active_downtime_details_sheet.dart';

/// Per-machine red downtime strip rendered under a machine card on the
/// Manager / Customer dashboard's "Machines" list.
///
/// Mirrors the global [ManagerDowntimeBanner] visually (red background,
/// warning icon, reason text, live `hh:mm:ss` counter) but scopes its
/// data to a single [machineId] so each card surfaces only the downtime
/// that belongs to it. Hidden when nothing is active on the machine.
class MachineDowntimeBanner extends ConsumerWidget {
  final int machineId;
  final int? planId;

  const MachineDowntimeBanner({
    super.key,
    required this.machineId,
    this.planId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(managerActiveDowntimesProvider);
    final envelope = async.asData?.value;
    if (envelope == null || envelope.isError) return const SizedBox.shrink();
    final list = envelope.data ?? const <ActiveDowntime>[];
    if (list.isEmpty) return const SizedBox.shrink();

    final match = _firstFor(list);
    if (match == null) return const SizedBox.shrink();

    final reasonLabel = match.reasonName.trim().isEmpty
        ? 'Active'
        : match.reasonName.trim();

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: VistarPalette.badSolid,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => showManagerActiveDowntimeDetailsSheet(
            context,
            downtime: match,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.white,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'DOWNTIME: $reasonLabel',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 12.5,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                LiveTimerText(
                  startTime: match.startTime,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  ActiveDowntime? _firstFor(List<ActiveDowntime> list) {
    for (final d in list) {
      if (d.machineId == machineId) return d;
    }
    if (planId != null) {
      for (final d in list) {
        if (d.planId == planId) return d;
      }
    }
    return null;
  }
}
