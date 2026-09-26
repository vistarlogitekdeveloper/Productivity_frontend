import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../core/theme/vistar_palette.dart';

/// Vistar DPL design system.
///
/// Every color, font, spacing, radius, and shadow used in DPL screens
/// comes from here. Hard-coded hex values in screen files are a code
/// smell — search the codebase periodically and pull violations back
/// into this file.
///
/// Colors are getters, not constants: they resolve against the active
/// light / dark [VistarTokens], so a screen that reads `DplColors.cardBg`
/// follows the theme toggle without knowing it exists. The trade-off is
/// that they can't appear inside a `const` expression.

class DplColors {
  const DplColors._();

  static bool get _dark => VistarPalette.isDark;

  // Brand — single primary purple anchored by the Vistar swoosh.
  static Color get primary => VistarPalette.primary;
  static Color get primaryLight =>
      _dark ? const Color(0xFFC387EE) : const Color(0xFF8B3FAC);

  /// Deep purple for text and icons on [primaryTint]. In dark mode this
  /// flips to a light violet so it stays readable on the tinted fill.
  static Color get primaryDark => VistarPalette.primaryInk;
  static Color get primaryTint => VistarPalette.primaryTint;

  // Gradient accent — the Vistar Premium ribbon (purple → pink → red →
  // orange → amber → cream). Use only for hero CTAs (Submit, START,
  // completion rings, login button) and thin accents, never as a large
  // surface.
  static const List<Color> gradientStops = VistarPalette.ribbonStops;
  static const LinearGradient brandGradient = VistarPalette.ribbonFlat;

  // Semantic — pairs of foreground + soft tint background.
  //
  // DPL screens use these both as text colours AND as solid fills behind
  // white text (START / STOP buttons, downtime banners), so in dark mode
  // they take the balanced "solid" tones that hold ~4:1 against white and
  // ~5:1 on the dark page — the pastel `VistarPalette.ok/bad/…` would fail
  // the white-text case.
  static Color get success => VistarPalette.okSolid;
  static Color get successBg => VistarPalette.okBg;
  static Color get warning =>
      _dark ? VistarPalette.warnSolid : const Color(0xFFD97706);
  static Color get warningBg => VistarPalette.warnBg;
  static Color get error =>
      _dark ? VistarPalette.badSolid : const Color(0xFFDC2626);
  static Color get errorBg =>
      _dark ? VistarPalette.badBg : const Color(0xFFFEE2E2);
  static Color get info =>
      _dark ? VistarPalette.infoSolid : const Color(0xFF2563EB);
  static Color get infoBg =>
      _dark ? VistarPalette.infoBg : const Color(0xFFDBEAFE);
  static Color get neutral =>
      _dark ? const Color(0xFF9A93B5) : const Color(0xFF6B6781);
  static Color get neutralBg => VistarPalette.surface3;

  // Status pills (plan / item status colors).
  static Color get statusDraft => neutral;
  static Color get statusPublished => info;
  static Color get statusInProgress => warning;
  static Color get statusCompleted => success;
  static Color get statusLocked =>
      _dark ? const Color(0xFF8C86A6) : const Color(0xFF524C66);

  // Surfaces.
  static Color get pageBg => VistarPalette.bg;
  static Color get cardBg => VistarPalette.surface;
  static Color get divider => VistarPalette.line;

  // Text.
  static Color get textPrimary => VistarPalette.txt;
  static Color get textSecondary => VistarPalette.txt2;
  static Color get textTertiary => VistarPalette.txt3;

  /// Text on a solid primary / status fill — white in both modes.
  static const Color textInverse = Color(0xFFFFFFFF);
}

class DplSpacing {
  const DplSpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
}

class DplRadius {
  const DplRadius._();
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double pill = 999;
}

class DplShadows {
  const DplShadows._();

  static bool get _dark => VistarPalette.isDark;

