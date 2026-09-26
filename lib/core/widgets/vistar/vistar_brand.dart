import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/vistar_palette.dart';

/// Brand asset paths. Generated from the master artwork
/// (`assets/images/logo.png` = the "S" swoosh, `vistar_logo.png` = the
/// Vistar Pulse wordmark): transparent, cropped tight, resized.
abstract final class VistarAssets {
  /// S mark, 360px — loaders, page watermark, card-corner accent.
  static const String mark = 'assets/images/vistar_mark.png';

  /// S mark, 140px — sidebar glyph, app-bar glyph, login mini-mark.
  static const String markSmall = 'assets/images/vistar_mark_sm.png';

  /// Wordmark, 486px (+2x) — splash and login only.
  static const String wordmark = 'assets/images/vistar_wordmark.png';

  /// 120px tileable grain for the ambient background.
  static const String grain = 'assets/images/vistar_grain.png';
}

/// The Vistar "S" swoosh.
///
/// Picks the small or large raster by the physical pixels it will occupy, so
/// a 28pt glyph doesn't decode the 360px file and a 96pt loader stays crisp.
/// [tint] paints the whole mark in one colour (used for quiet watermarks).
class VistarMark extends StatelessWidget {
  final double size;
  final double opacity;
  final Color? tint;

  /// Shown if the raster can't be loaded (e.g. a stripped test bundle).
  final Widget? fallback;

  const VistarMark({
    super.key,
    required this.size,
    this.opacity = 1,
    this.tint,
    this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
    final asset = size * dpr <= 150 ? VistarAssets.markSmall : VistarAssets.mark;
    return SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        asset,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        opacity: opacity >= 1 ? null : AlwaysStoppedAnimation<double>(opacity),
        color: tint,
        colorBlendMode: tint == null ? null : BlendMode.srcIn,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => fallback ?? const SizedBox.shrink(),
      ),
    );
  }
}

/// The full Vistar Pulse wordmark. Splash and login only — everywhere else
/// the product is identified by the S mark plus a Bricolage name.
class VistarWordmark extends StatelessWidget {
  final double height;

  const VistarWordmark({super.key, this.height = 64});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      VistarAssets.wordmark,
      height: height,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'Vistar Pulse',
      errorBuilder: (_, _, _) => Text(
        'Vistar Pulse',
        style: GoogleFonts.bricolageGrotesque(
          fontSize: height * 0.42,
          fontWeight: FontWeight.w800,
          color: VistarPalette.magenta,
          letterSpacing: -0.4,
        ),
      ),
    );
  }
}

/// Text painted with the rainbow ribbon (`background-clip: text`). For one
/// accent word in a headline or a KPI numeral — never a paragraph.
class VistarRibbonText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final Gradient gradient;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  const VistarRibbonText(
    this.text, {
    super.key,
    this.style,
    this.gradient = VistarPalette.ribbonFlat,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) =>
          gradient.createShader(Offset.zero & bounds.size),
      child: Text(
        text,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
        style: (style ?? const TextStyle()).copyWith(color: Colors.white),
      ),
    );
  }
}

/// `.sect-ttl` — section title led by a 5×16 ribbon tick.
class VistarSectionTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  const VistarSectionTitle(
    this.title, {
    super.key,
    this.trailing,
    this.padding = const EdgeInsets.only(bottom: 13),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Container(
            width: 5,
            height: 16,
            decoration: BoxDecoration(
              gradient: VistarPalette.ribbonVertical,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              title,
              style: GoogleFonts.manrope(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: VistarPalette.txt,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Rounded-square avatar on the ribbon with the user's initials.
class VistarAvatar extends StatelessWidget {
  final String name;
  final double size;
  final bool circle;

  const VistarAvatar({
    super.key,
    required this.name,
    this.size = 38,
    this.circle = false,
  });

  static String initialsOf(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'[\s@._-]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'U';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: VistarPalette.ribbon,
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(size * 0.3),
        boxShadow: [
          BoxShadow(
            color: VistarPalette.pink.withValues(alpha: 0.28),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        initialsOf(name),
        style: GoogleFonts.bricolageGrotesque(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.38,
          height: 1,
        ),
      ),
    );
  }
}
