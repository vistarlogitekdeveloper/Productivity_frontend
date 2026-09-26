import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/vistar_palette.dart';
import 'vistar_brand.dart';

/// The S breathing between 0.92× and 1.04× (`@keyframes breathe`), with the
/// pink drop-shadow glow from the design system.
class VistarBreathingS extends StatefulWidget {
  final double size;
  final Duration period;

  /// Blur of the pink glow, in logical px (CSS `drop-shadow` radius).
  final double glow;

  const VistarBreathingS({
    super.key,
    required this.size,
    this.period = const Duration(milliseconds: 2200),
    this.glow = 26,
  });

  @override
  State<VistarBreathingS> createState() => _VistarBreathingSState();
}

class _VistarBreathingSState extends State<VistarBreathingS>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.period.inMilliseconds ~/ 2),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mark = Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        // drop-shadow(0 0 26px rgba(224,33,138,.55)) — a blurred, pink-tinted
        // copy of the mark so the glow follows the swoosh's shape.
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: widget.glow / 2,
            sigmaY: widget.glow / 2,
            tileMode: TileMode.decal,
          ),
          child: VistarMark(
            size: widget.size,
            tint: VistarPalette.pink.withValues(alpha: 0.55),
          ),
        ),
        VistarMark(size: widget.size),
      ],
    );

    return AnimatedBuilder(
      animation: _c,
      child: mark,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_c.value);
        return Transform.translate(
          offset: Offset(0, 2 - 4 * t),
          child: Transform.scale(scale: 0.92 + 0.12 * t, child: child),
        );
      },
    );
  }
}

/// `.s-orbit` — two counter-spinning rings around a breathing S. The splash
/// loader, and the loader for long hand-offs.
///
/// [size] is the S itself (96 in the spec); the rings take ~2.08× that.
class VistarOrbitLoader extends StatefulWidget {
  final double size;
  final bool showRings;

  const VistarOrbitLoader({super.key, this.size = 96, this.showRings = true});

  @override
  State<VistarOrbitLoader> createState() => _VistarOrbitLoaderState();
}

class _VistarOrbitLoaderState extends State<VistarOrbitLoader>
    with TickerProviderStateMixin {
  late final AnimationController _r1 = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();
  late final AnimationController _r2 = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat();

  @override
  void dispose() {
    _r1.dispose();
    _r2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = widget.size * (200 / 96);
    final inset = box * 0.11;

    return SizedBox(
      width: widget.showRings ? box : widget.size,
      height: widget.showRings ? box : widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.showRings) ...[
            // .r1 — top pink / right orange, 1.6s clockwise.
            RotationTransition(
              turns: _r1,
              child: CustomPaint(
                size: Size.square(box),
                painter: const _OrbitRingPainter(
                  top: Color(0xA6E0218A),
                  right: Color(0x66F06000),
                ),
              ),
            ),
            // .r2 — inset 22px, bottom violet / left amber, 2.2s reverse.
            RotationTransition(
              turns: ReverseAnimation(_r2),
              child: CustomPaint(
                size: Size.square(box - inset * 2),
                painter: const _OrbitRingPainter(
                  bottom: Color(0xA69B30C9),
                  left: Color(0x73F0C000),
                ),
              ),
            ),
          ],
          VistarBreathingS(size: widget.size),
        ],
      ),
    );
  }
}

/// A circle drawn as up to four quarter-arcs — the CSS trick of colouring
/// individual borders of a round element.
class _OrbitRingPainter extends CustomPainter {
  final Color? top;
  final Color? right;
  final Color? bottom;
  final Color? left;

  const _OrbitRingPainter({this.top, this.right, this.bottom, this.left});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.75);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..isAntiAlias = true;
    void quarter(Color? c, double centre) {
      if (c == null) return;
      canvas.drawArc(rect, centre - math.pi / 4, math.pi / 2, false,
          paint..color = c);
    }

    quarter(top, -math.pi / 2);
    quarter(right, 0);
    quarter(bottom, math.pi / 2);
    quarter(left, math.pi);
  }

  @override
  bool shouldRepaint(covariant _OrbitRingPainter old) =>
      old.top != top ||
      old.right != right ||
      old.bottom != bottom ||
      old.left != left;
}

/// `.splash-bar` — a ribbon segment sweeping across a faint track.
class VistarRibbonBar extends StatefulWidget {
  final double width;
  final double height;

  const VistarRibbonBar({super.key, this.width = 200, this.height = 4});

  @override
  State<VistarRibbonBar> createState() => _VistarRibbonBarState();
}

