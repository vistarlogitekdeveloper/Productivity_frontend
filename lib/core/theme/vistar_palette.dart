import 'package:flutter/material.dart';

/// "Vistar Premium" design tokens for Vistar Pulse, in a light and a dark
/// flavour.
///
/// The dark set is a straight port of the design system's `:root` block
/// (near-black surfaces, hairline white lines, violet-grey text). The light
/// set is its daylight counterpart: lavender-white surfaces and violet-grey
/// ink, with the brand and status colours the app already used on light
/// screens kept as they were.
///
/// Rule of the system, in both modes: the rainbow ribbon is a *thin accent*
/// — primary buttons, the active-nav bar, KPI numerals, section ticks —
/// never a large fill. Big surfaces stay quiet so the ribbon pops.
///
/// Screens read colours through [VistarPalette] (or `DplColors`, which maps
/// onto it). Those getters resolve against the active brightness, which the
/// app root sets from the persisted theme mode before every build — see
/// `VistarThemeSync` in `main.dart`.
@immutable
class VistarTokens {
  final Brightness brightness;

  // Surfaces.
  final Color bg;
  final Color bg2;
  final Color surface;
  final Color surface2;
  final Color surface3;
  final Color line;
  final Color line2;

  // Ink.
  final Color txt;
  final Color txt2;
  final Color txt3;

  // Interactive brand accent (links, selected states, solid buttons).
  final Color primary;
  final Color primaryInk;
  final Color primaryTint;
  final Color primaryLine;

  // Status: foreground, ink (text on its own tint), tint fill, border.
  final Color ok;
  final Color okInk;
  final Color okBg;
  final Color okLine;
  final Color warn;
  final Color warnInk;
  final Color warnBg;
  final Color warnLine;
  final Color bad;
  final Color badInk;
  final Color badBg;
  final Color badLine;
  final Color info;
  final Color infoInk;
  final Color infoBg;
  final Color infoLine;

  // Solid status fills that carry WHITE text. In light mode these equal
  // the foregrounds; in dark mode the foregrounds are pastel (for text on
  // near-black) and would leave white text at ~2:1, so fills use deeper
  // tones that hold >=3.9:1 against white and still read on the page.
  final Color okSolid;
  final Color warnSolid;
  final Color badSolid;
  final Color infoSolid;

  /// Scrim behind modal overlays (route loader, hand-off overlay).
  final Color scrim;

  const VistarTokens._({
    required this.brightness,
    required this.bg,
    required this.bg2,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.line,
    required this.line2,
    required this.txt,
    required this.txt2,
    required this.txt3,
    required this.primary,
    required this.primaryInk,
    required this.primaryTint,
    required this.primaryLine,
    required this.ok,
    required this.okInk,
    required this.okBg,
    required this.okLine,
    required this.warn,
    required this.warnInk,
    required this.warnBg,
    required this.warnLine,
    required this.bad,
    required this.badInk,
    required this.badBg,
    required this.badLine,
    required this.info,
    required this.infoInk,
    required this.infoBg,
    required this.infoLine,
    required this.okSolid,
    required this.warnSolid,
    required this.badSolid,
    required this.infoSolid,
    required this.scrim,
  });

  bool get isDark => brightness == Brightness.dark;

