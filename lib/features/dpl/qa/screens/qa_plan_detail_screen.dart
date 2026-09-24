import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_empty_state.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_refresh_icon_button.dart';
import '../../core/widgets/dpl_shimmer.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../core/widgets/dpl_stat_tile.dart';
import '../../manager/providers/dpl_plan_detail_provider.dart';
import '../../manager/widgets/status_badge.dart';
import '../../models/dpl_location.dart';
import '../../models/dpl_part_sticker.dart';
import '../../models/dpl_production_plan.dart';
import '../../models/dpl_production_plan_item.dart';
import '../providers/qa_production_provider.dart';
import '../widgets/location_picker_sheet.dart';

/// Plan items for one plan, each with its printing allowance.
///
/// Mirrors the Manager's Plan Detail layout (same endpoint, same rows) and
/// adds the one thing QA needs on top: how many stickers each item still has
/// left, and the button that starts the scan.
class QaPlanDetailScreen extends ConsumerWidget {
  final int planId;

  const QaPlanDetailScreen({super.key, required this.planId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dplPlanDetailProvider(planId));

    return Scaffold(
      appBar: DplAppBar(
        title: 'QA — Plan Detail',
        actions: [
          DplRefreshIconButton(
            onRefresh: () async => ref.invalidate(dplPlanDetailProvider(planId)),
          ),
        ],
      ),
      body: async.when(
        loading: () => const DplDashboardShimmer(),
        error: (e, _) => DplInlineErrorRetry(
          message: e.toString(),
          onRetry: () => ref.invalidate(dplPlanDetailProvider(planId)),
        ),
        data: (res) {
          if (res.isError || res.data == null) {
            return DplInlineErrorRetry(
              message: res.error ?? 'Failed to load the plan.',
              onRetry: () => ref.invalidate(dplPlanDetailProvider(planId)),
            );
          }
          return _body(context, ref, res.data!);
        },
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, DplProductionPlan plan) {
    // In-progress first, then pending, completed pinned to the bottom — the
    // order the floor works in, and the same one the supervisor screen uses.
    final items = plan.items.sortedForExecution();
    final fmt = NumberFormat.decimalPattern();

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(dplPlanDetailProvider(planId)),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
        children: [
          DplCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        plan.machineName.isEmpty
                            ? 'Machine #${plan.machineId}'
                            : plan.machineName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    DplStatusBadge(status: plan.status),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  DateFormat('dd MMM yyyy').format(plan.planDate),
                  style: const TextStyle(
                    color: Color(0xFF5D6A7A),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: DplStatTile(
                        label: 'Plan Qty',
                        value: fmt.format(plan.effectiveTotalPlanQty),
                      ),
                    ),
                    Expanded(
                      child: DplStatTile(
                        label: 'Actual',
                        value: fmt.format(plan.effectiveTotalActualQty),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Plan Items',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 8),
          if (items.isEmpty)
            const DplEmptyView(
              title: 'No items on this plan',
              message: 'Nothing has been planned for this machine yet.',
              icon: Icons.inbox_outlined,
            )
          else
            ...items.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _QaPlanItemCard(item: item, planId: planId),
              ),
            ),
        ],
      ),
    );
  }
}

/// One plan-item row: identity, plan vs actual, and the printing allowance.
class _QaPlanItemCard extends ConsumerWidget {
  final DplProductionPlanItem item;
  final int planId;

  const _QaPlanItemCard({required this.item, required this.planId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(qaStickerSummaryProvider(item.id));
    final summary = summaryAsync.asData?.value.data;

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '#${item.planNo}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    color: Color(0xFF334155),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.partNumber.isEmpty ? '—' : item.partNumber,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      item.partDescription.isEmpty
                          ? item.partName
                          : item.partDescription,
                      style: const TextStyle(
                        color: Color(0xFF5D6A7A),
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              DplStatusBadge(status: item.status),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DplStatTile(label: 'Plan', value: '${item.planQty}'),
              ),
              Expanded(
                child: DplStatTile(label: 'Actual', value: '${item.actualQty}'),
              ),
              Expanded(
                child: DplStatTile(
                  label: 'Printed',
                  value: summary == null ? '—' : '${summary.printedQty}',
                ),
              ),
              Expanded(
                child: DplStatTile(
                  label: 'Left',
                  value: summary == null ? '—' : '${summary.remainingQty}',
                  valueColor: summary == null
                      ? null
                      : (summary.remainingQty > 0
                          ? const Color(0xFF15803D)
                          : const Color(0xFF9CA3AF)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _ActionRow(item: item, planId: planId, summaryAsync: summaryAsync),
          // Storage only becomes a question once every piece has a label on
          // it. An unlabelled part on a rack is stock nobody can trace back
          // off it, and the server refuses that case anyway.
          if (summary != null && summary.printedQty > 0)
            _LocationRow(item: item, planId: planId, summary: summary),
        ],
      ),
    );
  }
}

/// Where this batch is stored, and the control to change it.
class _LocationRow extends ConsumerWidget {
  final DplProductionPlanItem item;
  final int planId;
  final DplStickerSummary summary;

