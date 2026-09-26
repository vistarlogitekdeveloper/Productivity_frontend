import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../dpl_organization_provider.dart';
import 'dpl_user_menu.dart';
import 'vistar_logo.dart';

/// Polished, branded AppBar used by every DPL screen.
///
/// Layout (left → right):
///   * Leading — back arrow when the route can pop, otherwise the
///     Vistar "S" glyph (plus the Bricolage product name on wide screens —
///     the wordmark itself is reserved for splash and login).
///   * Title — bold display + optional [subtitle] widget below (e.g. a
///     "Live • updated 12s ago" indicator).
///   * Actions — caller-supplied widgets followed by [DplUserMenu]
///     (when [showProfile] is true).
///
/// Visual identity:
///   * Card surface (deep ink in dark mode), no Material elevation.
///   * The Vistar ribbon as a 3px strip at the very top. This is the
///     recognizable "Vistar bar" across every screen.
///   * Hairline divider at the bottom.
class DplAppBar extends ConsumerWidget implements PreferredSizeWidget {
  final String title;
  final Widget? subtitle;
  final List<Widget> actions;
  final bool showProfile;
  final Widget? leading;
  final PreferredSizeWidget? bottom;

  const DplAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.showProfile = true,
    this.leading,
    this.bottom,
  });

  // Brand tokens — resolved against the active light / dark palette.
  static Color get _surface =>
      VistarPalette.isDark ? VistarPalette.bg2 : VistarPalette.surface;
  static Color get _divider => VistarPalette.line;
  static Color get _textPrimary => VistarPalette.txt;
  static Color get _textMuted => VistarPalette.txt3;

  static const double _baseHeight = 72;
  static const double _accentStripHeight = 3;
  static const double _subtitleHeight = 18;

  double get _coreHeight =>
      _accentStripHeight + _baseHeight + (subtitle != null ? _subtitleHeight : 0);

  @override
  Size get preferredSize => Size.fromHeight(
        _coreHeight + (bottom?.preferredSize.height ?? 0),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canPop = Navigator.of(context).canPop();
    final isPhone = MediaQuery.of(context).size.width < 600;
    final org = ref.watch(dplActiveOrganizationProvider);

    // Leading slot has two flavors:
    //   * Back arrow — fixed 56dp slot so titles align consistently
    //     across screens that can/can't pop.
    //   * Vistar "S" glyph — plus the Bricolage product name and a
    //     hairline separator on wide screens. No SizedBox reservation,
    //     so the title sits immediately to the right of the brand.
    final Widget leadingWidget;
    if (leading != null) {
      leadingWidget = leading!;
    } else if (canPop) {
      leadingWidget = SizedBox(
        width: 56,
        child: Center(
          child: IconButton(
            tooltip: 'Back',
            icon: Icon(
              Icons.arrow_back_rounded,
              color: _textPrimary,
            ),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
      );
    } else {
      leadingWidget = Padding(
        padding: EdgeInsets.fromLTRB(isPhone ? 12 : 16, 0, isPhone ? 8 : 14, 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            VistarLogo(height: isPhone ? 34 : 38),
            if (!isPhone) ...[
              const SizedBox(width: 10),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Vistar Pulse',
                    style: GoogleFonts.bricolageGrotesque(
                      color: _textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      height: 1.05,
                    ),
                  ),
                  Text(
                    'PRODUCTION · DISPATCH',
                    style: GoogleFonts.manrope(
                      color: _textMuted,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.6,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 14),
              Container(width: 1, height: 28, color: _divider),
            ],
          ],
        ),
      );
    }

    return Material(
      color: _surface,
      elevation: 0,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Brand accent strip — the Vistar ribbon, instant recognition.
            Container(
              height: _accentStripHeight,
              decoration: const BoxDecoration(
                gradient: VistarPalette.ribbonFlat,
              ),
            ),
            Container(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: _divider, width: 1),
                ),
              ),
              height: _baseHeight + (subtitle != null ? _subtitleHeight : 0),
              child: Row(
                children: [
                  leadingWidget,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                title,
                                style: GoogleFonts.bricolageGrotesque(
                                  color: _textPrimary,
                                  fontWeight: FontWeight.w800,
                                  fontSize: isPhone ? 16 : 18,
                                  letterSpacing: -0.4,
                                  height: 1.15,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (org != null) ...[
                              const SizedBox(width: 8),
                              _OrgPill(label: org.displayLabel, isPhone: isPhone),
                            ],
                          ],
                        ),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: DefaultTextStyle(
                              style: GoogleFonts.manrope(
                                color: _textMuted,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                height: 1.1,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              child: subtitle!,
                            ),
                          ),
                      ],
                    ),
                  ),
                  ...actions,
                  if (showProfile) const DplUserMenu(),
                ],
              ),
            ),
            ?bottom,
          ],
        ),
      ),
    );
  }
}

/// Compact tenant chip rendered next to the AppBar title when the
/// logged-in user has an active organization. Single visual cue that
/// makes it obvious which org's data the screen is showing — important
/// once more than one tenant is provisioned server-side.
class _OrgPill extends StatelessWidget {
  final String label;
  final bool isPhone;

  const _OrgPill({required this.label, required this.isPhone});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isPhone ? 7 : 9,
        vertical: isPhone ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: VistarPalette.primaryTint,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: VistarPalette.primaryLine),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.business_rounded,
            size: 11,
            color: VistarPalette.primaryInk,
          ),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: isPhone ? 110 : 200),
            child: Text(
              label,
              style: TextStyle(
                color: VistarPalette.primaryInk,
                fontWeight: FontWeight.w700,
                fontSize: isPhone ? 10.5 : 11.5,
                height: 1.0,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