  static const VistarTokens light = VistarTokens._(
    brightness: Brightness.light,
    bg: Color(0xFFF7F5FB),
    bg2: Color(0xFFFBFAFD),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF7F4FB),
    surface3: Color(0xFFEFEAF6),
    line: Color(0xFFE6E1EF),
    line2: Color(0xFFD6CFE3),
    txt: Color(0xFF17132B),
    txt2: Color(0xFF625D78),
    txt3: Color(0xFF857E9F),
    primary: Color(0xFF6B1F8C),
    primaryInk: Color(0xFF4A1163),
    primaryTint: Color(0xFFF3E8F9),
    primaryLine: Color(0xFFD8BFE9),
    ok: Color(0xFF15803D),
    okInk: Color(0xFF14532D),
    okBg: Color(0xFFE7F8EF),
    okLine: Color(0xFFA7E3C4),
    warn: Color(0xFFB45309),
    warnInk: Color(0xFF92400E),
    warnBg: Color(0xFFFEF3C7),
    warnLine: Color(0xFFFCD34D),
    bad: Color(0xFFB3261E),
    badInk: Color(0xFF8F1D18),
    badBg: Color(0xFFFFECEA),
    badLine: Color(0xFFFFB4AA),
    info: Color(0xFF1D4ED8),
    infoInk: Color(0xFF1E3A8A),
    infoBg: Color(0xFFEEF2FF),
    infoLine: Color(0xFFC7D2FE),
    okSolid: Color(0xFF15803D),
    warnSolid: Color(0xFFB45309),
    badSolid: Color(0xFFB3261E),
    infoSolid: Color(0xFF1D4ED8),
    scrim: Color(0x8CF7F5FB),
  );

  static const VistarTokens dark = VistarTokens._(
    brightness: Brightness.dark,
    bg: Color(0xFF070611),
    bg2: Color(0xFF0B0A18),
    surface: Color(0xFF110F1E),
    surface2: Color(0xFF16142A),
    surface3: Color(0xFF1D1A33),
    line: Color(0x14FFFFFF),
    line2: Color(0x21FFFFFF),
    txt: Color(0xFFF2EEFB),
    txt2: Color(0xFFB9B2D6),
    txt3: Color(0xFF7E769B),
    // Violet lifted just enough to read on near-black *and* carry white
    // button text (≈4.2:1 both ways) — the flat brand purple is too dark
    // to do either on these surfaces.
    primary: Color(0xFFA64BDB),
    primaryInk: Color(0xFFD9B0F5),
    primaryTint: Color(0xFF2A153D),
    primaryLine: Color(0x619B30C9),
    ok: Color(0xFF34D399),
    okInk: Color(0xFF7EE6BE),
    okBg: Color(0xFF162A2F),
    okLine: Color(0x6134D399),
    warn: Color(0xFFFBBF24),
    warnInk: Color(0xFFFCD577),
    warnBg: Color(0xFF32281F),
    warnLine: Color(0x61FBBF24),
    bad: Color(0xFFFB6F84),
    badInk: Color(0xFFFFA3B1),
    badBg: Color(0xFF321C2C),
    badLine: Color(0x61FB6F84),
    info: Color(0xFF5BA8FF),
    infoInk: Color(0xFFA5CBFF),
    infoBg: Color(0xFF1B243E),
    infoLine: Color(0x615BA8FF),
    okSolid: Color(0xFF12946A),
    warnSolid: Color(0xFFB86E05),
    badSolid: Color(0xFFE5485F),
    infoSolid: Color(0xFF3B82F6),
    scrim: Color(0x8C070611),
  );

  static VistarTokens _active = light;

  /// The token set every [VistarPalette] getter currently reads.
  static VistarTokens get active => _active;

  static VistarTokens of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// Points the palette at [brightness]. Called by the app root; widgets
  /// never call this directly.
  static void activate(Brightness brightness) => _active = of(brightness);
}

/// Static facade over the active [VistarTokens], plus the brand constants
/// that are the same in both modes.
abstract final class VistarPalette {
  static VistarTokens get _t => VistarTokens.active;

  static bool get isDark => _t.isDark;

  // ── Brand ribbon (mode-independent) ─────────────────────────────
  static const Color purple = Color(0xFF7A1FB0);
  static const Color violet = Color(0xFF9B30C9);
  static const Color magenta = Color(0xFFC018C0);
  static const Color pink = Color(0xFFE0218A);
  static const Color red = Color(0xFFC8102E);
  static const Color orangeRed = Color(0xFFF0480C);
  static const Color orange = Color(0xFFF06000);
  static const Color amber = Color(0xFFF0C000);
  static const Color yellow = Color(0xFFF0E060);
  static const Color cream = Color(0xFFFFF6CC);

  /// The signature 8-stop ribbon.
  static const List<Color> ribbonStops = <Color>[
    Color(0xFF7A1FB0),
    Color(0xFFB81FB8),
    Color(0xFFE0218A),
    Color(0xFFD11630),
    Color(0xFFF0480C),
    Color(0xFFF06000),
    Color(0xFFF0C000),
    Color(0xFFF7EE9A),
  ];

  static const List<double> ribbonPositions = <double>[
    0.0,
    0.22,
    0.40,
    0.56,
    0.70,
    0.80,
    0.92,
    1.0,
  ];

  /// 115° ribbon — the CSS `--ribbon` token.
  static const LinearGradient ribbon = LinearGradient(
    begin: Alignment(-1.0, -0.55),
    end: Alignment(1.0, 0.55),
    colors: ribbonStops,
    stops: ribbonPositions,
  );