  const _LocationRow({
    required this.item,
    required this.planId,
    required this.summary,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(qaPlanItemLocationProvider(item.id));
    final assignment = async.asData?.value.data;

    // Only offer storage once the batch is fully labelled. Partially labelled
    // output on a rack is exactly the untraceable stock this flow exists to
    // prevent, so the button states the reason rather than simply not working.
    final fullyLabelled = summary.remainingQty == 0 && summary.printedQty > 0;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Row(
          children: [
            Icon(
              assignment == null
                  ? Icons.location_off_outlined
                  : Icons.place_rounded,
              size: 18,
              color: assignment == null
                  ? const Color(0xFF94A3B8)
                  : const Color(0xFF15803D),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    assignment == null ? 'Not stored yet' : 'Stored at',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  Text(
                    assignment == null
                        ? (fullyLabelled
                            ? 'Assign a storage location'
                            : 'Print all labels first')
                        : '${assignment.location?.displayLabel ?? 'Location #${assignment.locationId}'}'
                            ' · ${assignment.qty} pcs',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: assignment == null
                          ? const Color(0xFF475569)
                          : const Color(0xFF111827),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (async.isLoading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (assignment == null)
              TextButton(
                onPressed: fullyLabelled
                    ? () => _assign(context, ref, null)
                    : null,
                child: const Text('Assign'),
              )
            else
              // A menu rather than a bare "Change": taking a batch back off a
              // rack has to be reachable, otherwise the location is a one-way
              // door and the rack's occupancy never comes back down.
              PopupMenuButton<String>(
                tooltip: 'Storage options',
                onSelected: (v) {
                  if (v == 'change') {
                    _assign(context, ref, assignment);
                  } else if (v == 'release') {
                    _release(context, ref, assignment);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'change',
                    child: Text('Move to another location'),
                  ),
                  PopupMenuItem(
                    value: 'release',
                    child: Text('Remove from location'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _assign(
    BuildContext context,
    WidgetRef ref,
    DplLocationAssignment? current,
  ) async {
    final qty = summary.printedQty;
    final picked = await LocationPickerSheet.show(
      context,
      requiredQty: qty,
      selectedLocationId: current?.locationId,
    );
    if (picked == null || !context.mounted) return;

    final res = await ref.read(dplApiServiceProvider).assignPlanItemLocation(
          planItemId: item.id,
          locationId: picked.id,
          qty: qty,
        );
    if (!context.mounted) return;

    if (res.isError) {
      // LOCATION_FULL / LABELS_INCOMPLETE / QTY_EXCEEDS_PRODUCED all arrive
      // with a message that already names the numbers, so show it verbatim.
      DplSnacks.error(context, res.error ?? 'Failed to assign the location.');
    } else {
      DplSnacks.success(context, 'Stored at ${picked.code}.');
    }
    ref.invalidate(qaPlanItemLocationProvider(item.id));
  }

  Future<void> _release(
    BuildContext context,
    WidgetRef ref,
    DplLocationAssignment assignment,
  ) async {
    final code = assignment.location?.code ?? 'this location';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove from $code?'),
        content: Text(
          '${assignment.qty} piece${assignment.qty == 1 ? '' : 's'} will be '
          'taken off $code and the space freed up. The move is kept in the '
          'history, so where this batch was stored stays answerable.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final res =
        await ref.read(dplApiServiceProvider).releasePlanItemLocation(item.id);
    if (!context.mounted) return;

    if (res.isError) {
      DplSnacks.error(context, res.error ?? 'Failed to remove from location.');
    } else {
      DplSnacks.success(context, 'Removed from $code.');
    }
    ref.invalidate(qaPlanItemLocationProvider(item.id));
  }
}

class _ActionRow extends ConsumerWidget {
  final DplProductionPlanItem item;
  final int planId;
  final AsyncValue<dynamic> summaryAsync;

  const _ActionRow({
    required this.item,
    required this.planId,
    required this.summaryAsync,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final res = summaryAsync.asData?.value;
    final summary = res?.data;

    // The cap is mirrored here purely so the button reads honestly. The server
    // re-checks it under a row lock on every issue — this is a courtesy, not
    // the enforcement.
    final blockedReason = summary == null
        ? null
        : summary.wasReset
            // Plan reopened after labels were printed — "All 0 printed" would
            // be nonsense here, and the operator needs to know why.
            ? 'Quantity reset — plan reopened'
            : summary.noProductionYet
                ? 'Waiting for production to be recorded'
                : (!summary.canPrint
                    ? 'All ${summary.actualQty} stickers printed'
                    : null);

    if (summaryAsync.isLoading) {
      return const SizedBox(
        height: 36,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (res != null && res.isError) {
      return Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: Color(0xFFB91C1C)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              res.error ?? 'Could not read the sticker count.',
              style: const TextStyle(fontSize: 12, color: Color(0xFFB91C1C)),
            ),
          ),
          TextButton(
            onPressed: () => ref.invalidate(qaStickerSummaryProvider(item.id)),
            child: const Text('Retry'),
          ),
        ],
      );
    }

    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: blockedReason != null
            ? null
            // The expected part travels with the route so the scanner can
            // reject material for a different part before anything is issued.
            // Query params rather than `extra` so a refresh or a deep link
            // does not silently drop the constraint.
            : () => context.push(
                  Uri(
                    path: '/dpl/qa/plans/$planId/items/${item.id}/scan',
                    queryParameters: {
                      'partId': '${item.partId}',
                      if (item.partNumber.isNotEmpty) 'partNo': item.partNumber,
                    },
                  ).toString(),
                ),
        icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
        label: Text(
          blockedReason ?? 'Scan raw material & print labels',
        ),
      ),
    );
  }
}
