import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/widgets/shimmer_skeleton.dart';
import '../../../auth/auth_provider.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_constants.dart';
import '../../journey/screens/consolidated_slip_screen.dart';
import '../../journey/widgets/assign_driver_button.dart';
import '../../journey/widgets/trip_journey_drawer.dart';
import '../../manager/widgets/empty_state.dart';
import '../../manager/widgets/error_retry.dart';
import '../../models/dpl_dispatch_slip.dart';
import '../../models/dpl_trip_dispatch_readiness.dart';
import '../../tracking/screens/trip_track_map_screen.dart';
import '../providers/dispatch_slips_provider.dart';
import '../widgets/dispatch_slip_status_badge.dart';
import 'dispatch_slip_detail_screen.dart';
import 'trip_slips_screen.dart';

/// Lists dispatch slips with role-aware status tabs:
///   * QA → "Pending QA" inbox + history
///   * PDI → "Pending PDI" inbox + history
///   * Dispatch → "My slips" (all statuses)
///   * Manager → everything, all statuses
///
/// Embedded inside [DplSummaryShell] (no own AppBar by default) so the
/// shell's standard branded AppBar wraps it.
class DispatchSlipsInboxScreen extends ConsumerStatefulWidget {
  final bool showAppBar;
  const DispatchSlipsInboxScreen({super.key, this.showAppBar = false});

  @override
  ConsumerState<DispatchSlipsInboxScreen> createState() =>
      _DispatchSlipsInboxScreenState();
}

