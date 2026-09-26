import 'package:flutter/material.dart';

import '../design/dpl_theme.dart';
import 'dpl_buttons.dart';
import 'dpl_empty_state.dart';

/// Inline error block with a retry button. Use this *inside* a screen
/// body when a fetch fails — preferred over a transient snackbar so
/// the user has a clear recovery path.
class DplInlineErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  const DplInlineErrorRetry({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = 'Retry',
  });

  @override
  Widget build(BuildContext context) {
    return DplEmptyView(
      variant: DplEmptyVariant.error,
      title: 'Something went wrong',
      message: message,
      action: onRetry == null
          ? null
          : SizedBox(
              width: 180,
              child: DplPrimaryButton(
                label: retryLabel,
                icon: Icons.refresh,
                onPressed: onRetry,
                height: 48,
              ),
            ),
    );
  }
}

/// Small inline error chip used in dense layouts (e.g. report tabs).
class DplInlineErrorChip extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const DplInlineErrorChip({
    super.key,
    required this.message,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(DplSpacing.md),
      decoration: BoxDecoration(
        color: DplColors.errorBg,
        borderRadius: BorderRadius.circular(DplRadius.md),
        border: Border.all(color: DplColors.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: DplColors.error, size: 18),
          const SizedBox(width: DplSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: DplText.bodySm().copyWith(color: DplColors.error),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}
