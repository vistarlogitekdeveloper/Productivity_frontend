import 'package:flutter/material.dart';

import '../../theme/vistar_palette.dart';
import 'vistar_brand.dart';

/// The ambient page background: three aurora glows over the page colour, a
/// faint oversized S watermark on the right, and a film of grain.
///
/// Paints *behind* content — put it at the bottom of a [Stack] or use
/// [VistarAmbientScaffoldBody].
class VistarAmbient extends StatelessWidget {
  /// Draw the S watermark. Off for small surfaces (dialogs, sheets).
  final bool watermark;

  const VistarAmbient({super.key, this.watermark = true});

  @override
  Widget build(BuildContext context) {
    final dark = VistarPalette.isDark;
    // Daylight glows are kept faint — on a light page the same alphas read
    // as stains rather than light.
    final k = dark ? 1.0 : 0.42;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final vmax = w > h ? w : h;
        final shortest = w < h ? w : h;
        // CSS glows are sized in px (600–900px ellipses); Flutter's radial
        // radius is a fraction of the shortest side. Convert so a phone gets
        // the same ~500px reach instead of a glow a third the size.
        double radius(double px) =>
            shortest <= 0 ? 1 : (px / shortest).clamp(0.8, 2.2);

        return DecoratedBox(
          decoration: BoxDecoration(color: VistarPalette.bg),
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              // radial-gradient(800px 600px at 12% -8%, purple .22)
              _glow(
                center: const Alignment(-0.76, -1.16),
                radius: radius(800),
                color: VistarPalette.purple.withValues(alpha: 0.22 * k),
                stop: 0.6,
              ),
              // radial-gradient(700px 600px at 105% 8%, pink .16)
              _glow(
                center: const Alignment(1.1, -0.84),
                radius: radius(700),
                color: VistarPalette.pink.withValues(alpha: 0.16 * k),
                stop: 0.55,
              ),
              // radial-gradient(900px 700px at 80% 110%, orange .12)
              _glow(
                center: const Alignment(0.6, 1.2),
                radius: radius(900),
                color: VistarPalette.orange.withValues(alpha: 0.12 * k),
                stop: 0.55,
              ),
              if (watermark)
                Positioned(
                  right: -w * 0.06 - vmax * 0.12,
                  top: h / 2 - vmax * 0.31,
                  child: IgnorePointer(
                    child: Transform.rotate(
                      angle: 0.07,
                      child: VistarMark(
                        size: vmax * 0.62,
                        opacity: dark ? 0.05 : 0.045,
                      ),
                    ),
                  ),
                ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      image: DecorationImage(
                        image: const AssetImage(VistarAssets.grain),
                        repeat: ImageRepeat.repeat,
                        opacity: dark ? 0.045 : 0.03,
                        filterQuality: FilterQuality.none,
                        onError: (_, _) {},
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _glow({
    required Alignment center,
    required double radius,
    required Color color,
    required double stop,
  }) {
    return Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: center,
              radius: radius,
              colors: <Color>[color, color.withValues(alpha: 0)],
              stops: <double>[0, stop],
            ),
          ),
        ),
      ),
    );
  }
}

/// Convenience: [VistarAmbient] under [child], filling the available space.
class VistarAmbientScaffoldBody extends StatelessWidget {
  final Widget child;
  final bool watermark;

  const VistarAmbientScaffoldBody({
    super.key,
    required this.child,
    this.watermark = true,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      // The child keeps the constraints it would have had without us.
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(child: VistarAmbient(watermark: watermark)),
        child,
      ],
    );
  }
}

/// `.card .corner-s` — the faint S tucked into a card's bottom-right corner.
/// Place as the last child of a clipped [Stack] inside the card.
class VistarCornerMark extends StatelessWidget {
  final double size;
  final double opacity;

  const VistarCornerMark({super.key, this.size = 120, this.opacity = 0.05});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: -size * 0.22,
      bottom: -size * 0.25,
      child: IgnorePointer(child: VistarMark(size: size, opacity: opacity)),
    );
  }
}
