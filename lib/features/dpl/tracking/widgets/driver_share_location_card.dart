import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_format.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/widgets/dpl_snack.dart';
import '../services/trip_location_tracker.dart';

/// The driver's one control for live location sharing.
///
/// Deliberately explicit rather than automatic. Sharing never starts on
/// its own — the driver flips it on, the card states plainly what is
/// being shared and for how long, and a persistent OS notification runs
/// the whole time. That's both the honest thing to do and what keeps us
/// inside while-in-use location permission (see [TripLocationTracker]).
///
/// Renders its own status: live, queued-offline, permission-blocked, or
/// errored — the driver is the only person who can fix most of those, so
/// the fix is always one tap away.
class DriverShareLocationCard extends ConsumerWidget {
  final int tripId;

  /// Set once the trip's journey is finished. The card collapses to a
  /// short confirmation instead of offering a toggle.
  final bool tripClosed;

  const DriverShareLocationCard({
    super.key,
    required this.tripId,
    this.tripClosed = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(tripLocationTrackerProvider);
    final tracker = ref.read(tripLocationTrackerProvider.notifier);
    final on = state.isTracking(tripId);

    if (tripClosed && !on) return _closedCard();

    final blocked = on && state.status == TripTrackingStatus.blocked;
    final errored = on && state.status == TripTrackingStatus.error;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(DplRadius.lg),
        border: Border.all(
          color: on ? DplColors.primary.withValues(alpha: 0.45) : DplColors.divider,
          width: on ? 1.5 : 1,
        ),
        boxShadow: DplShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: on ? DplColors.primaryTint : DplColors.neutralBg,
                  borderRadius: BorderRadius.circular(DplRadius.sm),
                ),
                child: Icon(
                  on ? Icons.podcasts_rounded : Icons.location_on_outlined,
                  size: 20,
                  color: on ? DplColors.primary : DplColors.textSecondary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Share live location',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Lets dispatch see where the truck is during this trip.',
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.3,
                        color: DplColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Switch.adaptive(
                value: on,
                activeThumbColor: DplColors.primary,
                onChanged: (want) => _toggle(context, tracker, want),
              ),
            ],
          ),
          if (on) ...[
            const SizedBox(height: 12),
            Divider(height: 1, color: DplColors.divider),
            const SizedBox(height: 10),
            if (blocked || errored)
              _problem(context, tracker, state)
            else
              _liveDetail(state),
          ] else ...[
            const SizedBox(height: 10),
            _hint(
              icon: Icons.info_outline_rounded,
              text: 'Sharing runs only until this trip is closed, and stops '
                  'by itself at the final gate scan. A notification stays on '
                  'screen the whole time it is running.',
            ),
          ],
          if (on && state.mockDetected) ...[
            const SizedBox(height: 8),
            _hint(
              icon: Icons.warning_amber_rounded,
              color: DplColors.error,
              text: 'A mock-location app was detected on this phone. Dispatch '
                  'is notified when trip positions are simulated.',
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _toggle(
    BuildContext context,
    TripLocationTracker tracker,
    bool want,
  ) async {
    if (!want) {
      await tracker.stop();
      if (context.mounted) {
        DplSnacks.info(context, 'Location sharing stopped.');
      }
      return;
    }

    final ok = await tracker.start(tripId);
    if (!context.mounted) return;
    if (ok) {
      DplSnacks.success(context, 'Sharing live location with dispatch.');
    }
    // Failure detail already lives in the card's own status row — a
    // snack on top of it would just say the same thing twice.
  }

  // ── states

  Widget _liveDetail(TripTrackingState state) {
    final fix = state.lastFix;
    final starting = state.status == TripTrackingStatus.starting;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _pill(
              starting
                  ? 'Getting first fix…'
                  : (state.queued > 0 ? 'Saving offline' : 'Live'),
              color: starting
                  ? DplColors.info
                  : (state.queued > 0 ? DplColors.warning : DplColors.success),
              bg: starting
                  ? DplColors.infoBg
                  : (state.queued > 0
                      ? DplColors.warningBg
                      : DplColors.successBg),
            ),
            const Spacer(),
            if (fix != null)
              Text(
                'Updated ${DplFormat.relative(fix.recordedAt)}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: DplColors.textSecondary,
                ),
              ),
          ],
        ),
        if (state.queued > 0) ...[
          const SizedBox(height: 8),
          _hint(
            icon: Icons.cloud_off_rounded,
            color: DplColors.warning,
            text: '${state.queued} update${state.queued == 1 ? "" : "s"} '
                'waiting for signal. They upload automatically — keep '
                'sharing on.',
          ),
        ],
      ],
    );
  }

  Widget _problem(
    BuildContext context,
    TripLocationTracker tracker,
    TripTrackingState state,
  ) {
    final blocked = state.status == TripTrackingStatus.blocked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _hint(
          icon: blocked ? Icons.gpp_maybe_rounded : Icons.error_outline_rounded,
          color: DplColors.error,
          text: state.message ?? 'Location sharing stopped unexpectedly.',
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (blocked)
              TextButton.icon(
                style: _btnStyle,
                icon: const Icon(Icons.settings_rounded, size: 16),
                label: const Text('Open settings'),
                onPressed: tracker.openBlockingSettings,
              ),
            TextButton.icon(
              style: _btnStyle,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Try again'),
              onPressed: tracker.retry,
            ),
          ],
        ),
      ],
    );
  }

  Widget _closedCard() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: DplColors.cardBg,
          borderRadius: BorderRadius.circular(DplRadius.lg),
          border: Border.all(color: DplColors.divider),
          boxShadow: DplShadows.card,
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle_rounded,
                size: 20, color: DplColors.success),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Location sharing ended with the trip.',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: DplColors.textSecondary.withValues(alpha: 0.95),
                ),
              ),
            ),
          ],
        ),
      );

  // ── bits

  static final ButtonStyle _btnStyle = TextButton.styleFrom(
    foregroundColor: DplColors.primary,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    minimumSize: const Size(0, 32),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
    textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
  );

  Widget _pill(String text, {required Color color, required Color bg}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(DplRadius.pill),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      );

  Widget _hint({
    required IconData icon,
    required String text,
    Color? color,
  }) {
    final c = color ?? DplColors.textSecondary;
    return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: c),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: c,
              ),
            ),
          ),
        ],
      );
  }
}