class _DispatchSlipsInboxScreenState
    extends ConsumerState<DispatchSlipsInboxScreen> {
  late final TextEditingController _searchCtrl;
  Timer? _debounce;
  bool _didApplyRoleDefault = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(
      text: ref.read(dplDispatchSlipFiltersProvider).query,
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Pick the "inbox" status for the user's role the first time we
  /// build. Runs once so the user can still flip between statuses
  /// afterwards without us overriding their choice on rebuild.
  void _applyRoleDefaultIfNeeded(String role) {
    if (_didApplyRoleDefault) return;
    _didApplyRoleDefault = true;
    final current = ref.read(dplDispatchSlipFiltersProvider).status;
    if (current != null) return;
    String? defaultStatus;
    // QA role lands on "Pending PDI" too — QA approval was removed
    // from the workflow, so QA users effectively act on PDI-pending
    // slips. Keep the QA branch commented for easy re-enable.
    // if (AppConstants.isDplQaRole(role)) {
    //   defaultStatus = DplDispatchSlipStatus.pendingQa;
    // } else if (AppConstants.isDplPdiRole(role)) {
    if (AppConstants.isDplDeoRole(role)) {
      // DEO owns the invoice stage — land them on their queue.
      defaultStatus = DplDispatchSlipStatus.pendingDeo;
    } else if (AppConstants.isDplPdiRole(role) ||
        AppConstants.isDplQaRole(role)) {
      defaultStatus = DplDispatchSlipStatus.pendingPdi;
    }
    if (defaultStatus != null) {
      Future.microtask(() {
        if (!mounted) return;
        ref
            .read(dplDispatchSlipFiltersProvider.notifier)
            .setStatus(defaultStatus);
      });
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      ref.read(dplDispatchSlipFiltersProvider.notifier).setQuery(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(authControllerProvider).asData?.value?.role ?? '';
    _applyRoleDefaultIfNeeded(role);

    final filters = ref.watch(dplDispatchSlipFiltersProvider);
    final pageAsync = ref.watch(dplDispatchSlipsProvider);

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusTabs(role: role),
        _SearchBar(
          controller: _searchCtrl,
          onChanged: _onSearchChanged,
          onClear: () {
            _searchCtrl.clear();
            ref.read(dplDispatchSlipFiltersProvider.notifier).setQuery('');
          },
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(dplDispatchSlipsProvider);
              try {
                await ref.read(dplDispatchSlipsProvider.future);
              } catch (_) {}
            },
            child: pageAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: SkeletonList(count: 5),
              ),
              error: (e, _) => ListView(
                children: [
                  DplErrorRetry(
                    message: e.toString(),
                    onRetry: () => ref.invalidate(dplDispatchSlipsProvider),
                  ),
                ],
              ),
              data: (res) {
                if (res.isError) {
                  return ListView(
                    children: [
                      DplErrorRetry(
                        message: res.error ?? 'Failed to load slips.',
                        onRetry: () =>
                            ref.invalidate(dplDispatchSlipsProvider),
                      ),
                    ],
                  );
                }
                final page = res.data ?? DplDispatchSlipPage.empty();
                if (page.items.isEmpty) {
                  return ListView(
                    children: [
                      const SizedBox(height: 60),
                      DplEmptyState(
                        icon: Icons.inbox_outlined,
                        title: _emptyTitleFor(filters.status, role),
                        message: _emptyMessageFor(filters.status, role),
                      ),
                    ],
                  );
                }
                // Group by trip so a trip with N slips collapses to a
                // single card. Legacy slips (no trip_id) render as
                // standalone rows, interleaved in original order. The
                // visible page may not contain every slip cut from a
                // trip — if a trip's slips spill across paginated pages
                // the card surfaces only what's loaded here (see
                // backend ask in the PR description).
                final rows = _groupByTrip(page.items);
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: rows.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    if (i == rows.length) {
                      return _Pagination(
                        page: page,
                        onChange: (p) => ref
                            .read(dplDispatchSlipFiltersProvider.notifier)
                            .setPage(p),
                      );
                    }
                    final row = rows[i];
                    // Identity keys are REQUIRED here, not cosmetic. These
                    // cards own per-trip state fetched on init (the driver
                    // chip). Without a key Flutter reuses the Element at a
                    // given index across rebuilds — switching status tabs or
                    // paginating then leaves a card showing the driver of
                    // whichever trip previously occupied that slot.
                    if (row is _TripGroupRow) {
                      return _TripGroupCard(
                        key: ValueKey('trip-${row.tripId}'),
                        group: row,
                      );
                    }
                    final slip = (row as _LooseSlipRow).slip;
                    return _SlipRowCard(key: ValueKey('slip-${slip.id}'), slip: slip);
                  },
                );
              },
            ),
          ),
        ),
      ],
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: AppBar(
        title: const Text('Dispatch Slips'),
      ),
      body: body,
    );
  }

  String _emptyTitleFor(String? status, String role) {
    if (status == DplDispatchSlipStatus.pendingQa) return 'QA inbox is clear';
    if (status == DplDispatchSlipStatus.pendingDeo) return 'DEO inbox is clear';
    if (status == DplDispatchSlipStatus.pendingPdi) return 'PDI inbox is clear';
    if (AppConstants.isDplDispatchRole(role)) return 'No slips yet';
    return 'No slips found';
  }

  String _emptyMessageFor(String? status, String role) {
    if (status == DplDispatchSlipStatus.pendingQa) {
      return 'Nothing is waiting for QA approval right now.';
    }
    if (status == DplDispatchSlipStatus.pendingDeo) {
      return 'No trips are waiting for an invoice right now.';
    }
    if (status == DplDispatchSlipStatus.pendingPdi) {
      return 'Nothing is waiting for PDI approval right now.';
    }
    if (AppConstants.isDplDispatchRole(role)) {
      return 'Tap "Request Dispatch Slip" on a production bucket to start.';
    }
    return 'Try adjusting the filters above.';
  }

  /// Buckets the visible page's slips by `trip_id` while preserving the
  /// list's original order (a trip group lands at the position of its
  /// FIRST slip). Slips without a `trip_id` (legacy single-shot slips
  /// cut via the manual machine-picker) pass through as standalone
  /// rows so this change doesn't hide them.
  List<_InboxRow> _groupByTrip(List<DplDispatchSlip> items) {
    final rows = <_InboxRow>[];
    final byTrip = <int, int>{}; // trip_id → row index
    for (final slip in items) {
      final tripId = slip.tripId;
      if (tripId == null) {
        rows.add(_LooseSlipRow(slip));
        continue;
      }
      final existing = byTrip[tripId];
      if (existing == null) {
        byTrip[tripId] = rows.length;
        rows.add(_TripGroupRow(
          tripId: tripId,
          tripNumber: slip.tripNumber ?? 0,
          plantCode: slip.plant.code,
          plantName: slip.plant.name,
          slips: [slip],
        ));
      } else {
        (rows[existing] as _TripGroupRow).slips.add(slip);
      }
    }
    return rows;
  }
}

