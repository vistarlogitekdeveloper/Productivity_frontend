import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/vistar_palette.dart';
import '../../../auth/auth_provider.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../manager/widgets/empty_state.dart';
import '../../manager/widgets/error_retry.dart';
import '../../models/dpl_dispatch_slip.dart';
import '../../models/dpl_production_summary.dart';
import '../providers/dispatch_slips_provider.dart';
import '../widgets/dispatch_slip_status_badge.dart';
import '../widgets/request_dispatch_slip_sheet.dart';
import 'dispatch_slip_detail_screen.dart';

/// Drill-in detail for one production bucket — opened by tapping a
/// `_SummaryRowCard` on the Production Summary screen.
///
/// Layout (top-down):
///   * Header card with the bucket's machine + part + customer P/N +
///     all production stats (actual / plan / done / in-progress /
///     pending) — same numbers as the summary card but expanded.
///   * Available-for-dispatch banner with the Request CTA (Dispatch
///     role only).
///   * Pipeline status strip — per-status count + qty chips. Same
///     palette as the QA / PDI inbox badges.
///   * "All slips" list — every slip for this `(machine, part)`,
///     tappable to open the full printable slip detail.
class BucketDetailScreen extends ConsumerWidget {
  final DplProductionSummary bucket;

  const BucketDetailScreen({super.key, required this.bucket});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(authControllerProvider).asData?.value?.role ?? '';
    // Dispatch-only — the "Request" slip action + its Available banner are
    // a write surface. A manager viewing this via the dashboard toggle is
    // read-only, so they don't see it.
    final canRequestSlip = AppConstants.isDplDispatchRole(role);
    final slipsAsync = ref.watch(
      dplBucketSlipsProvider(
        (machineId: bucket.machineId, partId: bucket.partId),
      ),
    );

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: bucket.machineLabel,
        subtitle: Text(
          bucket.partLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(
            dplBucketSlipsProvider(
              (machineId: bucket.machineId, partId: bucket.partId),
            ),
          );
          try {
            await ref.read(
              dplBucketSlipsProvider(
                (machineId: bucket.machineId, partId: bucket.partId),
              ).future,
            );
          } catch (_) {}
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            _BucketHeader(bucket: bucket),
            const SizedBox(height: 12),
            if (canRequestSlip) _AvailableBanner(bucket: bucket),
            if (canRequestSlip) const SizedBox(height: 12),
            _ProductionStatsRow(bucket: bucket),
            const SizedBox(height: 16),
            _SectionLabel('All dispatch slips'),
            const SizedBox(height: 8),
            slipsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => DplErrorRetry(
                message: e.toString(),
                onRetry: () => ref.invalidate(
                  dplBucketSlipsProvider(
                    (machineId: bucket.machineId, partId: bucket.partId),
                  ),
                ),
              ),
              data: (res) {
                if (res.isError) {
                  return DplErrorRetry(
                    message: res.error ?? 'Failed to load slips.',
                    onRetry: () => ref.invalidate(
                      dplBucketSlipsProvider(
                        (machineId: bucket.machineId, partId: bucket.partId),
                      ),
                    ),
                  );
                }
                final items =
                    res.data?.items ?? const <DplDispatchSlip>[];
                if (items.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: DplEmptyState(
                      icon: Icons.receipt_long_outlined,
                      title: 'No slips yet for this bucket',
                      message:
                          'Slips you request for this (machine, part) appear here.',
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final s in items) ...[
                      _BucketSlipTile(
                        slip: s,
                        bucketMachineId: bucket.machineId,
                        bucketPartId: bucket.partId,
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _BucketHeader extends StatelessWidget {
  final DplProductionSummary bucket;
  const _BucketHeader({required this.bucket});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: DplColors.divider, width: 1.2),
        boxShadow: DplShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: DplColors.primaryTint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.precision_manufacturing_outlined,
                  size: 22,
                  color: DplColors.primaryDark,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bucket.machineLabel,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (bucket.machineCode.isNotEmpty &&
                        bucket.machineCode != bucket.machineLabel)
                      Text(
                        'Code: ${bucket.machineCode}',
                        style: TextStyle(
                          color: DplColors.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              _CompletionPill(ratio: bucket.completionRatio),
            ],
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: DplColors.divider),
          const SizedBox(height: 12),
          Text(
            bucket.partLabel,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 6),
          if (bucket.customerPartNo.isNotEmpty)
            _MetaRow(label: 'Customer P/N', value: bucket.customerPartNo),
          if (bucket.substratePartNo.isNotEmpty)
            _MetaRow(label: 'Substrate P/N', value: bucket.substratePartNo),
          if (bucket.materialCode.isNotEmpty)
            _MetaRow(label: 'Material code', value: bucket.materialCode),
          if (bucket.description.isNotEmpty &&
              bucket.description != bucket.partName)
            _MetaRow(label: 'Description', value: bucket.description),
        ],
      ),
    );
  }
}

class _CompletionPill extends StatelessWidget {
  final double ratio;
  const _CompletionPill({required this.ratio});

