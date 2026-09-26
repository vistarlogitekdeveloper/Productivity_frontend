import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import 'status_badge.dart';

/// Single card on the Manager Dashboard's "Machines" list.
///
/// Now built from values supplied by the parent screen rather than a raw
/// [DplMachineSummary] row, so a machine that has plans across multiple
/// shifts can be rendered as **one** card with multiple shift pills
/// (Shift A · Shift B · Shift C) and totals summed across those shifts.
class DplMachineSummaryCard extends StatelessWidget {
  final String machineName;
  final int machineId;

  /// All shift labels that contribute to this card, e.g.
  /// `['Shift A', 'Shift B']`. Sorted by code by the caller.
  final List<String> shiftLabels;

  /// Highest-priority status across all merged rows (drives the badge).
  final String status;

  final int planQty;
  final int actualQty;
  final double completionPct;

  /// Supervisor display — already merged/joined by the caller (e.g.
  /// `"A shift Supervisor · B shift Supervisor"` when the shifts have
  /// different supervisors).
  final String supervisorName;

  /// Distinct plans on this machine for the selected date. When > 1 the
  /// card surfaces a "N plans" hint so the user expects the picker sheet
  /// instead of being dropped straight onto one plan's detail screen.
  final int planCount;

  final VoidCallback? onTap;

  const DplMachineSummaryCard({
    super.key,
    required this.machineName,
    required this.machineId,
    required this.shiftLabels,
    required this.status,
    required this.planQty,
    required this.actualQty,
    required this.completionPct,
    required this.supervisorName,
    this.planCount = 1,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final pct = (completionPct * 100).round();
    final isPhone = MediaQuery.of(context).size.width < 600;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: EdgeInsets.all(isPhone ? 11 : 14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(isPhone ? 12 : 16),
            border: Border.all(color: VistarPalette.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      machineName.isEmpty
                          ? 'Machine #$machineId'
                          : machineName,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: isPhone ? 14 : 16,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Right edge — shift pills (wraps when there are many)
                  // followed by the status badge. Wrap so a machine with
                  // 3 shifts doesn't squeeze the machine name on narrow
                  // viewports.
                  Flexible(
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: isPhone ? 4 : 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final label in shiftLabels)
                          _ShiftChip(label: label, isPhone: isPhone),
                        DplStatusBadge(status: status),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: isPhone ? 6 : 8),
              Row(
                children: [
                  Expanded(
                    child: _kv(
                      label: 'Plan Qty',
                      value: fmt.format(planQty),
                      isPhone: isPhone,
                    ),
                  ),
                  Expanded(
                    child: _kv(
                      label: 'Actual',
                      value: fmt.format(actualQty),
                      isPhone: isPhone,
                    ),
                  ),
                  Expanded(
                    child: _kv(
                      label: 'Completion',
                      value: '$pct%',
                      isPhone: isPhone,
                    ),
                  ),
                ],
              ),
              SizedBox(height: isPhone ? 6 : 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: completionPct.clamp(0, 1),
                  minHeight: isPhone ? 5 : 6,
                  backgroundColor: VistarPalette.surface3,
                ),
              ),
              SizedBox(height: isPhone ? 6 : 8),
              Row(
                children: [
                  Icon(
                    Icons.person_outline,
                    size: isPhone ? 14 : 16,
                    color: VistarPalette.txt2,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      supervisorName.isEmpty
                          ? 'No supervisor assigned'
                          : supervisorName,
                      style: TextStyle(
                        color: VistarPalette.txt2,
                        fontWeight: FontWeight.w600,
                        fontSize: isPhone ? 12 : 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (planCount > 1) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: isPhone ? 6 : 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: VistarPalette.surface3,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: VistarPalette.line2),
                      ),
                      child: Text(
                        '$planCount plans',
                        style: TextStyle(
                          color: VistarPalette.txt,
                          fontWeight: FontWeight.w700,
                          fontSize: isPhone ? 10 : 11,
                          height: 1.0,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: isPhone ? 12 : 14,
                    color: VistarPalette.txt2,
                  ),
                ],
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
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              fontSize: isPhone ? 14 : 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

/// Compact "Shift A" pill rendered on the machine card title row.
class _ShiftChip extends StatelessWidget {
  final String label;
  final bool isPhone;

  const _ShiftChip({required this.label, required this.isPhone});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isPhone ? 6 : 8,
        vertical: isPhone ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: VistarPalette.infoBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: VistarPalette.infoLine),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: VistarPalette.infoInk,
          fontWeight: FontWeight.w700,
          fontSize: isPhone ? 10 : 11,
          height: 1.0,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