/// Sealed row type — either a one-card trip group or a legacy
/// standalone slip. Lets the inbox `ListView.builder` switch on shape
/// in one place.
sealed class _InboxRow {
  const _InboxRow();
}

class _TripGroupRow extends _InboxRow {
  final int tripId;
  final int tripNumber;
  final String plantCode;
  final String plantName;
  final List<DplDispatchSlip> slips;

  _TripGroupRow({
    required this.tripId,
    required this.tripNumber,
    required this.plantCode,
    required this.plantName,
    required this.slips,
  });

  int get totalQty => slips.fold<int>(0, (s, x) => s + x.totalQty);
}

class _LooseSlipRow extends _InboxRow {
  final DplDispatchSlip slip;
  const _LooseSlipRow(this.slip);
}

/// Status tab strip — shows counts so QA / PDI can see their queue
/// depth at a glance. "All" tab clears the status filter.
class _StatusTabs extends ConsumerWidget {
  final String role;
  const _StatusTabs({required this.role});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(dplDispatchSlipFiltersProvider);
    final pageAsync = ref.watch(dplDispatchSlipsProvider);
    final totals = pageAsync.asData?.value.data?.totals ??
        const DplDispatchSlipTotals();

    // Role-specific ordering: each role's primary inbox first, then the
    // others, then All. Dispatch sees all open + closed states.
    //
    // QA approval step was removed from the workflow — QA users now
    // get the PDI tab set. The original QA-first branch + the
    // "Pending QA" chip in the catch-all branch are commented for
    // easy re-enable.
    final List<_StatusTabSpec> tabs;
    // if (AppConstants.isDplQaRole(role)) {
    //   tabs = [
    //     _StatusTabSpec(DplDispatchSlipStatus.pendingQa, 'Pending QA',
    //         totals.pendingQa),
    //     _StatusTabSpec(DplDispatchSlipStatus.pendingPdi, 'Pending PDI',
    //         totals.pendingPdi),
    //     _StatusTabSpec(DplDispatchSlipStatus.approved, 'Approved',
    //         totals.approved),
    //     _StatusTabSpec(DplDispatchSlipStatus.rejected, 'Rejected',
    //         totals.rejected),
    //     const _StatusTabSpec(null, 'All', null),
    //   ];
    // } else if (...
    if (AppConstants.isDplDeoRole(role)) {
      // DEO's queue first — the slips waiting for an invoice — then the
      // stages downstream so they can follow what they've forwarded.
      tabs = [
        _StatusTabSpec(DplDispatchSlipStatus.pendingDeo, 'Pending DEO',
            totals.pendingDeo),
        _StatusTabSpec(DplDispatchSlipStatus.pendingPdi, 'Pending PDI',
            totals.pendingPdi),
        _StatusTabSpec(DplDispatchSlipStatus.approved, 'Approved',
            totals.approved),
        _StatusTabSpec(DplDispatchSlipStatus.dispatched, 'Dispatched',
            totals.dispatched),
        _StatusTabSpec(DplDispatchSlipStatus.rejected, 'Rejected',
            totals.rejected),
        const _StatusTabSpec(null, 'All', null),
      ];
    } else if (AppConstants.isDplPdiRole(role) ||
        AppConstants.isDplQaRole(role)) {
      tabs = [
        _StatusTabSpec(DplDispatchSlipStatus.pendingPdi, 'Pending PDI',
            totals.pendingPdi),
        _StatusTabSpec(DplDispatchSlipStatus.approved, 'Approved',
            totals.approved),
        _StatusTabSpec(DplDispatchSlipStatus.dispatched, 'Dispatched',
            totals.dispatched),
        _StatusTabSpec(DplDispatchSlipStatus.rejected, 'Rejected',
            totals.rejected),
        const _StatusTabSpec(null, 'All', null),
      ];
    } else {
      tabs = [
        const _StatusTabSpec(null, 'All', null),
        // Pending QA chip hidden — QA approval step removed.
        // _StatusTabSpec(DplDispatchSlipStatus.pendingQa, 'Pending QA',
        //     totals.pendingQa),
        _StatusTabSpec(DplDispatchSlipStatus.pendingDeo, 'Pending DEO',
            totals.pendingDeo),
        _StatusTabSpec(DplDispatchSlipStatus.pendingPdi, 'Pending PDI',
            totals.pendingPdi),
        _StatusTabSpec(DplDispatchSlipStatus.approved, 'Approved',
            totals.approved),
        _StatusTabSpec(DplDispatchSlipStatus.dispatched, 'Dispatched',
            totals.dispatched),
        _StatusTabSpec(DplDispatchSlipStatus.rejected, 'Rejected',
            totals.rejected),
      ];
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: [
          for (final t in tabs) ...[
            _StatusChip(
              label: t.label,
              count: t.count,
              selected: filters.status == t.status,
              onTap: () => ref
                  .read(dplDispatchSlipFiltersProvider.notifier)
                  .setStatus(t.status),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

class _StatusTabSpec {
  final String? status;
  final String label;
  final int? count;
  const _StatusTabSpec(this.status, this.label, this.count);
}

class _StatusChip extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  const _StatusChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? DplColors.primary : DplColors.cardBg,
            border: Border.all(
              color: selected ? DplColors.primary : DplColors.divider,
            ),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? DplColors.textInverse
                      : DplColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
              ),
              if (count != null && count! > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? Colors.white.withValues(alpha: 0.22)
                        : DplColors.primaryTint,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      color: selected
                          ? DplColors.textInverse
                          : DplColors.primaryDark,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _SearchBar({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search slip no, machine, part…',
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: onClear,
                ),
          filled: true,
          fillColor: DplColors.cardBg,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: DplColors.divider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: DplColors.divider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: DplColors.primary,
              width: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// Inbox row that rolls every slip cut from one trip into a single
/// card. Header carries the trip number + plant + total qty; the
/// list below shows each slip as a one-line summary so the user can
/// scan the trip's slip stack at a glance. The whole card is
/// tappable — tap → [TripSlipsScreen] with the full per-slip detail
/// + the multi-page "Print all" action.
class _TripGroupCard extends StatelessWidget {
  final _TripGroupRow group;
  const _TripGroupCard({super.key, required this.group});

  Color get _accent =>
      _SlipRowCard._tripPalette[group.tripId.abs() % _SlipRowCard._tripPalette.length];

  Map<String, int> _statusCounts() {
    final out = <String, int>{};
    for (final s in group.slips) {
      out[s.status] = (out[s.status] ?? 0) + 1;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final dateFmt = DateFormat('dd MMM yyyy, HH:mm');
    final statuses = _statusCounts();
    final plantLabel = group.plantName.isNotEmpty
        ? group.plantName
        : group.plantCode;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TripSlipsScreen(
              tripId: group.tripId,
              tripNumber: group.tripNumber,
              plantCode: group.plantCode,
              plantName: group.plantName,
              slips: group.slips,
            ),
          ),
        ),
        child: Ink(
          decoration: BoxDecoration(
            color: DplColors.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: DplColors.divider),
            boxShadow: DplShadows.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header band — matches the trip-driven open-trips card on
              // the dispatch landing so the visual language stays one.
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.10),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(13),
                  ),
                  border: Border(
                    bottom: BorderSide(
                      color: _accent.withValues(alpha: 0.25),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.local_shipping_rounded,
                        size: 18, color: _accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Trip #${group.tripNumber}',
                            style: TextStyle(
                              color: _accent,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              letterSpacing: 0.3,
                            ),
                          ),
                          if (plantLabel.isNotEmpty)
                            Text(
                              plantLabel,
                              style: TextStyle(
                                color: DplColors.textSecondary,
                                fontWeight: FontWeight.w700,
                                fontSize: 11.5,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${group.slips.length} slip'
                          '${group.slips.length == 1 ? "" : "s"}',
                          style: TextStyle(
                            color: DplColors.textPrimary,
                            fontWeight: FontWeight.w800,
                            fontSize: 11.5,
                          ),
                        ),
                        Text(
                          '${fmt.format(group.totalQty)} NOS',
                          style: TextStyle(
                            color: DplColors.textPrimary,
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (statuses.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final entry in statuses.entries)
                        _StatusPip(
                          status: entry.key,
                          count: entry.value,
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              // Mini-roster of slips. Each row is a one-line summary —
              // the full per-slip detail + actions live on
              // [TripSlipsScreen], reachable by tapping anywhere on
              // the card.
              for (var i = 0; i < group.slips.length; i++) ...[
                if (i > 0)
                  Divider(height: 1, color: DplColors.divider),
                _TripGroupSlipRow(slip: group.slips[i], dateFmt: dateFmt),
              ],
              // Post-dispatch actions — only surface Assign Driver /
              // Journey / Consolidated Slip once at least one slip on
              // the trip has been physically dispatched (there is no
              // trip-level 'dispatched' status; the signal lives on
              // slip.status per recon).
              if (group.slips
                  .any((s) => s.status == DplDispatchSlipStatus.dispatched))
                _TripCardActions(
                  tripId: group.tripId,
                  tripNumber: group.tripNumber,
                  plantName: group.plantName,
                  vehicleNo: group.slips.first.vehicleNo,
                  accent: _accent,
                  // Same rule the backend enforces on assignDriver /
                  // gateOut: every non-rejected slip must be dispatched.
                  readiness: TripDispatchReadiness.of(group.slips),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Row(
                  children: [
                    Icon(Icons.touch_app_outlined,
                        size: 13, color: _accent),
                    const SizedBox(width: 4),
                    Text(
                      'View all & print',
                      style: TextStyle(
                        color: _accent,
                        fontWeight: FontWeight.w800,
                        fontSize: 11.5,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const Spacer(),
                    Icon(Icons.chevron_right_rounded,
                        size: 16, color: _accent),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One-line summary of a slip inside a [_TripGroupCard]. Tappable so
/// the user can jump straight into the existing detail screen for
/// quick approve / reject / print on a single slip.
class _TripGroupSlipRow extends StatelessWidget {
  final DplDispatchSlip slip;
  final DateFormat dateFmt;
  const _TripGroupSlipRow({required this.slip, required this.dateFmt});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DispatchSlipDetailScreen(slipId: slip.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      slip.slipNo,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5,
                        letterSpacing: 0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      slip.isSingleItem
                          ? '${slip.machineLabel} • Qty ${fmt.format(slip.qty)}'
                          : '${slip.machineLabel} • '
                              '${slip.items.length} items • '
                              '${fmt.format(slip.totalQty)} NOS',
                      style: TextStyle(
                        color: DplColors.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 11.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              DispatchSlipStatusBadge(status: slip.status, dense: true),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPip extends StatelessWidget {
  final String status;
  final int count;
  const _StatusPip({required this.status, required this.count});

  @override
  Widget build(BuildContext context) {
    final palette = _pipPalette(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count ${DplDispatchSlipStatus.label(status)}',
        style: TextStyle(
          color: palette.fg,
          fontWeight: FontWeight.w800,
          fontSize: 10.5,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  static ({Color bg, Color fg}) _pipPalette(String s) {
    switch (s) {
      case DplDispatchSlipStatus.pendingQa:
      case DplDispatchSlipStatus.pendingDeo:
      case DplDispatchSlipStatus.pendingPdi:
        return (bg: DplColors.warningBg, fg: DplColors.warning);
      case DplDispatchSlipStatus.approved:
        return (bg: DplColors.primaryTint, fg: DplColors.primaryDark);
      case DplDispatchSlipStatus.dispatched:
        return (bg: DplColors.successBg, fg: DplColors.success);
      case DplDispatchSlipStatus.rejected:
        return (bg: DplColors.errorBg, fg: DplColors.error);
      default:
        return (bg: DplColors.neutralBg, fg: DplColors.textSecondary);
    }
  }
}

class _SlipRowCard extends StatelessWidget {
  final DplDispatchSlip slip;
  const _SlipRowCard({super.key, required this.slip});

  /// Stable color picked from [_tripPalette] so every slip cut from
  /// the same trip carries the same accent. Hashing the trip id keeps
  /// the mapping deterministic across sessions — Trip 47 is always
  /// the same color today and tomorrow. Legacy slips (no trip_id)
  /// return null and skip the accent strip entirely.
  static Color? _tripAccent(int? tripId) {
    if (tripId == null) return null;
    return _tripPalette[tripId.abs() % _tripPalette.length];
  }

  /// Curated palette — distinct hues that don't collide with the
  /// status badges (which already use red/amber/green). 8 entries is
  /// enough variety; if the same plant cuts more than 8 trips in a
  /// shift, two of them will share a color, which we accept as a
  /// tradeoff for keeping the legend mentally short.
  static const List<Color> _tripPalette = [
    Color(0xFF3F51B5), // indigo
    Color(0xFF009688), // teal
    Color(0xFF00ACC1), // cyan
    Color(0xFFE91E63), // pink
    Color(0xFF795548), // brown
    Color(0xFF607D8B), // blue grey
    Color(0xFFFF7043), // deep orange
    Color(0xFF673AB7), // deep purple
  ];

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final dateFmt = DateFormat('dd MMM yyyy, HH:mm');
    final tripAccent = _tripAccent(slip.tripId);

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
          decoration: BoxDecoration(
            color: DplColors.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: DplColors.divider),
            boxShadow: DplShadows.card,
          ),
          child: Stack(
            children: [
              // Main card content. The left padding is bumped up when
              // a trip accent is present so the colored strip never
              // overlaps the text.
              Padding(
                padding: EdgeInsets.fromLTRB(
                  tripAccent == null ? 14 : 18,
                  14,
                  14,
                  14,
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
                              fontSize: 15,
                              letterSpacing: 0.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (slip.tripNumber != null) ...[
                          const SizedBox(width: 6),
                          _TripPill(
                            tripNumber: slip.tripNumber!,
                            color: tripAccent ?? DplColors.textSecondary,
                          ),
                        ],
                        const SizedBox(width: 6),
                        DispatchSlipStatusBadge(status: slip.status),
                      ],
                    ),
              const SizedBox(height: 6),
              // Multi-item slips compress to "Machine · N items · X NOS"
              // so the tile stays one-line scannable. Single-item slips
              // keep the original "Machine · Qty X" + part label below.
              Text(
                slip.isSingleItem
                    ? '${slip.machineLabel} • Qty ${fmt.format(slip.qty)}'
                    : '${slip.machineLabel} • ${slip.items.length} items '
                        '• ${fmt.format(slip.totalQty)} NOS',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                slip.partLabel,
                style: TextStyle(
                  color: DplColors.textSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              // Customer P/N is only meaningful on single-item slips.
              // Multi-item slips render multiple P/Ns in the items
              // list — surfacing just the first one here would be
              // misleading, so hide.
              if (slip.isSingleItem && slip.customerPartNo.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  slip.customerPartNo,
                  style: TextStyle(
                    color: DplColors.textTertiary,
                    fontWeight: FontWeight.w600,
                    fontSize: 11.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 8),
              Row(
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
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (slip.requestedAt != null)
                    Text(
                      dateFmt.format(slip.requestedAt!.toLocal()),
                      style: TextStyle(
                        color: DplColors.textSecondary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
                  ],
                ),
              ),
              // Vertical color strip pinned to the left edge of the
              // card. Same trip → same color, derived from the trip
              // id hash. Skipped for legacy slips so they read as
              // visually distinct from trip-driven ones.
              if (tripAccent != null)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 5,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: tripAccent,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(13),
                        bottomLeft: Radius.circular(13),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact pill showing the source trip number, painted in the same
/// color as the card's left accent strip so the grouping signal is
/// reinforced inline next to the slip number.
class _TripPill extends StatelessWidget {
  final int tripNumber;
  final Color color;
  const _TripPill({required this.tripNumber, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_shipping_rounded, size: 11, color: color),
          const SizedBox(width: 3),
          Text(
            'Trip #$tripNumber',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 10.5,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _Pagination extends StatelessWidget {
  final DplDispatchSlipPage page;
  final ValueChanged<int> onChange;
  const _Pagination({required this.page, required this.onChange});

  @override
  Widget build(BuildContext context) {
    if (page.totalPages <= 1) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'Showing ${page.items.length} of ${page.total}',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: DplColors.textSecondary,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed:
                page.page > 1 ? () => onChange(page.page - 1) : null,
            icon: const Icon(Icons.chevron_left_rounded),
            label: const Text('Prev'),
          ),
          const SizedBox(width: 12),
          Text(
            'Page ${page.page} of ${page.totalPages}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: page.hasMore ? () => onChange(page.page + 1) : null,
            icon: const Icon(Icons.chevron_right_rounded),
            label: const Text('Next'),
          ),
        ],
      ),
    );
  }
}

/// Bottom action strip on a `_TripGroupCard` once at least one slip is
/// dispatched — Assign Driver + Journey + Consolidated Slip pills.
///
/// Stateful because it lazy-fetches the trip's `driver_name` (the slip
/// group only carries slip-scope fields; `driverName` lives on the
/// trip object). Refetches when the picker returns "assigned" so the
/// button label flips from "Assign Driver" to the chosen driver's name
/// without a full inbox reload.
class _TripCardActions extends ConsumerStatefulWidget {
  final int tripId;
  final int tripNumber;
  final String plantName;
  final String? vehicleNo;
  final Color accent;
  final TripDispatchReadiness readiness;

  const _TripCardActions({
    required this.tripId,
    required this.tripNumber,
    required this.plantName,
    required this.vehicleNo,
    required this.accent,
    required this.readiness,
  });

  @override
  ConsumerState<_TripCardActions> createState() => _TripCardActionsState();
}

class _TripCardActionsState extends ConsumerState<_TripCardActions> {
  String? _driverName;
  bool _hasLeftPlant = false;

  @override
  void initState() {
    super.initState();
    _refreshDriverInfo();
  }

  /// The inbox list can hand this State a different trip without ever
  /// disposing it — Flutter reuses Elements by position, and the driver
  /// chip is fetched once in [initState]. The keys on the cards make that
  /// reuse identity-correct, but this covers the case regardless: if the
  /// trip under us changes, drop the stale driver and refetch.
  @override
  void didUpdateWidget(covariant _TripCardActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tripId != widget.tripId) {
      setState(() {
        _driverName = null;
        _hasLeftPlant = false;
      });
      _refreshDriverInfo();
    }
  }

  Future<void> _refreshDriverInfo() async {
    // Capture the trip this request is for. Two fetches can be in flight
    // after a rapid rebuild, and the slower one must not overwrite the
    // newer trip's driver with the older trip's answer.
    final requestedTripId = widget.tripId;
    final info = await fetchTripDriverInfo(ref, requestedTripId);
    if (!mounted || requestedTripId != widget.tripId) return;
    setState(() {
      _driverName = info.driverName;
      _hasLeftPlant = info.hasLeftPlant;
    });
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Wrap(
        spacing: 4,
        runSpacing: 2,
        children: [
          AssignDriverButton(
            tripId: widget.tripId,
            currentDriverName: _driverName,
            accent: accent,
            locked: _hasLeftPlant,
            readiness: widget.readiness,
            onAssigned: _refreshDriverInfo,
          ),
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: accent,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
            icon: const Icon(Icons.route_rounded, size: 16),
            label: const Text('Journey'),
            onPressed: () => showTripJourneyDrawer(
              context,
              tripId: widget.tripId,
              tripNumber: widget.tripNumber,
              plantName: widget.plantName,
              vehicleNo: widget.vehicleNo,
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: accent,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
            icon: const Icon(Icons.qr_code_2_rounded, size: 16),
            label: const Text('Slip'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ConsolidatedSlipScreen(tripId: widget.tripId),
              ),
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: accent,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
            icon: const Icon(Icons.location_on_rounded, size: 16),
            label: const Text('Track Location'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => TripTrackMapScreen(
                  tripId: widget.tripId,
                  tripNumber: widget.tripNumber,
                  plantName: widget.plantName,
                  vehicleNo: widget.vehicleNo,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
