import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/vistar_palette.dart';
import '../../../../core/widgets/shimmer_skeleton.dart';
import '../../../auth/auth_provider.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_constants.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../manager/providers/dpl_masters_provider.dart';
import '../../manager/widgets/empty_state.dart';
import '../../manager/widgets/error_retry.dart';
import '../../models/dpl_plant.dart';
import '../../models/dpl_production_summary.dart';
import '../providers/dispatch_slips_provider.dart';
import '../providers/production_summary_provider.dart';
import '../providers/summary_tab_provider.dart';
import '../widgets/request_dispatch_slip_sheet.dart';
import 'bucket_detail_screen.dart';

/// Production Summary screen — shows the aggregate "total actual qty
/// produced till date" for every (machine, part) bucket in the active
/// organization, with search / filters / sort and a totals row.
///
/// Used by:
///   * `DplDispatchShell` (role `DPL_DISPATCH`)
///   * `DplQaShell` (role `DPL_QA`)
///   * `DplPdiShell` (role `DPL_PDI`)
/// The shells only differ in the AppBar title so each role lands on a
/// screen that "looks like theirs"; the data + actions are identical.
class ProductionSummaryScreen extends ConsumerStatefulWidget {
  /// AppBar title — varies by role (e.g. "Dispatch — Production Summary").
  final String title;
  final bool showAppBar;

  /// Optional plant context — when set, the screen renders a plant
  /// header strip at the top and (once backend PR 2 lands) the
  /// production-summary provider will filter results to this plant's
  /// machines. Until PR 2 ships, all buckets show through but the
  /// plant header still indicates which lens the user is in.
  final DplPlant? plant;

  const ProductionSummaryScreen({
    super.key,
    this.title = 'Production Summary',
    this.showAppBar = true,
    this.plant,
  });

  @override
  ConsumerState<ProductionSummaryScreen> createState() =>
      _ProductionSummaryScreenState();
}

