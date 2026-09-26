import 'package:flutter/material.dart';

import '../../../../core/theme/vistar_palette.dart';

/// Compact "Shift A" / "Shifts A, B" pill used on plan headers + item
/// rows so the supervisor / manager can see which shift owns the work.
class DplShiftChip extends StatelessWidget {
  final String label;
  final double fontSize;
  final EdgeInsetsGeometry padding;

  const DplShiftChip({
    super.key,
    required this.label,
    this.fontSize = 11,
    this.padding =
        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
  });

  @override
  Widget build(BuildContext context) {
    // Violet shift hue; lifted on dark surfaces so the label stays legible.
    final color = VistarPalette.isDark
        ? const Color(0xFFB794F6)
        : const Color(0xFF7C3AED);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.access_time, size: fontSize + 2, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: fontSize,
            ),
          ),
        ],
      ),
    );
  }
}