  /// Horizontal ribbon for text shaders, thin rules and progress bars.
  static const LinearGradient ribbonFlat = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: ribbonStops,
    stops: ribbonPositions,
  );

  /// Vertical ribbon for the 3px active-nav bar.
  static const LinearGradient ribbonVertical = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: ribbonStops,
    stops: ribbonPositions,
  );

  /// `--ribbon-soft` — the four-stop, slightly translucent ribbon used for
  /// hover washes and the skeleton sweep.
  static const LinearGradient ribbonSoft = LinearGradient(
    begin: Alignment(-1.0, -0.55),
    end: Alignment(1.0, 0.55),
    colors: <Color>[
      Color(0xE69B30C9),
      Color(0xE6E0218A),
      Color(0xE6F0480C),
      Color(0xE6F0C000),
    ],
  );

  /// Deep-violet hero banner fill (dashboard headers that carry white
  /// text). Dark enough to hold white type in both modes, quiet enough to
  /// respect the "no flat saturated fills" rule; pair with a thin ribbon
  /// accent rather than a second gradient.
  static const LinearGradient heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFF2A0A36), Color(0xFF4A1163), Color(0xFF7A1FB0)],
    stops: <double>[0.0, 0.55, 1.0],
  );

  // ── Surfaces / ink (mode-aware) ─────────────────────────────────
  static Color get bg => _t.bg;
  static Color get bg2 => _t.bg2;
  static Color get surface => _t.surface;
  static Color get surface2 => _t.surface2;
  static Color get surface3 => _t.surface3;
  static Color get line => _t.line;
  static Color get line2 => _t.line2;

  static Color get txt => _t.txt;
  static Color get txt2 => _t.txt2;
  static Color get txt3 => _t.txt3;

  static Color get primary => _t.primary;
  static Color get primaryInk => _t.primaryInk;
  static Color get primaryTint => _t.primaryTint;
  static Color get primaryLine => _t.primaryLine;

  static Color get ok => _t.ok;
  static Color get okInk => _t.okInk;
  static Color get okBg => _t.okBg;
  static Color get okLine => _t.okLine;
  static Color get warn => _t.warn;
  static Color get warnInk => _t.warnInk;
  static Color get warnBg => _t.warnBg;
  static Color get warnLine => _t.warnLine;
  static Color get bad => _t.bad;
  static Color get badInk => _t.badInk;
  static Color get badBg => _t.badBg;
  static Color get badLine => _t.badLine;
  static Color get info => _t.info;
  static Color get infoInk => _t.infoInk;
  static Color get infoBg => _t.infoBg;
  static Color get infoLine => _t.infoLine;

  /// Status fills behind white text (buttons, banners, solid badges).
  static Color get okSolid => _t.okSolid;
  static Color get warnSolid => _t.warnSolid;
  static Color get badSolid => _t.badSolid;
  static Color get infoSolid => _t.infoSolid;

  static Color get scrim => _t.scrim;

  /// Text / icons that sit on a solid brand or status fill.
  static const Color onAccent = Color(0xFFFFFFFF);

  // ── Radii (`--r-sm`, `--r`, `--r-lg`) ───────────────────────────
  static const double rSm = 11;
  static const double r = 16;
  static const double rLg = 22;

  /// Soft card shadow (`--shadow`). Lighter in daylight, where a heavy
  /// black bloom reads as dirt.
  static List<BoxShadow> get shadow => _t.isDark
      ? const <BoxShadow>[
          BoxShadow(
            color: Color(0xD9000000),
            blurRadius: 60,
            spreadRadius: -28,
            offset: Offset(0, 24),
          ),
        ]
      : const <BoxShadow>[
          BoxShadow(
            color: Color(0x142A1850),
            blurRadius: 40,
            spreadRadius: -18,
            offset: Offset(0, 18),
          ),
        ];

  /// Hover glow (`--glow`) — magenta bloom under a lifted card.
  static List<BoxShadow> get glow => _t.isDark
      ? const <BoxShadow>[
          BoxShadow(
            color: Color(0x66C018C0),
            blurRadius: 50,
            spreadRadius: -22,
            offset: Offset(0, 18),
          ),
        ]
      : const <BoxShadow>[
          BoxShadow(
            color: Color(0x33C018C0),
            blurRadius: 44,
            spreadRadius: -20,
            offset: Offset(0, 16),
          ),
        ];
}
