import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/dpl_constants.dart';
import '../../models/dpl_identity.dart';
import '../providers/dpl_identity_provider.dart';
import 'selfie_modal.dart';

/// Wraps the supervisor app body with a per-shift identity gate.
///
/// Rule (server-owned as of 2026-05-19): in every shift the supervisor
/// uses the app, they must take one selfie BEFORE doing anything else.
/// The server computes `verified_for_current_shift` against the plant
/// timezone — the client just reads the flag.
///
/// Behavior:
///   * If verification isn't required, or the supervisor is already
///     verified for the current shift → render [child] normally.
///   * Otherwise render [_ShiftLockScreen] and auto-open the selfie
///     modal once per distinct shift id (key 0 = unknown / gap time).
///   * If the supervisor cancels the modal they see the lock screen
///     with a tap-to-verify button.
class ShiftIdentityGuard extends ConsumerStatefulWidget {
  final Widget child;
  const ShiftIdentityGuard({super.key, required this.child});

  @override
  ConsumerState<ShiftIdentityGuard> createState() =>
      _ShiftIdentityGuardState();
}

class _ShiftIdentityGuardState
    extends ConsumerState<ShiftIdentityGuard> {
  bool _selfieOpen = false;
  int? _autoPromptedShiftId;

  Future<void> _promptSelfie() async {
    if (_selfieOpen || !mounted) return;
    _selfieOpen = true;
    try {
      await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        useSafeArea: true,
        builder: (_) => const SelfieModal(
          context: DplIdentityContext.login,
        ),
      );
      // Whether they submitted or cancelled, refresh status so the
      // guard re-evaluates against the latest server state.
      ref.invalidate(dplIdentityStatusProvider);
    } finally {
      _selfieOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(dplIdentityStatusProvider);
    final status = statusAsync.asData?.value.data;

    // Status not arrived yet (or backend errored). Fail-open so a
    // broken status endpoint doesn't lock production out.
    if (status == null) {
      _autoPromptedShiftId = null;
      return widget.child;
    }

    if (!status.required || status.verifiedForCurrentShift) {
      _autoPromptedShiftId = null;
      return widget.child;
    }

    // Auto-open the modal ONCE per distinct shift (or once for the
    // unknown-shift fallback bucket, key = 0); if they cancel, the
    // lock screen stays up and they can re-trigger via the button.
    final lockKey = status.currentShift?.id ?? 0;
    if (_autoPromptedShiftId != lockKey) {
      _autoPromptedShiftId = lockKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _promptSelfie();
      });
    }

    return _ShiftLockScreen(
      shift: status.currentShift,
      onVerify: _promptSelfie,
    );
  }
}

class _ShiftLockScreen extends StatelessWidget {
  final DplIdentityCurrentShift? shift;
  final Future<void> Function() onVerify;

  const _ShiftLockScreen({required this.shift, required this.onVerify});

  @override
  Widget build(BuildContext context) {
    final s = shift;
    final label = s?.windowLabel ?? '';
    final shiftName = (s?.name ?? '').isEmpty ? 'this shift' : s!.name;

    return Scaffold(
      backgroundColor: VistarPalette.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      color: VistarPalette.warnBg,
                      borderRadius: BorderRadius.circular(42),
                      border: Border.all(color: VistarPalette.warnLine),
                    ),
                    child: Icon(
                      Icons.shield_outlined,
                      size: 44,
                      color: VistarPalette.warn,
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Identity check required',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 20,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text.rich(
                    TextSpan(
                      style: TextStyle(
                        color: VistarPalette.txt2,
                        fontSize: 14,
                        height: 1.4,
                      ),
                      children: [
                        const TextSpan(
                          text: 'Please take a selfie for ',
                        ),
                        TextSpan(
                          text: shiftName,
                          style: TextStyle(
                            color: VistarPalette.info,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (label.isNotEmpty) ...[
                          const TextSpan(text: '  ('),
                          TextSpan(text: label),
                          const TextSpan(text: ')'),
                        ],
                        const TextSpan(
                          text: ' to continue using the app.',
                        ),
                      ],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.camera_alt_outlined, size: 18),
                      label: const Text('Take selfie'),
                      onPressed: () => onVerify(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'One verification per shift is required for '
                    'compliance.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: VistarPalette.txt3,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
