import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/vistar_palette.dart';

/// `.btn-grad` — the rainbow-ribbon primary button.
///
/// Reserved for the one primary action on a surface (Sign in, Submit,
/// Start). On hover the ribbon slides and the button lifts a pixel.
/// Disabled renders as a quiet surface so it never competes with an
/// enabled ribbon elsewhere.
class VistarRibbonButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget child;
  final IconData? icon;
  final double height;
  final EdgeInsetsGeometry padding;

  const VistarRibbonButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.height = 50,
    this.padding = const EdgeInsets.symmetric(horizontal: 18),
  });

  @override
  State<VistarRibbonButton> createState() => _VistarRibbonButtonState();
}

class _VistarRibbonButtonState extends State<VistarRibbonButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final radius = BorderRadius.circular(VistarPalette.rSm);

    final label = DefaultTextStyle.merge(
      style: GoogleFonts.manrope(
        fontWeight: FontWeight.w700,
        fontSize: 15,
        color: enabled ? Colors.white : VistarPalette.txt3,
      ),
      child: IconTheme.merge(
        data: IconThemeData(
          color: enabled ? Colors.white : VistarPalette.txt3,
          size: 19,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon),
              const SizedBox(width: 9),
            ],
            Flexible(child: widget.child),
          ],
        ),
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        height: widget.height,
        transform: Matrix4.translationValues(0, enabled && _hover ? -1 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: radius,
          color: enabled ? null : VistarPalette.surface3,
          // background-size:160% → hover slides to background-position:100%.
          gradient: enabled
              ? LinearGradient(
                  begin: _hover
                      ? const Alignment(-1.6, -0.55)
                      : const Alignment(-1.0, -0.55),
                  end: _hover
                      ? const Alignment(1.0, 0.55)
                      : const Alignment(1.6, 0.55),
                  colors: VistarPalette.ribbonStops,
                  stops: VistarPalette.ribbonPositions,
                )
              : null,
          border: enabled ? null : Border.all(color: VistarPalette.line),
          boxShadow: enabled
              ? const [
                  // 0 14px 34px -14px rgba(224,33,138,.7)
                  BoxShadow(
                    color: Color(0xB3E0218A),
                    blurRadius: 34,
                    spreadRadius: -14,
                    offset: Offset(0, 14),
                  ),
                ]
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: widget.onPressed,
            splashColor: Colors.white.withValues(alpha: 0.18),
            highlightColor: Colors.white.withValues(alpha: 0.06),
            child: Padding(
              padding: widget.padding,
              child: Center(child: label),
            ),
          ),
        ),
      ),
    );
  }
}
