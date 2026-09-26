import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../design/dpl_theme.dart';

/// Which dashboard the switcher currently sits on.
enum DplDashboardMode { production, dispatch }

/// Full-width segmented "Production ⇄ Dispatch" band that sits directly
/// UNDER the AppBar — dropped into [DplAppBar.bottom] — giving a DPL
/// Manager one-tap (or one-swipe) access to both the Daily Production
/// dashboard (`/dpl/manager`) and the Dispatch dashboard (`/dpl/summary`).
///
/// Interaction:
///   * TAP a segment → switch to it.
///   * SWIPE/DRAG horizontally → switch toward the drag direction
///     (drag right → Dispatch, drag left → Production). Works for both a
///     quick fling and a slow drag-and-release (distance OR velocity).
///
/// Manager-only — the caller gates visibility by role (Dispatch / DEO /
/// PDI can't reach the manager dashboard, so they never see it). Uses
/// `context.go` so switching swaps the shell instead of stacking routes.
/// Implements [PreferredSizeWidget] so it slots into the AppBar's `bottom`
/// with a fixed height and never touches the (crowded) action Row.
class DplDashboardSwitcher extends StatefulWidget
    implements PreferredSizeWidget {
  final DplDashboardMode current;
  const DplDashboardSwitcher({super.key, required this.current});

  static const double _height = 52;

  @override
  Size get preferredSize => const Size.fromHeight(_height);

  @override
  State<DplDashboardSwitcher> createState() => _DplDashboardSwitcherState();
}

class _DplDashboardSwitcherState extends State<DplDashboardSwitcher> {
  /// Accumulated horizontal drag since the gesture started. Tracking the
  /// distance (not just the end velocity) means a slow drag-and-release
  /// switches too, not only a quick fling.
  double _dragDx = 0;

  /// Min net drag distance (px) OR fling velocity to trigger a switch.
  static const double _minDragDx = 24;
  static const double _minFlingV = 250;

  void _go(DplDashboardMode target) {
    if (target == widget.current) return; // already there — no-op
    context.go(
      target == DplDashboardMode.dispatch ? '/dpl/summary' : '/dpl/manager',
    );
  }

  void _onDragEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    // Rightward (toward the right "Dispatch" segment) → Dispatch;
    // leftward (toward the left "Production" segment) → Production.
    if (_dragDx > _minDragDx || v > _minFlingV) {
      _go(DplDashboardMode.dispatch);
    } else if (_dragDx < -_minDragDx || v < -_minFlingV) {
      _go(DplDashboardMode.production);
    }
    _dragDx = 0;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Opaque so drags starting on the padding/gaps are captured too.
      // Taps still reach the segment InkWells — the gesture arena hands a
      // pure tap to the InkWell and a horizontal drag to this detector.
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _dragDx = 0,
      onHorizontalDragUpdate: (d) => _dragDx += d.delta.dx,
      onHorizontalDragEnd: _onDragEnd,
      child: Container(
        height: DplDashboardSwitcher._height,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: DplColors.cardBg,
          border: Border(
            bottom: BorderSide(color: DplColors.divider, width: 1),
          ),
        ),
        child: Container(
          // The pill — stretches the full band width; each segment takes
          // an equal half via Expanded.
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: DplColors.primaryTint,
            borderRadius: BorderRadius.circular(999),
            border:
                Border.all(color: DplColors.primary.withValues(alpha: 0.18)),
          ),
          child: Row(
            children: [
              Expanded(
                child: _SwitcherSegment(
                  label: 'Production',
                  icon: Icons.insights_rounded,
                  active: widget.current == DplDashboardMode.production,
                  onTap: widget.current == DplDashboardMode.production
                      ? null
                      : () => _go(DplDashboardMode.production),
                ),
              ),
              Expanded(
                child: _SwitcherSegment(
                  label: 'Dispatch',
                  icon: Icons.local_shipping_rounded,
                  active: widget.current == DplDashboardMode.dispatch,
                  onTap: widget.current == DplDashboardMode.dispatch
                      ? null
                      : () => _go(DplDashboardMode.dispatch),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitcherSegment extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback? onTap;
  const _SwitcherSegment({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? DplColors.textInverse : DplColors.primaryDark;
    return Semantics(
      button: true,
      selected: active,
      label: '$label dashboard',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            // Fill the Expanded half and centre the icon + label in it.
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: active ? DplColors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: DplColors.primary.withValues(alpha: 0.28),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
