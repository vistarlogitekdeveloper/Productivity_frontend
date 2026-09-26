import 'package:flutter/material.dart';

import '../theme/vistar_palette.dart';

/// Skeleton base + the design system's rainbow sweep (`.skel::after`:
/// transparent → pink 16% → orange 12% → transparent over `--surface2`).
abstract final class VistarSkeleton {
  static Color get base =>
      VistarPalette.isDark ? VistarPalette.surface2 : VistarPalette.surface3;
  static Color get pink =>
      Color.alphaBlend(VistarPalette.pink.withValues(alpha: 0.16), base);
  static Color get orange =>
      Color.alphaBlend(VistarPalette.orange.withValues(alpha: 0.12), base);
}

class AppShimmer extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Color? baseColor;
  final Color? highlightColor;

  const AppShimmer({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 1300),
    this.baseColor,
    this.highlightColor,
  });

  @override
  State<AppShimmer> createState() => _AppShimmerState();
}

class _AppShimmerState extends State<AppShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final custom = widget.highlightColor != null;
    final baseColor = widget.baseColor ?? VistarSkeleton.base;

    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final v = _controller.value;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            if (custom) {
              // Caller-tinted sweep (e.g. white dots on a filled button).
              final highlight = widget.highlightColor!;
              return LinearGradient(
                begin: Alignment(-1.0 + (2 * v), 0),
                end: Alignment(0.0 + (2 * v), 0),
                colors: <Color>[
                  baseColor.withValues(alpha: 0.95),
                  highlight.withValues(alpha: 0.98),
                  baseColor.withValues(alpha: 0.95),
                ],
                stops: const <double>[0.25, 0.5, 0.75],
              ).createShader(bounds);
            }
            // Rainbow sweep: a box-wide band travelling from fully off the
            // left edge (translateX(-100%)) to fully off the right.
            return LinearGradient(
              begin: Alignment(-3.0 + 4 * v, 0),
              end: Alignment(-1.0 + 4 * v, 0),
              colors: <Color>[
                baseColor,
                widget.baseColor == null ? VistarSkeleton.pink : baseColor,
                widget.baseColor == null ? VistarSkeleton.orange : baseColor,
                baseColor,
              ],
              stops: const <double>[0.0, 0.36, 0.64, 1.0],
            ).createShader(bounds);
          },
          child: child,
        );
      },
    );
  }
}

class SkeletonBox extends StatelessWidget {
  final double height;
  final double? width;
  final BorderRadiusGeometry borderRadius;
  final EdgeInsetsGeometry? margin;

  const SkeletonBox({
    super.key,
    required this.height,
    this.width,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final color = VistarSkeleton.base;

    return Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(color: color, borderRadius: borderRadius),
    );
  }
}

class ShimmerCenteredPlaceholder extends StatelessWidget {
  final double verticalPadding;
  final double titleWidth;
  final double subtitleWidth;

  const ShimmerCenteredPlaceholder({
    super.key,
    this.verticalPadding = 28,
    this.titleWidth = 190,
    this.subtitleWidth = 120,
  });

  @override
  Widget build(BuildContext context) {
    return AppShimmer(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: verticalPadding),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SkeletonBox(height: 14, width: titleWidth),
              const SizedBox(height: 10),
              SkeletonBox(height: 12, width: subtitleWidth),
            ],
          ),
        ),
      ),
    );
  }
}

class ShimmerButtonDots extends StatelessWidget {
  final double size;
  final double spacing;

  const ShimmerButtonDots({super.key, this.size = 7, this.spacing = 4});

  @override
  Widget build(BuildContext context) {
    return AppShimmer(
      baseColor: Colors.white54,
      highlightColor: Colors.white,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dot(),
            SizedBox(width: spacing),
            _dot(),
            SizedBox(width: spacing),
            _dot(),
          ],
        ),
      ),
    );
  }

  Widget _dot() {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
    );
  }
}

class ShimmerLinearBar extends StatelessWidget {
  final double height;
  final BorderRadiusGeometry borderRadius;

  const ShimmerLinearBar({
    super.key,
    this.height = 2,
    this.borderRadius = BorderRadius.zero,
  });

  @override
  Widget build(BuildContext context) {
    return AppShimmer(
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: VistarSkeleton.base,
          borderRadius: borderRadius,
        ),
      ),
    );
  }
}

class SkeletonCard extends StatelessWidget {
  final BorderRadiusGeometry borderRadius;
  const SkeletonCard({
    super.key,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
  });

  @override
  Widget build(BuildContext context) {
    return AppShimmer(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.02),
          borderRadius: borderRadius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkeletonBox(height: 14, width: 180),
            const SizedBox(height: 8),
            SkeletonBox(height: 12, width: 120),
            const SizedBox(height: 12),
            Row(
              children: [
                SkeletonBox(
                  height: 10,
                  width: 60,
                  borderRadius: BorderRadius.circular(999),
                ),
                const SizedBox(width: 8),
                SkeletonBox(
                  height: 10,
                  width: 60,
                  borderRadius: BorderRadius.circular(999),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class SkeletonList extends StatelessWidget {
  final int count;
  final double spacing;
  const SkeletonList({super.key, this.count = 4, this.spacing = 10});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        count,
        (i) => Padding(
          padding: EdgeInsets.only(bottom: i == count - 1 ? 0 : spacing),
          child: const SkeletonCard(),
        ),
      ),
    );
  }
}
