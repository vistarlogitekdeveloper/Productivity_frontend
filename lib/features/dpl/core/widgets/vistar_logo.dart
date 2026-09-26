import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/widgets/vistar/vistar_brand.dart';
import '../design/dpl_theme.dart';

/// Vistar brand mark + wordmark.
///
/// Pass [showWordmark]=true for the full Vistar Pulse wordmark (splash and
/// login hero only, per the design system), false for the bare "S" mark
/// used as the glyph in app bars and sidebars.
///
/// Falls back to a typographic placeholder when the asset can't be
/// found so screens render cleanly during onboarding of new variants.
class VistarLogo extends StatelessWidget {
  final double height;
  final bool showWordmark;
  final Color? fallbackColor;

  const VistarLogo({
    super.key,
    this.height = 28,
    this.showWordmark = false,
    this.fallbackColor,
  });

  @override
  Widget build(BuildContext context) {
    if (!showWordmark) {
      return VistarMark(
        size: height,
        fallback: _MarkFallback(
          size: height,
          color: fallbackColor ?? DplColors.primary,
        ),
      );
    }
    return Image.asset(
      VistarAssets.wordmark,
      height: height,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'Vistar Pulse',
      errorBuilder: (_, _, _) => _WordmarkFallback(
        height: height,
        color: fallbackColor ?? DplColors.primary,
      ),
    );
  }
}

class _MarkFallback extends StatelessWidget {
  final double size;
  final Color color;
  const _MarkFallback({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: DplColors.brandGradient,
      ),
      alignment: Alignment.center,
      child: Text(
        'V',
        style: TextStyle(
          color: DplColors.textInverse,
          fontWeight: FontWeight.w900,
          fontSize: size * 0.55,
          height: 1,
        ),
      ),
    );
  }
}

class _WordmarkFallback extends StatelessWidget {
  final double height;
  final Color color;
  const _WordmarkFallback({required this.height, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MarkFallback(size: height, color: color),
          SizedBox(width: height * 0.25),
          Text(
            'Vistar',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: height * 0.7,
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Preloads the Vistar brand rasters so they never flash on first render.
/// Call after the binding is ready.
Future<void> precacheVistarLogos(BuildContext context) async {
  if (kIsWeb) return; // precache is no-op on web
  try {
    await Future.wait([
      precacheImage(const AssetImage(VistarAssets.wordmark), context),
      precacheImage(const AssetImage(VistarAssets.mark), context),
      precacheImage(const AssetImage(VistarAssets.markSmall), context),
    ]);
  } catch (_) {
    // Asset missing during onboarding — fallbacks handle render.
  }
}
