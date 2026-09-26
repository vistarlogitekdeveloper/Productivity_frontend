import 'package:flutter/material.dart';

import '../../../../core/widgets/vistar/vistar_ambient.dart';
import '../design/dpl_theme.dart';

/// Base card surface used across DPL screens. Card surface, large radius,
/// hairline border, soft shadow, optional [accentColor] left border for
/// status indication, optional [onTap] for ripple.
///
/// Carries the Vistar Premium card accent: a faint S tucked into the
/// bottom-right corner ([showCornerMark]).
class DplCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? accentColor;
  final VoidCallback? onTap;
  final double radius;
  final bool showCornerMark;

  const DplCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(DplSpacing.lg),
    this.margin,
    this.accentColor,
    this.onTap,
    this.radius = DplRadius.lg,
    this.showCornerMark = true,
  });

  @override
  Widget build(BuildContext context) {
    final accent = accentColor;
    final borderRadius = BorderRadius.circular(radius);

    // The accent is painted as a strip rather than a coloured left border:
    // Flutter can't combine a 4px accent side with hairline sides on a
    // rounded box (non-uniform border colours).
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: borderRadius,
        boxShadow: DplShadows.card,
        border: Border.all(color: DplColors.divider),
      ),
      child: Stack(
        // passthrough: the child keeps exactly the constraints it had before
        // the corner mark existed, so cards still stretch to fill lists.
        fit: StackFit.passthrough,
        children: [
          Padding(padding: padding, child: child),
          if (accent != null)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 4,
              child: ColoredBox(color: accent),
            ),
          if (showCornerMark) const VistarCornerMark(size: 110),
        ],
      ),
    );

    final clipped = ClipRRect(
      borderRadius: borderRadius,
      child: surface,
    );

    final content = onTap == null
        ? clipped
        : Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: borderRadius,
              onTap: onTap,
              child: clipped,
            ),
          );

    if (margin == null) return content;
    return Padding(padding: margin!, child: content);
  }
}
