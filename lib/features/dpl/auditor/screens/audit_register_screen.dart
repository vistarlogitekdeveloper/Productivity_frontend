import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../models/dpl_pallet_audit.dart';
import '../auditor_providers.dart';

/// What has been checked, and what failed.
///
/// A rejected row carries its REASON on the face of the card rather than
/// behind a tap. The reason is the whole reason the record exists — whoever
/// picks the pallet up next needs it, and a register that makes them open
/// every row to find the one that matters is a register nobody reads.
class DplAuditRegisterScreen extends ConsumerWidget {
  const DplAuditRegisterScreen({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(dplAuditRegisterFilterProvider);
    final async = ref.watch(dplAuditRegisterProvider);

    final body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final s in const [
                  ('all', 'All'),
                  ('rejected', 'Rejected'),
                  ('approved', 'Approved'),
                  ('in_progress', 'In progress'),
                ]) ...[
                  ChoiceChip(
                    selected: status == s.$1,
                    onSelected: (_) => ref
                        .read(dplAuditRegisterFilterProvider.notifier)
                        .set(s.$1),
                    label: Text(s.$2),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => DplInlineErrorRetry(
              message: e.toString(),
              onRetry: () => ref.invalidate(dplAuditRegisterProvider),
            ),
            data: (res) {
              if (res.isError) {
                return DplInlineErrorRetry(
                  message: res.error ?? 'Failed to load the register.',
                  onRetry: () => ref.invalidate(dplAuditRegisterProvider),
                );
              }
              final rows = res.data?.audits ?? const <DplPalletAudit>[];
              if (rows.isEmpty) {
                return ListView(
                  padding: const EdgeInsets.all(28),
                  children: [
                    const SizedBox(height: 40),
                    Icon(
                      Icons.fact_check_outlined,
                      size: 40,
                      color: DplColors.textTertiary,
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Nothing checked yet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                );
              }
              return RefreshIndicator(
                onRefresh: () async => ref.invalidate(dplAuditRegisterProvider),
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 28),
                  itemCount: rows.length,
                  itemBuilder: (_, i) => _row(rows[i]),
                ),
              );
            },
          ),
        ),
      ],
    );

    if (!showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: AppBar(title: const Text('Checked')),
      body: body,
    );
  }

  Widget _row(DplPalletAudit a) {
    final (colour, icon, label) = switch (a.status) {
      'approved' => (DplColors.success, Icons.verified, 'Approved'),
      'rejected' => (DplColors.error, Icons.report_problem_outlined, 'Rejected'),
      'in_progress' => (DplColors.warning, Icons.pending_outlined, 'In progress'),
      _ => (DplColors.textSecondary, Icons.remove_circle_outline, 'Abandoned'),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DplCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: colour),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    a.palletNo ?? 'Pallet #${a.palletId}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: colour,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              [
                '${a.matchedQty} of ${a.expectedQty} found',
                if (a.missingQty > 0) '${a.missingQty} missing',
                if (a.foreignQty > 0) '${a.foreignQty} not from it',
                if ((a.auditedByName ?? '').isNotEmpty) a.auditedByName!,
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
            ),
            if ((a.reason ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: DplColors.errorBg,
                  borderRadius: BorderRadius.circular(DplRadius.sm),
                ),
                child: Text(
                  a.reason!,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: DplColors.error,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
