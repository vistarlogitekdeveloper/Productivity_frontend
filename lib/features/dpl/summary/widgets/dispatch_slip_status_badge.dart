import 'package:flutter/material.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_constants.dart';

/// Compact pill rendering a dispatch slip's lifecycle status with the
/// colour palette already used elsewhere in the DPL design system
/// (success / warning / error / neutral pairs from [DplColors]).
class DispatchSlipStatusBadge extends StatelessWidget {
  final String status;
  final bool dense;

  const DispatchSlipStatusBadge({
    super.key,
    required this.status,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = _paletteFor(status);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        DplDispatchSlipStatus.label(status),
        style: TextStyle(
          color: palette.fg,
          fontWeight: FontWeight.w800,
          fontSize: dense ? 10.5 : 11.5,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  _StatusPalette _paletteFor(String status) {
    switch (status) {
      case DplDispatchSlipStatus.pendingQa:
      case DplDispatchSlipStatus.pendingDeo:
      case DplDispatchSlipStatus.pendingPdi:
        return _StatusPalette(DplColors.warning, DplColors.warningBg);
      case DplDispatchSlipStatus.approved:
        return _StatusPalette(DplColors.info, DplColors.infoBg);
      case DplDispatchSlipStatus.dispatched:
        return _StatusPalette(DplColors.success, DplColors.successBg);
      case DplDispatchSlipStatus.rejected:
        return _StatusPalette(DplColors.error, DplColors.errorBg);
      default:
        return _StatusPalette(DplColors.neutral, DplColors.neutralBg);
    }
  }
}

class _StatusPalette {
  final Color fg;
  final Color bg;
  const _StatusPalette(this.fg, this.bg);
}
