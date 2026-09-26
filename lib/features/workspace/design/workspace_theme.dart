import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/theme/vistar_palette.dart';

// The launcher reads the shared Vistar Premium palette. Re-exported so the
// workspace files keep importing a single design file.
export '../../../core/theme/vistar_palette.dart' show VistarPalette;

/// Typography: Bricolage Grotesque for display, Manrope for everything
/// else — exactly the pairing the design system specifies.
///
/// Colors default to the active palette's ink, so the same call reads
/// correctly in light and dark mode.
class VistarType {
  const VistarType._();

  static TextStyle display({
    required double size,
    FontWeight weight = FontWeight.w800,
    Color? color,
    double height = 1.08,
  }) => GoogleFonts.bricolageGrotesque(
    fontSize: size,
    fontWeight: weight,
    color: color ?? VistarPalette.txt,
    height: height,
    letterSpacing: -0.4,
  );

  static TextStyle body({
    required double size,
    FontWeight weight = FontWeight.w500,
    Color? color,
    double height = 1.45,
    double letterSpacing = 0.1,
  }) => GoogleFonts.manrope(
    fontSize: size,
    fontWeight: weight,
    color: color ?? VistarPalette.txt2,
    height: height,
    letterSpacing: letterSpacing,
  );

  /// Uppercase micro-label (group headers, taglines above titles).
  static TextStyle overline({Color? color, double size = 11}) =>
      GoogleFonts.manrope(
        fontSize: size,
        fontWeight: FontWeight.w700,
        color: color ?? VistarPalette.txt3,
        letterSpacing: 2.4,
      );
}

/// Local [ThemeData] for the launcher, in the active brightness. Applied
/// with a `Theme(...)` wrapper so Material widgets (inputs, chips,
/// tooltips) pick up the portal palette.
ThemeData vistarWorkspaceTheme() {
  final base = VistarPalette.isDark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: VistarPalette.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: VistarPalette.pink,
      onPrimary: Colors.white,
      secondary: VistarPalette.violet,
      surface: VistarPalette.surface,
      onSurface: VistarPalette.txt,
      error: VistarPalette.bad,
    ),
    textTheme: GoogleFonts.manropeTextTheme(
      base.textTheme,
    ).apply(bodyColor: VistarPalette.txt, displayColor: VistarPalette.txt),
    dividerColor: VistarPalette.line,
    splashFactory: InkSparkle.splashFactory,
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: VistarPalette.surface3,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: VistarPalette.line2),
      ),
      textStyle: VistarType.body(size: 12, color: VistarPalette.txt),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: VistarPalette.surface,
      hintStyle: VistarType.body(size: 14, color: VistarPalette.txt3),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VistarPalette.rSm),
        borderSide: BorderSide(color: VistarPalette.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VistarPalette.rSm),
        borderSide: BorderSide(color: VistarPalette.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VistarPalette.rSm),
        borderSide: BorderSide(
          color: VistarPalette.pink.withValues(alpha: 0.6),
          width: 1.4,
        ),
      ),
    ),
  );
}