  /// Soft 2-layer card shadow. On near-black a shadow can't darken the
  /// page, so dark mode swaps it for a deeper, wider bloom.
  static List<BoxShadow> get card => _dark
      ? const [
          BoxShadow(
            color: Color(0x73000000),
            blurRadius: 30,
            spreadRadius: -12,
            offset: Offset(0, 14),
          ),
        ]
      : const [
          BoxShadow(
            color: Color(0x0A2A1850),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
          BoxShadow(
            color: Color(0x122A1850),
            blurRadius: 12,
            offset: Offset(0, 6),
          ),
        ];

  /// Stronger shadow for bottom sheets / modals.
  static List<BoxShadow> get sheet => _dark
      ? const [
          BoxShadow(
            color: Color(0x99000000),
            blurRadius: 32,
            offset: Offset(0, -8),
          ),
        ]
      : const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 8,
            offset: Offset(0, -2),
          ),
          BoxShadow(
            color: Color(0x1F000000),
            blurRadius: 24,
            offset: Offset(0, -8),
          ),
        ];

  /// Top shadow for the bottom navigation bar.
  static List<BoxShadow> get bottomNav => _dark
      ? const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 12,
            offset: Offset(0, -4),
          ),
        ]
      : const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 6,
            offset: Offset(0, -2),
          ),
        ];

  /// Subtle button drop shadow.
  static List<BoxShadow> get button => _dark
      ? const [
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ]
      : const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ];
}

/// Typography scale. All number styles enable tabular figures so
/// digits align cleanly in tables and cards.
///
/// Vistar Premium pairing: Bricolage Grotesque for display text (titles,
/// KPI numerals), Manrope for everything else, Roboto Mono for timers.
class DplText {
  const DplText._();

  static const _tabularFigures = FontFeature.tabularFigures();

  // UI font — Manrope via google_fonts.
  static TextStyle _body({
    required double size,
    required FontWeight weight,
    double? height,
    Color? color,
    List<FontFeature> features = const [],
  }) =>
      GoogleFonts.manrope(
        fontSize: size,
        fontWeight: weight,
        height: height,
        color: color ?? DplColors.textPrimary,
        letterSpacing: 0.1,
        fontFeatures: features,
      );

  // Display font — Bricolage Grotesque via google_fonts.
  static TextStyle _display({
    required double size,
    required FontWeight weight,
    double? height,
    Color? color,
    List<FontFeature> features = const [],
  }) =>
      GoogleFonts.bricolageGrotesque(
        fontSize: size,
        fontWeight: weight,
        height: height,
        color: color ?? DplColors.textPrimary,
        letterSpacing: -0.4,
        fontFeatures: features,
      );

  static TextStyle _mono({
    required double size,
    required FontWeight weight,
    double? height,
    Color? color,
  }) =>
      GoogleFonts.robotoMono(
        fontSize: size,
        fontWeight: weight,
        height: height,
        color: color ?? DplColors.textPrimary,
        fontFeatures: const [_tabularFigures],
      );

  static TextStyle display() => _display(size: 32, weight: FontWeight.w800);
  static TextStyle h1() => _display(size: 24, weight: FontWeight.w800);
  static TextStyle h2() => _display(size: 20, weight: FontWeight.w800);
  static TextStyle h3() =>
      _body(size: 17, weight: FontWeight.w700, height: 1.3);
  static TextStyle bodyLg() => _body(size: 16, weight: FontWeight.w500);
  static TextStyle body() => _body(size: 14, weight: FontWeight.w500);
  static TextStyle bodySm() => _body(size: 13, weight: FontWeight.w500);
  static TextStyle caption() => _body(
        size: 12,
        weight: FontWeight.w600,
        color: DplColors.textSecondary,
      );
  static TextStyle button() =>
      _body(size: 15, weight: FontWeight.w700, color: DplColors.textInverse);
  static TextStyle mono() => _mono(size: 16, weight: FontWeight.w600);
  static TextStyle numLg() => _display(
        size: 28,
        weight: FontWeight.w800,
        features: const [_tabularFigures],
      );
  static TextStyle numMd() => _display(
        size: 20,
        weight: FontWeight.w800,
        features: const [_tabularFigures],
      );
  static TextStyle timer() => _mono(size: 48, weight: FontWeight.w700);
}

/// Returns a [ThemeData] tuned for DPL surfaces in the active brightness.
/// Apply via `Theme(...)` at the top of a DPL shell if it ever needs to
/// diverge from the app-wide theme.
ThemeData dplThemeData() {
  final dark = VistarPalette.isDark;
  final base = dark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: DplColors.pageBg,
    colorScheme: base.colorScheme.copyWith(
      primary: DplColors.primary,
      onPrimary: DplColors.textInverse,
      surface: DplColors.cardBg,
      onSurface: DplColors.textPrimary,
      error: DplColors.error,
    ),
    textTheme: GoogleFonts.manropeTextTheme(base.textTheme).apply(
      bodyColor: DplColors.textPrimary,
      displayColor: DplColors.textPrimary,
    ),
    dividerColor: DplColors.divider,
    splashFactory: InkSparkle.splashFactory,
  );
}