class _ProductionSummaryScreenState
    extends ConsumerState<ProductionSummaryScreen> {
  late final TextEditingController _searchCtrl;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final initialQuery =
        ref.read(dplProductionSummaryFiltersProvider).query;
    _searchCtrl = TextEditingController(text: initialQuery);

    // Sync the route's plant context into the global filter so the
    // backend's `?plant_code=` query param matches what we're showing.
    // Notifier mutations have to be deferred a microtask so we don't
    // touch provider state mid-build.
    Future.microtask(() {
      if (!mounted) return;
      ref
          .read(dplProductionSummaryFiltersProvider.notifier)
          .setPlantCode(widget.plant?.code);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    // Clear plant scope on the way out so a subsequent non-plant
    // entry point doesn't inherit a stale "?plant_code=NEXON_EV" from
    // the route we're leaving.
    if (widget.plant != null) {
      Future.microtask(() {
        try {
          ref
              .read(dplProductionSummaryFiltersProvider.notifier)
              .setPlantCode(null);
        } catch (_) {
          // Provider may already be disposed if the whole shell
          // unmounted. Safe to ignore.
        }
      });
    }
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      ref.read(dplProductionSummaryFiltersProvider.notifier).setQuery(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final filters = ref.watch(dplProductionSummaryFiltersProvider);
    final pageAsync = ref.watch(dplProductionSummaryProvider);

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.plant != null) _PlantHeaderStrip(plant: widget.plant!),
        _SearchBar(
          controller: _searchCtrl,
          onChanged: _onSearchChanged,
          onClear: () {
            _searchCtrl.clear();
            ref
                .read(dplProductionSummaryFiltersProvider.notifier)
                .setQuery('');
          },
        ),
        _ActiveFilterChips(filters: filters),
        const ProductionTotalsBanner(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(dplProductionSummaryProvider);
              try {
                await ref.read(dplProductionSummaryProvider.future);
              } catch (_) {}
            },
            child: pageAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: SkeletonList(count: 6),
              ),
              error: (e, _) => ListView(
                children: [
                  DplErrorRetry(
                    message: e.toString(),
                    onRetry: () =>
                        ref.invalidate(dplProductionSummaryProvider),
                  ),
                ],
              ),
              data: (res) {
                if (res.isError) {
                  return ListView(
                    children: [
                      DplErrorRetry(
                        message: res.error ??
                            'Failed to load production summary.',
                        onRetry: () =>
                            ref.invalidate(dplProductionSummaryProvider),
                      ),
                    ],
                  );
                }
                final page = res.data ?? DplProductionSummaryPage.empty();
                if (page.items.isEmpty) {
                  return ListView(
                    children: const [
                      SizedBox(height: 60),
                      DplEmptyState(
                        icon: Icons.inbox_outlined,
                        title: 'No production yet',
                        message:
                            'No (machine, part) buckets match the current filters.',
                      ),
                    ],
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: page.items.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    if (i == page.items.length) {
                      return _Pagination(
                        page: page,
                        onChange: (p) => ref
                            .read(dplProductionSummaryFiltersProvider
                                .notifier)
                            .setPage(p),
                      );
                    }
                    return SummaryBucketCard(item: page.items[i]);
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
      appBar: DplAppBar(
        title: widget.plant != null
            ? '${widget.plant!.name} — Production'
            : widget.title,
        actions: [
          IconButton(
            tooltip: 'Sort',
            icon: const Icon(Icons.swap_vert_rounded),
            onPressed: () => _openSortSheet(context, ref),
          ),
          IconButton(
            tooltip: 'Filter',
            icon: const Icon(Icons.filter_alt_outlined),
            onPressed: () => _openFilterSheet(context, ref),
          ),
        ],
      ),
      body: body,
    );
  }

  Future<void> _openFilterSheet(BuildContext context, WidgetRef ref) async {
    final current = ref.read(dplProductionSummaryFiltersProvider);
    final machinesAsync = ref.read(dplMachinesProvider);

    int? machineId = current.machineId;
    DateTime? from = current.from;
    DateTime? to = current.to;
    bool onlyProduced = current.onlyProduced;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(builder: (ctx, setSheet) {
          Future<void> pickDate(bool isFrom) async {
            final picked = await showDatePicker(
              context: ctx,
              initialDate: (isFrom ? from : to) ?? DateTime.now(),
              firstDate: DateTime(2020),
              lastDate: DateTime(2100),
            );
            if (picked != null) {
              setSheet(() {
                if (isFrom) {
                  from = picked;
                } else {
                  to = picked;
                }
              });
            }
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              16 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Filter', style: DplText.h2()),
                const SizedBox(height: 16),
                machinesAsync.when(
                  loading: () => const SizedBox(
                    height: 56,
                    child: Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (res) {
                    if (res.isError) return const SizedBox.shrink();
                    final items = res.data ?? const [];
                    return DropdownButtonFormField<int?>(
                      initialValue: machineId,
                      decoration:
                          const InputDecoration(labelText: 'Machine'),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('All machines'),
                        ),
                        ...items.map(
                          (m) => DropdownMenuItem<int?>(
                            value: m.id,
                            child: Text(m.name),
                          ),
                        ),
                      ],
                      onChanged: (v) => setSheet(() => machineId = v),
                    );
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => pickDate(true),
                        icon: const Icon(Icons.date_range_outlined),
                        label: Text(
                          from == null
                              ? 'From'
                              : DateFormat('dd MMM yyyy').format(from!),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => pickDate(false),
                        icon: const Icon(Icons.event_outlined),
                        label: Text(
                          to == null
                              ? 'To'
                              : DateFormat('dd MMM yyyy').format(to!),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Hide buckets with 0 actual qty',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  value: onlyProduced,
                  onChanged: (v) => setSheet(() => onlyProduced = v),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          ref
                              .read(dplProductionSummaryFiltersProvider
                                  .notifier)
                              .clear();
                          Navigator.of(ctx).pop();
                        },
                        child: const Text('Clear'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          ref
                              .read(dplProductionSummaryFiltersProvider
                                  .notifier)
                              .update(current.copyWith(
                                machineId: machineId,
                                from: from,
                                to: to,
                                onlyProduced: onlyProduced,
                                page: 1,
                              ));
                          Navigator.of(ctx).pop();
                        },
                        child: const Text('Apply'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        });
      },
    );
  }

  Future<void> _openSortSheet(BuildContext context, WidgetRef ref) async {
    final current = ref.read(dplProductionSummaryFiltersProvider);
    const sortOptions = <_SortOption>[
      _SortOption('last_produced_at', 'Last produced'),
      _SortOption('first_produced_at', 'First produced'),
      _SortOption('total_actual_qty', 'Total actual qty'),
      _SortOption('total_plan_qty', 'Total plan qty'),
      _SortOption('machine_name', 'Machine name'),
      _SortOption('part_name', 'Part name'),
      _SortOption('updated_at', 'Updated at'),
    ];

    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: Row(
                    children: [
                      Text('Sort by', style: DplText.h3()),
                      const Spacer(),
                      _OrderToggle(
                        order: current.order,
                        onChanged: (v) {
                          ref
                              .read(dplProductionSummaryFiltersProvider
                                  .notifier)
                              .setSort(current.sort, v);
                        },
                      ),
                    ],
                  ),
                ),
                for (final opt in sortOptions)
                  ListTile(
                    dense: true,
                    title: Text(
                      opt.label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    trailing: Icon(
                      current.sort == opt.value
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: current.sort == opt.value
                          ? DplColors.primary
                          : DplColors.textTertiary,
                    ),
                    onTap: () {
                      ref
                          .read(dplProductionSummaryFiltersProvider
                              .notifier)
                          .setSort(opt.value, current.order);
                      Navigator.of(ctx).pop();
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SortOption {
  final String value;
  final String label;
  const _SortOption(this.value, this.label);
}

class _OrderToggle extends StatelessWidget {
  final String order;
  final ValueChanged<String> onChanged;
  const _OrderToggle({required this.order, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(value: 'desc', label: Text('Desc')),
        ButtonSegment(value: 'asc', label: Text('Asc')),
      ],
      selected: {order == 'asc' ? 'asc' : 'desc'},
      onSelectionChanged: (s) => onChanged(s.first),
      showSelectedIcon: false,
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText:
              'Search machine, part, description, material code…',
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

class _ActiveFilterChips extends ConsumerWidget {
  final DplProductionSummaryFilters filters;
  const _ActiveFilterChips({required this.filters});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chips = <Widget>[];
    final df = DateFormat('dd MMM');

    if (filters.machineId != null) {
      chips.add(InputChip(
        label: Text('Machine #${filters.machineId}'),
        onDeleted: () => ref
            .read(dplProductionSummaryFiltersProvider.notifier)
            .setMachineId(null),
      ));
    }
    if (filters.from != null || filters.to != null) {
      final label = (filters.from != null && filters.to != null)
          ? '${df.format(filters.from!)} – ${df.format(filters.to!)}'
          : filters.from != null
              ? 'From ${df.format(filters.from!)}'
              : 'Until ${df.format(filters.to!)}';
      chips.add(InputChip(
        label: Text(label),
        onDeleted: () => ref
            .read(dplProductionSummaryFiltersProvider.notifier)
            .setDateRange(from: null, to: null),
      ));
    }
    if (filters.onlyProduced) {
      chips.add(InputChip(
        label: const Text('Only produced'),
        onDeleted: () => ref
            .read(dplProductionSummaryFiltersProvider.notifier)
            .setOnlyProduced(false),
      ));
    }

    if (chips.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: chips,
      ),
    );
  }
}

/// Slim header strip shown at the top of the screen when the user
/// entered via the plant landing — gives them an unambiguous "you're
/// looking at plant X" signal that survives every scroll. Stays out of
/// the way (small, single-line) so the search bar + totals banner are
/// still the dominant surfaces.
class _PlantHeaderStrip extends StatelessWidget {
  final DplPlant plant;
  const _PlantHeaderStrip({required this.plant});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: DplColors.primaryTint,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: DplColors.primary.withValues(alpha: 0.18),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.factory_outlined,
              size: 16,
              color: DplColors.primaryDark,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                plant.name,
                style: TextStyle(
                  color: DplColors.primaryDark,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  letterSpacing: 0.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: DplColors.cardBg.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: DplColors.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Text(
                plant.code,
                style: TextStyle(
                  color: DplColors.primaryDark,
                  fontWeight: FontWeight.w800,
                  fontSize: 10.5,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two stacked banners summarising both the production-summary totals
/// and the dispatch-slip pipeline totals.
///
///   Row 1 — Production:  Actual / Plan / Buckets / Remaining
///   Row 2 — Pipeline:    In pipeline / Dispatched / Rejected
///
/// Production data comes from `dplProductionSummaryProvider`. Pipeline
/// data comes from `dplDispatchSlipsProvider` — the same provider the
/// Slips inbox tab already watches, so this also pre-warms its cache.
/// Both totals blocks are scoped server-side so the banner numbers
/// stay stable as the user filters / paginates either screen.
class ProductionTotalsBanner extends ConsumerWidget {
  const ProductionTotalsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fmt = NumberFormat.decimalPattern();

    // Production stats (from production summary).
    final productionAsync = ref.watch(dplProductionSummaryProvider);
    int actual = 0;
    int plan = 0;
    int buckets = 0;
    int remaining = 0;
    final pData = productionAsync.asData?.value.data;
    if (pData != null) {
      actual = pData.totals.totalActualQty;
      plan = pData.totals.totalPlanQty;
      buckets = pData.totals.bucketCount > 0
          ? pData.totals.bucketCount
          : pData.total;
      remaining = pData.totals.totalAvailableForDispatchQty;
    }

    // Pipeline stats (from dispatch slip list totals).
    final slipsAsync = ref.watch(dplDispatchSlipsProvider);
    int inPipeline = 0;
    int dispatched = 0;
    int rejected = 0;
    final sData = slipsAsync.asData?.value.data;
    if (sData != null) {
      inPipeline = sData.totals.inPipelineQty;
      dispatched = sData.totals.dispatchedQty;
      rejected = sData.totals.rejectedQty;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BannerSurface(
            cells: [
              _Cell(
                label: 'Actual (till date)',
                value: fmt.format(actual),
                emphasised: true,
              ),
              _Cell(label: 'Plan', value: fmt.format(plan)),
              _Cell(label: 'Buckets', value: fmt.format(buckets)),
              _Cell(
                label: 'Remaining',
                value: fmt.format(remaining),
                accent: DplColors.primaryDark,
              ),
            ],
          ),
          const SizedBox(height: 8),
          _BannerSurface(
            cells: [
              _Cell(
                label: 'In pipeline',
                value: fmt.format(inPipeline),
                accent: DplColors.warning,
              ),
              _Cell(
                label: 'Dispatched',
                value: fmt.format(dispatched),
                accent: DplColors.success,
              ),
              _Cell(
                label: 'Rejected',
                value: fmt.format(rejected),
                accent: DplColors.error,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shared gradient surface for each banner row. Cells are equally
/// spaced with hairline dividers between them so the row reads as one
/// continuous summary card.
class _BannerSurface extends StatelessWidget {
  final List<_Cell> cells;
  const _BannerSurface({required this.cells});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < cells.length; i++) {
      children.add(Expanded(child: cells[i]));
      if (i != cells.length - 1) {
        children.add(
          Container(
            width: 1,
            height: 28,
            color: VistarPalette.primaryLine,
          ),
        );
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            DplColors.primaryTint,
            Color.lerp(DplColors.primaryTint, DplColors.primary, 0.08)!,
          ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VistarPalette.primaryLine, width: 1.2),
      ),
      child: Row(children: children),
    );
  }
}

class _Cell extends StatelessWidget {
  final String label;
  final String value;
  final Color? accent;
  final bool emphasised;
  const _Cell({
    required this.label,
    required this.value,
    this.accent,
    this.emphasised = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = accent ?? DplColors.textPrimary;
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: emphasised ? DplColors.primaryDark : color,
            fontWeight: FontWeight.w800,
            fontSize: emphasised ? 18 : 16,
            height: 1.1,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: DplColors.textSecondary,
            fontWeight: FontWeight.w600,
            fontSize: 10.5,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Public bucket card used by the Production Summary screen AND the
/// Plant Landing screen (so the dashboard shows plant cards + bucket
/// cards stacked, restoring the at-a-glance production data the user
/// expects to see on the dashboard).
class SummaryBucketCard extends ConsumerWidget {
  final DplProductionSummary item;
  const SummaryBucketCard({super.key, required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fmt = NumberFormat.decimalPattern();
    final dateFmt = DateFormat('dd MMM yyyy, HH:mm');
    final pct = (item.completionRatio * 100).clamp(0, 100);
    final pctText = '${pct.toStringAsFixed(0)}%';

    final role = ref.watch(authControllerProvider).asData?.value?.role ?? '';
    final isDispatch = AppConstants.isDplDispatchRole(role);
    // Read-only pipeline chips are useful oversight for a manager too;
    // the "Request" write action (Available banner) is dispatch-only.
    final canViewPipeline =
        isDispatch || AppConstants.isDplManagerRole(role);
    final canRequestSlip = isDispatch;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BucketDetailScreen(bucket: item),
          ),
        ),
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          decoration: BoxDecoration(
            color: DplColors.cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: DplColors.divider, width: 1.2),
            boxShadow: DplShadows.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          // Header row — machine + completion pill
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: DplColors.primaryTint,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: DplColors.primary.withValues(alpha: 0.15),
                  ),
                ),
                child: Icon(
                  Icons.precision_manufacturing_outlined,
                  size: 18,
                  color: DplColors.primaryDark,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.machineLabel,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (item.machineCode.isNotEmpty &&
                        item.machineCode != item.machineLabel)
                      Text(
                        'Code: ${item.machineCode}',
                        style: TextStyle(
                          color: DplColors.textSecondary,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              _Pill(text: pctText),
            ],
          ),
          const SizedBox(height: 10),
          Divider(height: 1, color: DplColors.divider),
          const SizedBox(height: 10),

          // Part block
          Text(
            item.partLabel,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13.5,
              height: 1.25,
            ),
          ),
          if (item.customerPartNo.isNotEmpty) ...[
            const SizedBox(height: 3),
            _KvRow(label: 'Customer P/N', value: item.customerPartNo),
          ],
          if (item.substratePartNo.isNotEmpty)
            _KvRow(label: 'Substrate P/N', value: item.substratePartNo),
          if (item.materialCode.isNotEmpty)
            _KvRow(label: 'Material code', value: item.materialCode),
          if (item.description.isNotEmpty &&
              item.description != item.partName) ...[
            const SizedBox(height: 4),
            Text(
              item.description,
              style: TextStyle(
                color: DplColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],

          const SizedBox(height: 12),

          // Quantity row — actual / plan / counters
          Row(
            children: [
              Expanded(
                child: _QtyTile(
                  label: 'Actual',
                  value: fmt.format(item.totalActualQty),
                  emphasised: true,
                ),
              ),
              Expanded(
                child: _QtyTile(
                  label: 'Plan',
                  value: fmt.format(item.totalPlanQty),
                ),
              ),
              Expanded(
                child: _QtyTile(
                  label: 'Done',
                  value: '${item.completedItems}',
                ),
              ),
              Expanded(
                child: _QtyTile(
                  label: 'In-prog',
                  value: '${item.inProgressItems}',
                ),
              ),
              Expanded(
                child: _QtyTile(
                  label: 'Pending',
                  value: '${item.pendingItems}',
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // Timestamps row
          Row(
            children: [
              Icon(
                Icons.update_rounded,
                size: 13,
                color: DplColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  item.lastProducedAt == null
                      ? 'Never produced'
                      : 'Last produced: ${dateFmt.format(item.lastProducedAt!.toLocal())}',
                  style: TextStyle(
                    color: DplColors.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (item.firstProducedAt != null) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(
                  Icons.flag_outlined,
                  size: 13,
                  color: DplColors.textSecondary,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'First produced: ${dateFmt.format(item.firstProducedAt!.toLocal())}',
                    style: TextStyle(
                      color: DplColors.textSecondary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],

          // Dispatch pipeline + CTA — visible only to Dispatch (and
          // Manager). Pulls live per-bucket counts so the user sees how
          // many of their slips for this exact (machine, part) are
          // already queued at QA, PDI, ready to ship, or shipped — same
          // colour palette as the QA / PDI inbox status badges.
          // Pipeline chips (read-only oversight) — dispatch actors AND
          // managers. The Available banner carries the "Request" write
          // action, so it stays dispatch-only (managers are view-only).
          if (canViewPipeline) ...[
            const SizedBox(height: 12),
            _DispatchPipelineRow(item: item),
          ],
          if (canRequestSlip) ...[
            const SizedBox(height: 10),
            _AvailableBanner(item: item),
          ],
        ],
      ),
        ),
      ),
    );
  }
}

class _KvRow extends StatelessWidget {
  final String label;
  final String value;
  const _KvRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                color: DplColors.textSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: DplColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _QtyTile extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasised;
  const _QtyTile({
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
            color: emphasised
                ? DplColors.primaryDark
                : DplColors.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: emphasised ? 15.5 : 13.5,
            height: 1.1,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: DplColors.textSecondary,
            fontWeight: FontWeight.w600,
            fontSize: 10.5,
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  const _Pill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: DplColors.successBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: DplColors.success.withValues(alpha: 0.25),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: DplColors.success,
          fontWeight: FontWeight.w800,
          fontSize: 11.5,
        ),
      ),
    );
  }
}

class _Pagination extends StatelessWidget {
  final DplProductionSummaryPage page;
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

/// Prominent "Available for dispatch" banner — replaces the small pill
/// the card had before. Renders the qty in the same bold tabular style
/// the totals banner up top uses, with the Request Dispatch Slip CTA
/// sitting flush on the right. Disabled when nothing's available so the
/// user can't tap into a dead-end form.
class _AvailableBanner extends StatelessWidget {
  final DplProductionSummary item;
  const _AvailableBanner({required this.item});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final qty = item.availableForDispatchQty;
    final hasQty = qty > 0;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            DplColors.primaryTint,
            Color.lerp(DplColors.primaryTint, DplColors.primary, 0.08)!,
          ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VistarPalette.primaryLine),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: DplColors.cardBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: VistarPalette.primaryLine),
            ),
            child: Icon(
              Icons.local_shipping_outlined,
              size: 20,
              color: DplColors.primaryDark,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
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
                const SizedBox(height: 1),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      fmt.format(qty),
                      style: TextStyle(
                        color: DplColors.primaryDark,
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
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
                        'of ${fmt.format(item.totalActualQty)} actual',
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
                      bucket: item,
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
                horizontal: 14,
                vertical: 10,
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

/// Horizontal strip of per-bucket pipeline status chips. Same colour
/// palette as the QA / PDI inbox status badges so a Dispatch user
/// instantly recognises "this bucket has 3 slips waiting at QA". Tapping
/// a chip jumps to the Slips tab with the matching status filter.
///
/// Watches [dplBucketSlipCountsProvider] which fetches the user's
/// recent slips and groups them by `(machine, part)`. While loading or
/// for buckets with zero slips, the row is hidden entirely so the card
/// height stays compact.
class _DispatchPipelineRow extends ConsumerWidget {
  final DplProductionSummary item;
  const _DispatchPipelineRow({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dplBucketSlipCountsProvider);
    final counts = async.asData?.value[dplBucketKey(item.machineId, item.partId)];

    if (counts == null || !counts.hasAny) return const SizedBox.shrink();

    void jumpToSlipsTab(String status) {
      // Drop into the Slips tab with this status pre-selected so the
      // user lands on exactly the queue they tapped from. The list
      // doesn't currently filter by machine/part on this entry-point
      // (no shared sticky filter); status alone gives them the right
      // bucket of their own slips since the backend role-scopes the
      // result set to "their" slips for the Dispatch role.
      ref.read(dplSummaryTabProvider.notifier).set(1);
      ref.read(dplDispatchSlipFiltersProvider.notifier).setStatus(status);
    }

    return SizedBox(
      height: 30,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        physics: const BouncingScrollPhysics(),
        children: [
          if (counts.pendingQa.hasAny)
            _PipelineChip(
              label: 'Pending QA',
              entry: counts.pendingQa,
              fg: DplColors.warning,
              bg: DplColors.warningBg,
              onTap: () => jumpToSlipsTab(DplDispatchSlipStatus.pendingQa),
            ),
          if (counts.pendingDeo.hasAny)
            _PipelineChip(
              label: 'Pending DEO',
              entry: counts.pendingDeo,
              fg: DplColors.warning,
              bg: DplColors.warningBg,
              onTap: () => jumpToSlipsTab(DplDispatchSlipStatus.pendingDeo),
            ),
          if (counts.pendingPdi.hasAny)
            _PipelineChip(
              label: 'Pending PDI',
              entry: counts.pendingPdi,
              fg: DplColors.warning,
              bg: DplColors.warningBg,
              onTap: () => jumpToSlipsTab(DplDispatchSlipStatus.pendingPdi),
            ),
          if (counts.approved.hasAny)
            _PipelineChip(
              label: 'Approved',
              entry: counts.approved,
              fg: DplColors.info,
              bg: DplColors.infoBg,
              onTap: () => jumpToSlipsTab(DplDispatchSlipStatus.approved),
            ),
          if (counts.dispatched.hasAny)
            _PipelineChip(
              label: 'Dispatched',
              entry: counts.dispatched,
              fg: DplColors.success,
              bg: DplColors.successBg,
              onTap: () => jumpToSlipsTab(DplDispatchSlipStatus.dispatched),
            ),
          if (counts.rejected.hasAny)
            _PipelineChip(
              label: 'Rejected',
              entry: counts.rejected,
              fg: DplColors.error,
              bg: DplColors.errorBg,
              onTap: () => jumpToSlipsTab(DplDispatchSlipStatus.rejected),
            ),
        ],
      ),
    );
  }
}

/// One pill in the per-bucket pipeline strip. Shows two facts:
///   * `count` — how many of the user's slips for this (machine, part)
///     are in this status (lives in the small filled circle, primary
///     visual signal).
///   * `qty` — the rolled-up NOS across those slips, rendered as a
///     subtle secondary suffix ("Dispatched · 152 NOS") so the user
///     can see at a glance how much production is "tied up" in that
///     part of the pipeline without opening the Slips tab.
class _PipelineChip extends StatelessWidget {
  final String label;
  final DplStatusSlipQty entry;
  final Color fg;
  final Color bg;
  final VoidCallback onTap;

  const _PipelineChip({
    required this.label,
    required this.entry,
    required this.fg,
    required this.bg,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 18,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: fg,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${entry.count}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 10.5,
                      height: 1.0,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w800,
                    fontSize: 11.5,
                  ),
                ),
                if (entry.qty > 0) ...[
                  const SizedBox(width: 5),
                  Container(
                    width: 3,
                    height: 3,
                    decoration: BoxDecoration(
                      color: fg.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '${fmt.format(entry.qty)} NOS',
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.85),
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
