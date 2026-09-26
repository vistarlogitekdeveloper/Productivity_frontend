import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/widgets/shift_chip.dart';
import '../../manager/widgets/status_badge.dart';
import '../../models/dpl_production_plan_item.dart';

/// Tappable row used on the supervisor machine-plan list. Bigger than the
/// manager version so it's glove-friendly.
class PlanRowCard extends StatelessWidget {
  final DplProductionPlanItem item;
  final VoidCallback onTap;

  const PlanRowCard({
    super.key,
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final timeFmt = DateFormat('HH:mm');
    final pct = (item.completionPct * 100).round();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
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
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: VistarPalette.infoBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '#${item.planNo}',
                      style: TextStyle(
                        color: VistarPalette.info,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.partDescription.isEmpty
                              ? (item.partNumber.isEmpty
                                  ? 'Part #${item.partId}'
                                  : item.partNumber)
                              : item.partDescription,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (item.partName.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              item.partName,
                              style: TextStyle(
                                color: VistarPalette.txt2,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      DplStatusBadge(status: item.status),
                      if (item.pausedAt != null) ...[
                        const SizedBox(height: 4),
                        _PausedChip(pausedAt: item.pausedAt!),
                      ],
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _stat('Plan', fmt.format(item.planQty)),
                  const SizedBox(width: 16),
                  _stat('Actual', fmt.format(item.actualQty)),
                  const Spacer(),
                  Text(
                    '$pct%',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: VistarPalette.txt2,
                    ),
                  ),
                ],
              ),
              if (item.startTime != null ||
                  item.endTime != null ||
                  item.shiftDisplayLabel != null) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (item.shiftDisplayLabel != null)
                      DplShiftChip(label: item.shiftDisplayLabel!),
                    if (item.startTime != null)
                      _chip(
                        icon: Icons.play_arrow_outlined,
                        label: 'Started ${timeFmt.format(item.startTime!.toLocal())}',
                        color: VistarPalette.ok,
                      ),
                    if (item.endTime != null)
                      _chip(
                        icon: Icons.flag_outlined,
                        label: 'Ended ${timeFmt.format(item.endTime!.toLocal())}',
                        color: VistarPalette.info,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Row(
      children: [
        Text(
          '$label: ',
          style: TextStyle(
            color: VistarPalette.txt2,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 14,
          ),
        ),
      ],
    );
  }

  Widget _chip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small "Paused" pill that sits beside the status badge whenever the
/// supervisor has an open item-level pause on this row.
class _PausedChip extends StatelessWidget {
  final DateTime pausedAt;
  const _PausedChip({required this.pausedAt});

  @override
  Widget build(BuildContext context) {
    final color = VistarPalette.warn;
    final timeFmt = DateFormat('HH:mm');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.pause_circle_outline, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            'Paused ${timeFmt.format(pausedAt.toLocal())}',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