  @override
  Widget build(BuildContext context) {
    final pct = (ratio * 100).clamp(0, 100).toStringAsFixed(0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: DplColors.successBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: DplColors.success.withValues(alpha: 0.25)),
      ),
      child: Text(
        '$pct%',
        style: TextStyle(
          color: DplColors.success,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final String label;
  final String value;
  const _MetaRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                color: DplColors.textSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: DplColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductionStatsRow extends StatelessWidget {
  final DplProductionSummary bucket;
  const _ProductionStatsRow({required this.bucket});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: DplColors.divider, width: 1.2),
        boxShadow: DplShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PRODUCTION',
            style: TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w800,
              fontSize: 10.5,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  label: 'Actual',
                  value: fmt.format(bucket.totalActualQty),
                  emphasised: true,
                ),
              ),
              Expanded(
                child: _StatTile(
                  label: 'Plan',
                  value: fmt.format(bucket.totalPlanQty),
                ),
              ),
              Expanded(
                child: _StatTile(
                  label: 'Done',
                  value: '${bucket.completedItems}',
                ),
              ),
              Expanded(
                child: _StatTile(
                  label: 'In-prog',
                  value: '${bucket.inProgressItems}',
                ),
              ),
              Expanded(
                child: _StatTile(
                  label: 'Pending',
                  value: '${bucket.pendingItems}',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasised;
  const _StatTile({
    required this.label,
    required this.value,
    this.emphasised = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: emphasised ? DplColors.primaryDark : DplColors.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: emphasised ? 18 : 15,
            height: 1.1,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: TextStyle(
            color: DplColors.textSecondary,
            fontWeight: FontWeight.w600,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _AvailableBanner extends StatelessWidget {
  final DplProductionSummary bucket;
  const _AvailableBanner({required this.bucket});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final qty = bucket.availableForDispatchQty;
    final hasQty = qty > 0;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            DplColors.primaryTint,
            Color.lerp(DplColors.primaryTint, DplColors.primary, 0.08)!,
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.primaryLine, width: 1.2),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: DplColors.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: VistarPalette.primaryLine),
            ),
            child: Icon(
              Icons.local_shipping_outlined,
              size: 22,
              color: DplColors.primaryDark,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Available for Dispatch',
                  style: TextStyle(
                    color: DplColors.primaryDark,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      fmt.format(qty),
                      style: TextStyle(
                        color: DplColors.primaryDark,
                        fontWeight: FontWeight.w800,
                        fontSize: 24,
                        height: 1.1,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'NOS',
                      style: TextStyle(
                        color: DplColors.primaryDark,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'of ${fmt.format(bucket.totalActualQty)} actual',
                        style: TextStyle(
                          color: DplColors.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: hasQty
                ? () => RequestDispatchSlipSheet.show(
                      context,
                      bucket: bucket,
                    )
                : null,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Request'),
            style: FilledButton.styleFrom(
              backgroundColor: DplColors.primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: DplColors.neutralBg,
              disabledForegroundColor: DplColors.textTertiary,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: DplColors.textSecondary,
          fontWeight: FontWeight.w800,
          fontSize: 11,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// One slip row inside the bucket's "all slips" list. Tap → opens the
/// printable slip detail screen for that slip.
///
/// With multi-item slips the backend's filter (`machine_id=...&
/// part_id=...`) returns any slip whose items[] contains the bucket —
/// but the slip can carry additional items for other buckets too. The
/// tile shows **only the portion of qty that belongs to this bucket**
/// so the user sees an accurate per-bucket number, plus a
/// `+N more items` chip when the slip spans other buckets too.
class _BucketSlipTile extends StatelessWidget {
  final DplDispatchSlip slip;
  final int bucketMachineId;
  final int bucketPartId;

  const _BucketSlipTile({
    required this.slip,
    required this.bucketMachineId,
    required this.bucketPartId,
  });

  /// Sum of qty across the slip's items that match this bucket. If the
  /// slip predates the multi-item refactor and falls back to the
  /// single-item shape, `slip.qty` ends up driving the same number via
  /// the model's compat getter.
  int get _qtyForThisBucket {
    return slip.items
        .where((it) =>
            it.machineId == bucketMachineId && it.partId == bucketPartId)
        .fold<int>(0, (sum, it) => sum + it.qty);
  }

  /// Count of items on the slip that belong to OTHER buckets. Used
  /// to surface a tiny "+2 more" hint so the user understands the
  /// slip's qty here is just a slice of a bigger multi-item dispatch.
  int get _otherItemCount {
    return slip.items
        .where((it) =>
            it.machineId != bucketMachineId || it.partId != bucketPartId)
        .length;
  }

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final dateFmt = DateFormat('dd MMM yyyy, HH:mm');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DispatchSlipDetailScreen(slipId: slip.id),
          ),
        ),
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: DplColors.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: DplColors.divider, width: 1.2),
            boxShadow: DplShadows.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      slip.slipNo,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                        letterSpacing: 0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DispatchSlipStatusBadge(status: slip.status),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _MiniStat(
                    icon: Icons.inventory_2_outlined,
                    label: 'Qty',
                    value: '${fmt.format(_qtyForThisBucket)} NOS',
                  ),
                  if (_otherItemCount > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: DplColors.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: DplColors.primary.withValues(alpha: 0.25),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        '+$_otherItemCount more',
                        style: TextStyle(
                          color: DplColors.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 10.5,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 12),
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          Icons.person_outline,
                          size: 13,
                          color: DplColors.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            slip.requestedBy?.name ?? '-',
                            style: TextStyle(
                              color: DplColors.textSecondary,
                              fontWeight: FontWeight.w600,
                              fontSize: 11.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (slip.requestedAt != null)
                Row(
                  children: [
                    Icon(
                      Icons.schedule_outlined,
                      size: 12,
                      color: DplColors.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      dateFmt.format(slip.requestedAt!.toLocal()),
                      style: TextStyle(
                        color: DplColors.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              Divider(height: 1, color: DplColors.divider),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _ApprovalChip(
                      label: 'QA',
                      state: slip.qaState,
                      name: slip.qaApproval?.name,
                      rejecterName: slip.rejection?.isQa == true
                          ? slip.rejection?.name
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ApprovalChip(
                      label: 'PDI',
                      state: slip.pdiState,
                      name: slip.pdiApproval?.name,
                      rejecterName: slip.rejection?.isPdi == true
                          ? slip.rejection?.name
                          : null,
                    ),
                  ),
                ],
              ),
              // Show "Dispatched on" once the slip has shipped.
              if (slip.dispatchedAt != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.local_shipping_outlined,
                      size: 13,
                      color: DplColors.success,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Dispatched ${dateFmt.format(slip.dispatchedAt!.toLocal())}'
                      '${slip.dispatchedBy?.name.isNotEmpty == true ? "  by ${slip.dispatchedBy!.name}" : ""}',
                      style: TextStyle(
                        color: DplColors.success,
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _MiniStat({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: DplColors.textSecondary),
        const SizedBox(width: 4),
        Text(
          '$label: ',
          style: TextStyle(
            color: DplColors.textSecondary,
            fontWeight: FontWeight.w600,
            fontSize: 11.5,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: DplColors.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: 12,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _ApprovalChip extends StatelessWidget {
  final String label;
  final DispatchStationState state;
  final String? name;
  final String? rejecterName;
  const _ApprovalChip({
    required this.label,
    required this.state,
    required this.name,
    required this.rejecterName,
  });

  @override
  Widget build(BuildContext context) {
    final palette = _paletteFor(state);
    final body = switch (state) {
      DispatchStationState.approved => name?.trim().isEmpty ?? true ? '-' : name!,
      DispatchStationState.pending => 'Pending',
      DispatchStationState.rejected =>
        (rejecterName?.trim().isEmpty ?? true) ? 'Rejected' : 'Rejected by $rejecterName',
    };
    final icon = switch (state) {
      DispatchStationState.approved => Icons.check_circle_rounded,
      DispatchStationState.pending => Icons.access_time_rounded,
      DispatchStationState.rejected => Icons.cancel_rounded,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.fg.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: palette.fg),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: palette.fg,
                    fontWeight: FontWeight.w800,
                    fontSize: 10,
                    letterSpacing: 0.4,
                  ),
                ),
                Text(
                  body,
                  style: TextStyle(
                    color: palette.fg,
                    fontWeight: FontWeight.w700,
                    fontSize: 11.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  ({Color fg, Color bg}) _paletteFor(DispatchStationState state) {
    switch (state) {
      case DispatchStationState.approved:
        return (fg: DplColors.success, bg: DplColors.successBg);
      case DispatchStationState.pending:
        return (fg: DplColors.warning, bg: DplColors.warningBg);
      case DispatchStationState.rejected:
        return (fg: DplColors.error, bg: DplColors.errorBg);
    }
  }
}