class _VistarRibbonBarState extends State<VistarRibbonBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seg = widget.width * 0.4;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: widget.width,
        height: widget.height,
        color: VistarPalette.isDark
            ? const Color(0x12FFFFFF)
            : const Color(0x142A1850),
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            // translateX(-110%) → translateX(360%) of the 40% segment.
            final t = Curves.easeInOut.transform(_c.value);
            final dx = seg * (-1.1 + 4.7 * t);
            return Stack(
              children: [
                Positioned(
                  left: dx,
                  top: 0,
                  bottom: 0,
                  width: seg,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: VistarPalette.ribbonFlat,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────
// Route-change loader
// ───────────────────────────────────────────────────────────────────

/// Flashes the breathing-S overlay for ~360ms whenever a full screen is
/// pushed, popped or replaced (`#routeload` in the design system).
///
/// Purely visual: the overlay ignores pointers, so it never delays a tap or
/// changes what the navigator does. Dialogs, sheets and menus don't trigger
/// it — only [PageRoute]s.
class VistarRouteLoader extends NavigatorObserver {
  VistarRouteLoader._();

  static final VistarRouteLoader instance = VistarRouteLoader._();

  /// Global switch — flip to false to drop the overlay without touching
  /// the router.
  static bool enabled = true;

  /// Bumped on every screen switch; [VistarRouteLoaderOverlay] listens.
  final ValueNotifier<int> ticks = ValueNotifier<int>(0);

  bool _primed = false;

  void _flash(Route<dynamic>? route) {
    if (!enabled || route is! PageRoute) return;
    // The very first route is covered by the splash — don't stack loaders.
    if (!_primed) {
      _primed = true;
      return;
    }
    ticks.value++;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _flash(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _flash(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _flash(newRoute);
}

/// Hosts the route-change loader above the navigator. Mounted once, in
/// `MaterialApp.builder`.
class VistarRouteLoaderOverlay extends StatefulWidget {
  final Widget child;

  const VistarRouteLoaderOverlay({super.key, required this.child});

  @override
  State<VistarRouteLoaderOverlay> createState() =>
      _VistarRouteLoaderOverlayState();
}

class _VistarRouteLoaderOverlayState extends State<VistarRouteLoaderOverlay>
    with SingleTickerProviderStateMixin {
  // 360ms visible: quick fade in, hold, fade out.
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );
  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 22),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 48),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 30),
  ]).animate(_c);

  @override
  void initState() {
    super.initState();
    VistarRouteLoader.instance.ticks.addListener(_onTick);
  }

  @override
  void dispose() {
    VistarRouteLoader.instance.ticks.removeListener(_onTick);
    _c.dispose();
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    _c.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                if (!_c.isAnimating) return const SizedBox.shrink();
                return Opacity(
                  opacity: _opacity.value,
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                    child: ColoredBox(
                      color: VistarPalette.scrim,
                      child: const Center(
                        child: VistarBreathingS(
                          size: 64,
                          glow: 18,
                          period: Duration(milliseconds: 1000),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ───────────────────────────────────────────────────────────────────
// Splash
// ───────────────────────────────────────────────────────────────────

/// Cold-start splash: orbit loader, wordmark, tagline and ribbon bar over a
/// glowing page. Covers the app for ~2.2s while the router and session
/// restore settle underneath, then fades away. Shown once per launch.
class VistarSplashGate extends StatefulWidget {
  final Widget child;

  /// Total time on screen, including the fade-out.
  final Duration duration;

  const VistarSplashGate({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 2200),
  });

  @override
  State<VistarSplashGate> createState() => _VistarSplashGateState();
}

class _VistarSplashGateState extends State<VistarSplashGate>
    with SingleTickerProviderStateMixin {
  static const _fade = Duration(milliseconds: 380);

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _done = true);
      }
    });
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    final fadeStart =
        1 - _fade.inMilliseconds / widget.duration.inMilliseconds;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, child) {
              final v = _c.value;
              final o = v < fadeStart
                  ? 1.0
                  : (1 - (v - fadeStart) / (1 - fadeStart)).clamp(0.0, 1.0);
              return Opacity(opacity: o, child: child);
            },
            child: const VistarSplash(),
          ),
        ),
      ],
    );
  }
}

/// The splash artwork on its own (also used by previews).
class VistarSplash extends StatelessWidget {
  const VistarSplash({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = VistarPalette.isDark;
    return Material(
      color: VistarPalette.bg,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.15),
            radius: 1.1,
            colors: dark
                ? const [Color(0xFF1A1030), Color(0xFF070611)]
                : const [Color(0xFFFFFFFF), Color(0xFFF1ECF8)],
          ),
        ),
        child: Stack(
          children: [
            // Soft brand bloom behind the orbit.
            Center(
              child: Container(
                width: 420,
                height: 420,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      VistarPalette.pink.withValues(alpha: dark ? 0.16 : 0.08),
                      VistarPalette.pink.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const VistarOrbitLoader(size: 96),
                    const SizedBox(height: 18),
                    const VistarWordmark(height: 78),
                    const SizedBox(height: 14),
                    Text(
                      'THE PULSE OF YOUR SHOP FLOOR',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.manrope(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 3,
                        color: VistarPalette.txt3,
                      ),
                    ),
                    const SizedBox(height: 26),
                    const VistarRibbonBar(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
