import 'package:flutter/material.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/dpl_constants.dart';

/// Colour-coded pill for plan / item status.
class DplStatusBadge extends StatelessWidget {
  final String status;
  final EdgeInsets padding;
  final double fontSize;

  const DplStatusBadge({
    super.key,
    required this.status,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    this.fontSize = 11,
  });

  Color _bg() {
    switch (status) {
      case DplPlanStatus.draft:
        return VistarPalette.surface3;
      case DplPlanStatus.published:
        return VistarPalette.infoBg;
      case DplPlanStatus.inProgress:
        return VistarPalette.warnBg;
      case DplPlanStatus.completed:
        return VistarPalette.okBg;
      case DplPlanStatus.locked:
        return VistarPalette.surface3;
      case 'pending':
        return VistarPalette.surface3;
      default:
        return VistarPalette.surface3;
    }
  }

  Color _fg() {
    switch (status) {
      case DplPlanStatus.draft:
        return VistarPalette.txt2;
      case DplPlanStatus.published:
        return VistarPalette.info;
      case DplPlanStatus.inProgress:
        return VistarPalette.warn;
      case DplPlanStatus.completed:
        return VistarPalette.ok;
      case DplPlanStatus.locked:
        return VistarPalette.txt;
      case 'pending':
        return VistarPalette.txt2;
      default:
        return VistarPalette.txt2;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: _bg(),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        DplPlanStatus.label(status),
        style: TextStyle(
          color: _fg(),
          fontWeight: FontWeight.w700,
          fontSize: fontSize,
        ),
      ),
    );
  }
}
