import 'package:flutter/material.dart';

import '../design/dpl_format.dart';
import '../design/dpl_theme.dart';

/// Vertical activity log built from the raw `remarks` field on a
/// production plan. Each entry shows the action, the IST-formatted
/// timestamp, and a subtle timeline line connecting consecutive
/// entries.
class ActivityLogList extends StatelessWidget {
  final List<ActivityLogEntry> entries;

  /// When true, list shows in reverse chronological order (newest at
  /// the top). Default false — order is preserved as written.
  final bool reverseChronological;

  const ActivityLogList({
    super.key,
    required this.entries,
    this.reverseChronological = false,
  });

  /// Convenience constructor that parses the raw remarks string.
  ActivityLogList.fromRemarks(String? remarks, {super.key, bool reverse = false})
      : entries = DplActivityLog.parse(remarks),
        reverseChronological = reverse;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final ordered =
        reverseChronological ? entries.reversed.toList() : entries;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < ordered.length; i++)
          _Entry(
            entry: ordered[i],
            isFirst: i == 0,
            isLast: i == ordered.length - 1,
          ),
      ],
    );
  }
}

class _Entry extends StatelessWidget {
  final ActivityLogEntry entry;
  final bool isFirst;
  final bool isLast;

  const _Entry({
    required this.entry,
    required this.isFirst,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Timeline rail (line + dot)
          SizedBox(
            width: 24,
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    width: 2,
                    color: isFirst ? Colors.transparent : DplColors.divider,
                  ),
                ),
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: DplColors.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(
                  child: Container(
                    width: 2,
                    color: isLast ? Colors.transparent : DplColors.divider,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: DplSpacing.sm),
          // Entry content
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: DplSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.action,
                    style: DplText.body()
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                  if (entry.formatted.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(entry.formatted, style: DplText.caption()),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
