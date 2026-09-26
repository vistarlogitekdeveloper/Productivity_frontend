import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../design/dpl_theme.dart';

enum _DplButtonVariant { primary, secondary, danger, gradient }

class _DplButtonBase extends StatelessWidget {
  final _DplButtonVariant variant;
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;
  final double height;
  final HapticFeedbackType haptic;
  final bool fullWidth;

  const _DplButtonBase({
    required this.variant,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.height = 56,
    this.haptic = HapticFeedbackType.medium,
    this.fullWidth = true,
  });

  bool get _isDisabled => onPressed == null || loading;

  Color get _fg {
    switch (variant) {
      case _DplButtonVariant.primary:
      case _DplButtonVariant.danger:
      case _DplButtonVariant.gradient:
        return DplColors.textInverse;
      case _DplButtonVariant.secondary:
        return DplColors.primary;
    }
  }

  Color? get _bg {
    switch (variant) {
      case _DplButtonVariant.primary:
        return DplColors.primary;
      case _DplButtonVariant.danger:
        return DplColors.error;
      case _DplButtonVariant.secondary:
        return DplColors.cardBg;
      case _DplButtonVariant.gradient:
        return null; // handled via gradient
    }
  }

  Gradient? get _gradient =>
      variant == _DplButtonVariant.gradient ? VistarPalette.ribbon : null;

  BoxBorder? get _border {
    if (variant != _DplButtonVariant.secondary) return null;
    return Border.all(color: DplColors.primary, width: 1.5);
  }

  void _onTap() {
    if (_isDisabled) return;
    switch (haptic) {
      case HapticFeedbackType.light:
        HapticFeedback.lightImpact();
        break;
      case HapticFeedbackType.medium:
        HapticFeedback.mediumImpact();
        break;
      case HapticFeedbackType.heavy:
        HapticFeedback.heavyImpact();
        break;
      case HapticFeedbackType.none:
        break;
    }
    onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(DplRadius.md);
    final disabled = _isDisabled;

    final inner = Center(
      child: loading
          ? SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                valueColor: AlwaysStoppedAnimation(_fg),
              ),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, color: _fg, size: 20),
                  const SizedBox(width: 8),
                ],
                Text(label, style: DplText.button().copyWith(color: _fg)),
              ],
            ),
    );

    final decoration = BoxDecoration(
      color: _bg,
      gradient: _gradient,
      borderRadius: radius,
      border: _border,
      boxShadow: disabled || variant == _DplButtonVariant.secondary
          ? null
          : variant == _DplButtonVariant.gradient
          // `.btn-grad` bloom: 0 14px 34px -14px rgba(224,33,138,.7)
          ? const [
              BoxShadow(
                color: Color(0xB3E0218A),
                blurRadius: 34,
                spreadRadius: -14,
                offset: Offset(0, 14),
              ),
            ]
          : DplShadows.button,
    );

    final button = Opacity(
      opacity: disabled ? 0.4 : 1,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: disabled ? null : _onTap,
          child: Container(
            height: height,
            width: fullWidth ? double.infinity : null,
            padding: const EdgeInsets.symmetric(horizontal: DplSpacing.lg),
            decoration: decoration,
            child: inner,
          ),
        ),
      ),
    );

    return button;
  }
}

enum HapticFeedbackType { light, medium, heavy, none }

class DplPrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;
  final bool fullWidth;
  final double height;
  const DplPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.loading = false,
    this.fullWidth = true,
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) => _DplButtonBase(
        variant: _DplButtonVariant.primary,
        label: label,
        icon: icon,
        onPressed: onPressed,
        loading: loading,
        fullWidth: fullWidth,
        height: height,
      );
}

class DplSecondaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;
  final bool fullWidth;
  final double height;
  const DplSecondaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.loading = false,
    this.fullWidth = true,
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) => _DplButtonBase(
        variant: _DplButtonVariant.secondary,
        label: label,
        icon: icon,
        onPressed: onPressed,
        loading: loading,
        fullWidth: fullWidth,
        height: height,
        haptic: HapticFeedbackType.light,
      );
}

class DplDangerButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;
  final bool fullWidth;
  final double height;
  const DplDangerButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.loading = false,
    this.fullWidth = true,
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) => _DplButtonBase(
        variant: _DplButtonVariant.danger,
        label: label,
        icon: icon,
        onPressed: onPressed,
        loading: loading,
        fullWidth: fullWidth,
        height: height,
        haptic: HapticFeedbackType.heavy,
      );
}

class DplGradientButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;
  final bool fullWidth;
  final double height;
  const DplGradientButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.loading = false,
    this.fullWidth = true,
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) => _DplButtonBase(
        variant: _DplButtonVariant.gradient,
        label: label,
        icon: icon,
        onPressed: onPressed,
        loading: loading,
        fullWidth: fullWidth,
        height: height,
        haptic: HapticFeedbackType.heavy,
      );
}

/// 72dp version for START / STOP / RESUME on the execution screen.
class DplBigActionButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;
  /// Defaults to [DplColors.primary]; pass [DplColors.error] for the
  /// danger variant.
  final Color? color;
  final bool useGradient;

  const DplBigActionButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.loading = false,
    this.color,
    this.useGradient = false,
  });

  @override
  Widget build(BuildContext context) {
    if (useGradient) {
      return DplGradientButton(
        label: label,
        icon: icon,
        onPressed: onPressed,
        loading: loading,
        height: 72,
      );
    }
    return _DplButtonBase(
      variant: (color ?? DplColors.primary) == DplColors.error
          ? _DplButtonVariant.danger
          : _DplButtonVariant.primary,
      label: label,
      icon: icon,
      onPressed: onPressed,
      loading: loading,
      height: 72,
      haptic: HapticFeedbackType.heavy,
    );
  }
}
