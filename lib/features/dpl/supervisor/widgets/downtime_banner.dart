import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../providers/today_plans_provider.dart';
import 'live_timer_text.dart';

/// Global sticky red banner shown above the supervisor IndexedStack
/// whenever any plan has an active downtime.
class DowntimeBanner extends ConsumerWidget {
  const DowntimeBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downtime = ref.watch(activeDowntimeProvider);
    if (downtime == null) return const SizedBox.shrink();

    final planId = downtime.planId;
    final itemId = downtime.planItemId;

    return Material(
      color: VistarPalette.badSolid,
      child: InkWell(
        onTap: planId == null
            ? null
            : () {
                if (itemId != null) {
                  context.push(
                    '/dpl/supervisor/machine/$planId/execute/$itemId',
                  );
                } else {
                  context.push('/dpl/supervisor/machine/$planId');
                }
              },
        child: SafeArea(
          top: false,
          bottom: false,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'DOWNTIME: ${downtime.reasonName.isEmpty ? "Active" : downtime.reasonName}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                LiveTimerText(
                  startTime: downtime.startTime,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    fontFamily: 'monospace',
                  ),
                ),
                if (planId != null) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right,
                      color: Colors.white, size: 18),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
