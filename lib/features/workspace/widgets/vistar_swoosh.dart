import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/widgets/vistar/vistar_brand.dart';
import '../../../core/widgets/vistar/vistar_loaders.dart';

/// The Vistar "S" swoosh.
///
/// Renders the real mark (`assets/images/vistar_mark*.png`, cut from the
/// master `logo.png`). The vector painter below is kept as the fallback for
/// bundles where the raster is missing, so the launcher never shows a hole.
class VistarSwoosh extends StatelessWidget {
  final double size;
  final double opacity;

  /// Paint every band in this single color instead of the ribbon. Used
  /// where the swoosh has to sit quietly behind content.
  final Color? tint;

  const VistarSwoosh({
    super.key,
    required this.size,
    this.opacity = 1.0,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return VistarMark(
      size: size,
      opacity: opacity,
      tint: tint,
      fallback: Opacity(
        opacity: opacity,
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _VistarSwooshPainter(tint: tint)),
        ),
      ),
    );
  }
}

class _Band {
  final Color color;
  final double width;

  /// Distance the band's centre is pushed along the ribbon normal, so the
  /// outer edges of every band line up instead of nesting concentrically.
  final double offset;

  const _Band(this.color, this.width, this.offset);
}

class _VistarSwooshPainter extends CustomPainter {
  final Color? tint;

  const _VistarSwooshPainter({this.tint});

  // Outer edge → core. Widths and offsets are fractions of the box.
  static const List<_Band> _bands = <_Band>[
    _Band(Color(0xFFD24BD2), 0.150, 0.000),
    _Band(Color(0xFF7A1FB0), 0.120, 0.015),
    _Band(Color(0xFFC8102E), 0.098, 0.026),
    _Band(Color(0xFFF0480C), 0.078, 0.036),
    _Band(Color(0xFFF06000), 0.062, 0.044),
    _Band(Color(0xFFF0C000), 0.048, 0.051),
    _Band(Color(0xFFF7EE9A), 0.034, 0.058),
    _Band(Color(0xFFFFF6CC), 0.020, 0.065),
  ];

  /// Unit normal of the ribbon, pointing from the outer edge toward the
  /// core (down-right, perpendicular to the overall upper-right →
  /// lower-left flow).
  static final double _n = 1 / math.sqrt2;

  /// Half-thickness of the whole band stack, as a fraction of the box.
  /// Equals `_bands.first.width / 2` — the stack is symmetric about the
  /// spine — with a hair of slack so the clip never bites into the ink.
  static const double _halfStack = 0.078;

  /// Fraction of the curve each tip tapers over.
  static const double _tipRun = 0.30;

  @override
  void paint(Canvas canvas, Size size) {
    final box = math.min(size.width, size.height);
    // Inset so the widest stroke stays inside the painted box.
    final pad = box * 0.10;
    final span = box - pad * 2;

    Offset p(double x, double y) => Offset(pad + x * span, pad + y * span);

    final spine = Path()
      ..moveTo(p(1.00, 0.10).dx, p(1.00, 0.10).dy)
      ..cubicTo(
        p(0.72, 0.14).dx,
        p(0.72, 0.14).dy,
        p(0.40, 0.14).dx,
        p(0.40, 0.14).dy,
        p(0.36, 0.34).dx,
        p(0.36, 0.34).dy,
      )
      ..cubicTo(
        p(0.32, 0.53).dx,
        p(0.32, 0.53).dy,
        p(0.68, 0.48).dx,
        p(0.68, 0.48).dy,
        p(0.66, 0.66).dx,
        p(0.66, 0.66).dy,
      )
      ..cubicTo(
        p(0.64, 0.86).dx,
        p(0.64, 0.86).dy,
        p(0.30, 0.86).dx,
        p(0.30, 0.86).dy,
        p(0.00, 0.90).dx,
        p(0.00, 0.90).dy,
      );

    // The bands are uniform-width strokes; clipping them to a tapered
    // envelope is what pulls both ends out to the needle tips the
    // printed mark has.
    canvas.save();
    canvas.clipPath(_taperEnvelope(spine, _halfStack * span), doAntiAlias: true);

    for (final band in _bands) {
      final shift = band.offset * span * _n;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = band.width * span
        ..strokeCap = StrokeCap.butt
        ..strokeJoin = StrokeJoin.round
        ..color = tint ?? band.color
        ..isAntiAlias = true;
      canvas.drawPath(spine.shift(Offset(shift, shift)), paint);
    }

    canvas.restore();
  }

  /// Outline of the ribbon: the spine walked at ±`maxHalfWidth`, with the
  /// width easing to zero over [_tipRun] at each end.
  static Path _taperEnvelope(Path spine, double maxHalfWidth) {
    final metric = spine.computeMetrics().first;
    final length = metric.length;
    const steps = 220;

    final upper = <Offset>[];
    final lower = <Offset>[];

    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final tangent = metric.getTangentForOffset(t * length);
      if (tangent == null) continue;
      final v = tangent.vector; // already unit length
      final normal = Offset(-v.dy, v.dx);
      final halfWidth = maxHalfWidth * _taper(t);
      upper.add(tangent.position + normal * halfWidth);
      lower.add(tangent.position - normal * halfWidth);
    }

    final path = Path()..moveTo(upper.first.dx, upper.first.dy);
    for (final o in upper.skip(1)) {
      path.lineTo(o.dx, o.dy);
    }
    for (final o in lower.reversed) {
      path.lineTo(o.dx, o.dy);
    }
    return path..close();
  }

  /// 0 at both tips, 1 across the body — raised to a power below 1 so the
  /// tips stay slender for longer instead of flaring linearly.
  static double _taper(double t) {
    final ramp = math.min(math.min(t, 1 - t) / _tipRun, 1.0);
    return math.pow(ramp, 0.5).toDouble();
  }

  @override
  bool shouldRepaint(covariant _VistarSwooshPainter oldDelegate) =>
      oldDelegate.tint != tint;
}

/// The splash / route-change loader from the Vistar design system: the
/// mark breathing between 0.92× and 1.04× inside two counter-spinning
/// rings. Delegates to the shared [VistarOrbitLoader].
class VistarBreathingMark extends StatelessWidget {
  final double size;
  final bool showRings;

  const VistarBreathingMark({super.key, this.size = 96, this.showRings = true});

  @override
  Widget build(BuildContext context) =>
      VistarOrbitLoader(size: size, showRings: showRings);
}
