import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/widgets/dpl_empty_state.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../models/dpl_admin.dart';
import '../providers/admin_providers.dart';

/// Account history — who changed which account, and when.
///
/// Separate from the production audit log, which records machine and plan
/// events. "Who gave this person dispatch rights in March" is a different
/// question from "who stopped machine 3", usually asked by a different person
/// for a different reason.
///
/// Append-only and read-only: there is no edit or delete, here or in the API.
class AdminActivityScreen extends ConsumerWidget {
  const AdminActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminAuditProvider);

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => DplInlineErrorRetry(
          message: e.toString(),
          onRetry: () => ref.invalidate(adminAuditProvider),
        ),
        data: (res) {
          if (res.isError) {
            return DplInlineErrorRetry(
              message: res.error ?? 'Failed to load the account history.',
              onRetry: () => ref.invalidate(adminAuditProvider),
            );
          }
          final rows = res.data ?? const <DplUserAuditEntry>[];
          if (rows.isEmpty) {
            return const DplEmptyView(
              title: 'Nothing recorded yet',
              message:
                  'Every account created, edited, disabled or re-enabled shows '
                  'up here, along with changes to the access rules.',
              icon: Icons.history,
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(adminAuditProvider),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
              itemCount: rows.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _AuditTile(entry: rows[i]),
            ),
          );
        },
      ),
    );
  }
}

class _AuditTile extends StatelessWidget {
  final DplUserAuditEntry entry;

  const _AuditTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final summary = entry.changeSummary;
    final when = entry.createdAt;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        border: Border.all(color: DplColors.divider),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_iconFor(entry.action), size: 18, color: _colorFor(entry.action)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.actionLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
                if (entry.targetEmail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    entry.targetEmail,
                    style: TextStyle(
                      fontSize: 12,
                      color: DplColors.textSecondary,
                    ),
                  ),
                ],
                if (summary.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    summary,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: DplColors.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  [
                    if (entry.actorName.isNotEmpty) 'by ${entry.actorName}',
                    if (when != null)
                      DateFormat('d MMM yyyy, HH:mm').format(when.toLocal()),
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: 11,
                    color: DplColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(String action) {
    switch (action) {
      case 'created':
        return Icons.person_add_alt_1;
      case 'disabled':
        return Icons.block;
      case 'enabled':
        return Icons.check_circle_outline;
      case 'password_reset':
        return Icons.key_outlined;
      case 'role_changed':
        return Icons.badge_outlined;
      case 'permissions_changed':
        return Icons.tune;
      case 'org_created':
      case 'org_updated':
        return Icons.apartment_outlined;
      default:
        return Icons.edit_outlined;
    }
  }

  static Color _colorFor(String action) {
    switch (action) {
      case 'created':
      case 'enabled':
        return DplColors.success;
      case 'disabled':
        return DplColors.error;
      case 'permissions_changed':
      case 'role_changed':
        return DplColors.warning;
      default:
        return DplColors.neutral;
    }
  }
}
