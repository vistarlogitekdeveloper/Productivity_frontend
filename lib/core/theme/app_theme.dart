import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'vistar_palette.dart';

/// App-wide Material theme for Vistar Pulse, built from the Vistar Premium
/// tokens in [VistarTokens].
///
/// Both themes come from the same recipe; only the token set differs. That
/// keeps light and dark visually identical in structure — same radii, same
/// hairlines, same type scale — so a screen that works in one mode works in
/// the other.
class AppTheme {
  const AppTheme._();

  static ThemeData get lightTheme => _buildTheme(VistarTokens.light);
  static ThemeData get darkTheme => _buildTheme(VistarTokens.dark);

  static ThemeData _buildTheme(VistarTokens t) {
    final isDark = t.isDark;
    const white = Color(0xFFFFFFFF);

    final colorScheme = ColorScheme(
      brightness: t.brightness,
      primary: t.primary,
      onPrimary: white,
      primaryContainer: t.primaryTint,
      onPrimaryContainer: t.primaryInk,
      secondary: VistarPalette.pink,
      onSecondary: white,
      secondaryContainer: isDark
          ? const Color(0xFF331631)
          : const Color(0xFFFDE7F3),
      onSecondaryContainer: isDark
          ? const Color(0xFFFFB2DA)
          : const Color(0xFF8A0F52),
      tertiary: VistarPalette.orange,
      onTertiary: white,
      tertiaryContainer: isDark
          ? const Color(0xFF33211A)
          : const Color(0xFFFFEDE0),
      onTertiaryContainer: isDark
          ? const Color(0xFFFFC49E)
          : const Color(0xFF8A3300),
      error: t.bad,
      onError: white,
      errorContainer: t.badBg,
      onErrorContainer: t.badInk,
      surface: t.surface,
      onSurface: t.txt,
      onSurfaceVariant: t.txt2,
      surfaceContainerLowest: isDark ? t.bg2 : white,
      surfaceContainerLow: t.surface2,
      surfaceContainer: t.surface2,
      surfaceContainerHigh: t.surface3,
      surfaceContainerHighest: t.surface3,
      outline: t.line2,
      outlineVariant: t.line,
      shadow: const Color(0xFF000000),
      scrim: const Color(0xFF000000),
      inverseSurface: isDark
          ? const Color(0xFFF2EEFB)
          : const Color(0xFF1D1A33),
      onInverseSurface: isDark
          ? const Color(0xFF17132B)
          : const Color(0xFFF2EEFB),
      inversePrimary: isDark
          ? const Color(0xFF6B1F8C)
          : const Color(0xFFD9B0F5),
      surfaceTint: Colors.transparent,
    );

    // Manrope for body, labels and table text; Bricolage Grotesque for
    // display text (headlines, page titles, KPI numerals).
    final base = isDark
        ? Typography.material2021().white
        : Typography.material2021().black;
    final body = GoogleFonts.manropeTextTheme(base).apply(
      bodyColor: t.txt,
      displayColor: t.txt,
    );
    TextStyle? display(TextStyle? s, FontWeight w) => s == null
        ? null
        : GoogleFonts.bricolageGrotesque(
            textStyle: s,
            fontWeight: w,
            letterSpacing: -0.4,
            color: t.txt,
          );

    final textTheme = body.copyWith(
      displayLarge: display(body.displayLarge, FontWeight.w800),
      displayMedium: display(body.displayMedium, FontWeight.w800),
      displaySmall: display(body.displaySmall, FontWeight.w800),
      headlineLarge: display(body.headlineLarge, FontWeight.w800),
      headlineMedium: display(body.headlineMedium, FontWeight.w800),
      headlineSmall: display(body.headlineSmall, FontWeight.w800),
      titleLarge: display(body.titleLarge, FontWeight.w800),
      titleMedium: body.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      titleSmall: body.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      labelLarge: body.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      bodyMedium: body.bodyMedium?.copyWith(letterSpacing: 0.1),
      bodySmall: body.bodySmall?.copyWith(
        letterSpacing: 0.1,
        color: t.txt2,
      ),
    );

    final radiusSm = BorderRadius.circular(VistarPalette.rSm);
    final radius = BorderRadius.circular(VistarPalette.r);
    final radiusLg = BorderRadius.circular(VistarPalette.rLg);
    final focusPink = VistarPalette.pink.withValues(alpha: 0.6);

    return ThemeData(
      useMaterial3: true,
      brightness: t.brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: t.bg,
      canvasColor: t.surface,
      cardColor: t.surface,
      dividerColor: t.line,
      hintColor: t.txt3,
      disabledColor: t.txt3,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      textTheme: textTheme,
      iconTheme: IconThemeData(color: t.txt2),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: VistarPalette.pink,
        selectionColor: VistarPalette.pink.withValues(alpha: 0.28),
        selectionHandleColor: VistarPalette.pink,
      ),
      scrollbarTheme: ScrollbarThemeData(
        radius: const Radius.circular(10),
        thickness: WidgetStateProperty.all(8),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.dragged)
              ? VistarPalette.pink.withValues(alpha: 0.6)
              : VistarPalette.violet.withValues(alpha: isDark ? 0.4 : 0.3),
        ),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: isDark ? t.bg2 : t.surface,
        foregroundColor: t.txt,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: t.line)),
        titleTextStyle: GoogleFonts.bricolageGrotesque(
          color: t.txt,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.4,
        ),
        iconTheme: IconThemeData(color: t.txt),
        actionsIconTheme: IconThemeData(color: t.txt2),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: t.surface,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: t.line),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
        labelStyle: TextStyle(color: t.txt2, fontWeight: FontWeight.w600),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.error)
                ? t.bad
                : states.contains(WidgetState.focused)
                ? VistarPalette.pink
                : t.txt2,
            fontWeight: FontWeight.w700,
          ),
        ),
        hintStyle: TextStyle(color: t.txt3),
        helperStyle: TextStyle(color: t.txt3),
        prefixIconColor: t.txt3,
        suffixIconColor: t.txt3,
        border: OutlineInputBorder(
          borderRadius: radiusSm,
          borderSide: BorderSide(color: t.line2),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: radiusSm,
          borderSide: BorderSide(color: t.line2),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: radiusSm,
          borderSide: BorderSide(color: t.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radiusSm,
          borderSide: BorderSide(color: focusPink, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: radiusSm,
          borderSide: BorderSide(color: t.bad),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: radiusSm,
          borderSide: BorderSide(color: t.bad, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          backgroundColor: t.primary,
          foregroundColor: white,
          disabledBackgroundColor: t.surface3,
          disabledForegroundColor: t.txt3,
          shape: RoundedRectangleBorder(borderRadius: radiusSm),
          textStyle: GoogleFonts.manrope(
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          backgroundColor: t.primary,
          foregroundColor: white,
          disabledBackgroundColor: t.surface3,
          disabledForegroundColor: t.txt3,
          shape: RoundedRectangleBorder(borderRadius: radiusSm),
          textStyle: GoogleFonts.manrope(
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
      // `.btn-ghost` — quiet surface button with a hairline border.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          foregroundColor: t.txt,
          backgroundColor: t.surface2,
          side: BorderSide(color: t.line2),
          shape: RoundedRectangleBorder(borderRadius: radiusSm),
          textStyle: GoogleFonts.manrope(
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: isDark ? t.primaryInk : t.primary,
          shape: RoundedRectangleBorder(borderRadius: radiusSm),
          textStyle: GoogleFonts.manrope(fontWeight: FontWeight.w700),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: t.txt2),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? t.primaryTint
                : t.surface2,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? t.primaryInk : t.txt2,
          ),
          side: WidgetStateProperty.all(BorderSide(color: t.line2)),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: radiusSm),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 4,
        highlightElevation: 6,
        backgroundColor: t.primary,
        foregroundColor: white,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 68,
        backgroundColor: isDark ? t.bg2 : t.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: t.primaryTint,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? t.primaryInk
                : t.txt3,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => GoogleFonts.manrope(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w800
                : FontWeight.w600,
            color: states.contains(WidgetState.selected) ? t.txt : t.txt3,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: isDark ? t.bg2 : t.surface,
        indicatorColor: t.primaryTint,
        selectedIconTheme: IconThemeData(color: t.primaryInk),
        unselectedIconTheme: IconThemeData(color: t.txt3),
        selectedLabelTextStyle: TextStyle(
          color: t.txt,
          fontWeight: FontWeight.w800,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: t.txt3,
          fontWeight: FontWeight.w600,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: t.txt,
        unselectedLabelColor: t.txt3,
        indicatorColor: VistarPalette.pink,
        dividerColor: t.line,
        labelStyle: GoogleFonts.manrope(fontWeight: FontWeight.w800),
        unselectedLabelStyle: GoogleFonts.manrope(
          fontWeight: FontWeight.w600,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: t.surface2,
        selectedColor: t.primaryTint,
        disabledColor: t.surface2,
        side: BorderSide(color: t.line),
        checkmarkColor: t.primaryInk,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        labelStyle: TextStyle(color: t.txt, fontWeight: FontWeight.w600),
        secondaryLabelStyle: TextStyle(
          color: t.primaryInk,
          fontWeight: FontWeight.w700,
        ),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStateProperty.all(t.surface2),
        headingTextStyle: GoogleFonts.manrope(
          color: t.txt3,
          fontWeight: FontWeight.w700,
          fontSize: 12,
          letterSpacing: 0.6,
        ),
        dataTextStyle: GoogleFonts.manrope(
          color: t.txt2,
          fontWeight: FontWeight.w500,
        ),
        dataRowColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.hovered) ? t.surface2 : null,
        ),
        dividerThickness: 0.6,
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: radius,
          border: Border.all(color: t.line),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? t.surface2 : t.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radiusLg,
          side: isDark ? BorderSide(color: t.line2) : BorderSide.none,
        ),
        titleTextStyle: GoogleFonts.bricolageGrotesque(
          color: t.txt,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.4,
        ),
        contentTextStyle: GoogleFonts.manrope(
          color: t.txt2,
          fontSize: 14,
          height: 1.45,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? t.surface2 : t.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: isDark ? t.surface2 : t.surface,
        dragHandleColor: t.line2,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(VistarPalette.rLg),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: isDark ? t.surface3 : const Color(0xFF1D1A33),
        contentTextStyle: GoogleFonts.manrope(
          color: const Color(0xFFF2EEFB),
          fontWeight: FontWeight.w600,
        ),
        actionTextColor: const Color(0xFFFFB2DA),
        shape: RoundedRectangleBorder(
          borderRadius: radiusSm,
          side: isDark ? BorderSide(color: t.line2) : BorderSide.none,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? t.surface3 : const Color(0xFF1D1A33),
          borderRadius: BorderRadius.circular(8),
          border: isDark ? Border.all(color: t.line2) : null,
        ),
        textStyle: GoogleFonts.manrope(
          fontSize: 12,
          color: const Color(0xFFF2EEFB),
          fontWeight: FontWeight.w600,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: isDark ? VistarPalette.pink : t.primary,
        linearTrackColor: t.surface3,
        circularTrackColor: Colors.transparent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? white : t.txt3,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? t.primary : t.surface3,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : t.line2,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? t.primary : null,
        ),
        checkColor: WidgetStateProperty.all(white),
        side: BorderSide(color: t.line2, width: 1.6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? t.primary : t.txt3,
        ),
      ),
      dividerTheme: DividerThemeData(color: t.line, thickness: 0.8),
      listTileTheme: ListTileThemeData(
        iconColor: t.txt2,
        textColor: t.txt,
        shape: RoundedRectangleBorder(borderRadius: radiusSm),
        titleTextStyle: GoogleFonts.manrope(
          color: t.txt,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
        subtitleTextStyle: GoogleFonts.manrope(color: t.txt2, fontSize: 13),
      ),
      popupMenuTheme: PopupMenuThemeData(
        elevation: 8,
        color: isDark ? t.surface2 : t.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: isDark ? 0.6 : 0.18),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: t.line),
        ),
        textStyle: GoogleFonts.manrope(color: t.txt, fontSize: 14),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStateProperty.all(
            isDark ? t.surface2 : t.surface,
          ),
          surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
          side: WidgetStateProperty.all(BorderSide(color: t.line)),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: radiusSm),
          ),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStateProperty.all(
            isDark ? t.surface2 : t.surface,
          ),
          surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        ),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: isDark ? t.surface2 : t.surface,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: isDark ? t.surface3 : t.primaryTint,
        headerForegroundColor: isDark ? t.txt : t.primaryInk,
        shape: RoundedRectangleBorder(borderRadius: radiusLg),
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: isDark ? t.surface2 : t.surface,
        shape: RoundedRectangleBorder(borderRadius: radiusLg),
      ),
      badgeTheme: const BadgeThemeData(backgroundColor: VistarPalette.pink),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: t.txt2,
        collapsedIconColor: t.txt3,
        textColor: t.txt,
        collapsedTextColor: t.txt,
      ),
    );
  }
}
