import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../models/dpl_plant.dart';
import '../../summary/providers/plants_provider.dart';

/// Immutable filter state for any part-list screen (master edits +
/// computed dispatch view).
///
/// Three independent dimensions:
///   * [query] — free-text match against customer PN / description /
///     part name / machine name. Case-insensitive substring.
///   * [plantCode] — pinned to one of the backend's hardcoded plants.
///     A row matches when its `machineName` is one of that plant's
///     machine names (see [matchesPlant]).
///   * [machineName] — pinned to a single machine name. Substring,
///     case-insensitive (so "6AB" matches "6AB Line 2" if backend
///     decides to elaborate later).
@immutable
class DplPartFilter {
  final String query;
  final String? plantCode;
  final String? machineName;

  const DplPartFilter({
    this.query = '',
    this.plantCode,
    this.machineName,
  });

  bool get isEmpty =>
      query.trim().isEmpty && plantCode == null && machineName == null;

  DplPartFilter copyWith({
    String? query,
    Object? plantCode = _sentinel,
    Object? machineName = _sentinel,
  }) {
    return DplPartFilter(
      query: query ?? this.query,
      plantCode: identical(plantCode, _sentinel)
          ? this.plantCode
          : plantCode as String?,
      machineName: identical(machineName, _sentinel)
          ? this.machineName
          : machineName as String?,
    );
  }

  /// True when this row passes every active dimension of the filter.
  /// Inactive dimensions short-circuit to `true`, so an empty filter
  /// matches everything.
  bool accepts({
    required String customerPn,
    required String description,
    required String partName,
    required String machineName,
    required List<DplPlant> plants,
  }) {
    if (this.machineName != null &&
        !_ciContains(machineName, this.machineName!)) {
      return false;
    }
    if (plantCode != null && !_matchesPlant(machineName, plantCode!, plants)) {
      return false;
    }
    final q = query.trim();
    if (q.isEmpty) return true;
    return _ciContains(customerPn, q) ||
        _ciContains(description, q) ||
        _ciContains(partName, q) ||
        _ciContains(machineName, q);
  }

  static bool _ciContains(String haystack, String needle) {
    if (needle.isEmpty) return true;
    return haystack.toLowerCase().contains(needle.toLowerCase());
  }

  static bool _matchesPlant(
    String machineName,
    String plantCode,
    List<DplPlant> plants,
  ) {
    if (machineName.trim().isEmpty) return false;
    final p = plants.firstWhere(
      (p) => p.code == plantCode,
      orElse: () => const DplPlant(code: '', name: ''),
    );
    if (p.code.isEmpty) return false;
    final mn = machineName.toLowerCase();
    for (final m in p.machines) {
      if (m.name.toLowerCase() == mn) return true;
    }
    return false;
  }
}

const _sentinel = Object();

/// Search box + plant chip row + machine chip row. Designed to live
/// directly under the AppBar of any part-list screen and emit a single
/// [DplPartFilter] via [onChanged].
///
/// Machine chips are derived from the [availableMachineNames] the
/// caller supplies — typically the distinct set across the currently
/// loaded entries. When a plant is selected, the machine chip list is
/// narrowed to that plant's machines so the manager doesn't see
/// chips that would match zero rows.
class DplPartFilterBar extends ConsumerStatefulWidget {
  final DplPartFilter filter;
  final ValueChanged<DplPartFilter> onChanged;

  /// Distinct machine names present in the currently loaded data set.
  /// Drives the "machine" chip row (alongside whatever the active
  /// plant's machines roster says).
  final Set<String> availableMachineNames;

  /// Total rows before filtering. Surfaced in the result count.
  final int totalCount;

  /// Rows the parent kept after applying [filter]. Surfaced in the
  /// result count next to the search box.
  final int matchedCount;

  /// Placeholder text in the search field. Lets callers tailor it to
  /// each screen (the master edits search by part, the dispatch view
  /// also wants the description hint).
  final String searchHint;

  const DplPartFilterBar({
    super.key,
    required this.filter,
    required this.onChanged,
    required this.availableMachineNames,
    required this.totalCount,
    required this.matchedCount,
    this.searchHint = 'Search description / part / customer PN',
  });

  @override
  ConsumerState<DplPartFilterBar> createState() => _DplPartFilterBarState();
}

class _DplPartFilterBarState extends ConsumerState<DplPartFilterBar> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = widget.filter.query;
  }

  @override
  void didUpdateWidget(covariant DplPartFilterBar old) {
    super.didUpdateWidget(old);
    // Keep the controller's text in sync if the parent clears the
    // filter programmatically (e.g. a "reset filters" action). We
    // never overwrite while the user is actively typing — that's
    // handled by the if-clause.
    if (widget.filter.query != _searchCtrl.text &&
        widget.filter.query != old.filter.query) {
      _searchCtrl.text = widget.filter.query;
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onQueryChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      widget.onChanged(widget.filter.copyWith(query: v));
    });
    setState(() {/* show/hide the clear button */});
  }

  void _clearQuery() {
    _debounce?.cancel();
    _searchCtrl.clear();
    widget.onChanged(widget.filter.copyWith(query: ''));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final plantsAsync = ref.watch(dplPlantsProvider);
    final plants = plantsAsync.asData?.value.data ?? const <DplPlant>[];

    // Narrow the visible machine chips to the selected plant's machines
    // (intersected with what we actually saw in the data) so chips
    // never go stale or match zero rows.
    final Set<String> machineRoster;
    if (widget.filter.plantCode != null) {
      final p = plants.firstWhere(
        (p) => p.code == widget.filter.plantCode,
        orElse: () => const DplPlant(code: '', name: ''),
      );
      machineRoster = p.machines
          .map((m) => m.name)
          .where((n) => n.isNotEmpty)
          .toSet()
          .intersection(widget.availableMachineNames);
    } else {
      machineRoster = widget.availableMachineNames;
    }
    final machinesSorted = machineRoster.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return Container(
      color: DplColors.cardBg,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ─── Search input ───
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: _onQueryChanged,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    hintText: widget.searchHint,
                    suffixIcon: _searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            iconSize: 18,
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: _clearQuery,
                          ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          BorderSide(color: DplColors.divider),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          BorderSide(color: DplColors.divider),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _ResultCount(
                matched: widget.matchedCount,
                total: widget.totalCount,
                isFiltered: !widget.filter.isEmpty,
              ),
            ],
          ),
          // ─── Plant chip row ─── (only if backend returned >1 plant).
          if (plants.length > 1) ...[
            const SizedBox(height: 10),
            _ChipRow(
              label: 'PLANT',
              children: [
                _FilterChip(
                  label: 'All',
                  icon: Icons.business_rounded,
                  selected: widget.filter.plantCode == null,
                  onTap: () => widget.onChanged(
                    widget.filter.copyWith(plantCode: null),
                  ),
                ),
                for (final p in plants)
                  _FilterChip(
                    label: p.name.isEmpty ? p.code : p.name,
                    icon: Icons.factory_rounded,
                    selected: widget.filter.plantCode == p.code,
                    onTap: () => widget.onChanged(
                      widget.filter.copyWith(
                        plantCode: widget.filter.plantCode == p.code
                            ? null
                            : p.code,
                        // Clear an incompatible machine pin when
                        // switching plants — avoids a phantom filter
                        // that hides every row.
                        machineName: null,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          // ─── Machine chip row ───
          if (machinesSorted.isNotEmpty) ...[
            const SizedBox(height: 8),
            _ChipRow(
              label: 'MACHINE',
              children: [
                _FilterChip(
                  label: 'All',
                  icon: Icons.precision_manufacturing_rounded,
                  selected: widget.filter.machineName == null,
                  onTap: () => widget.onChanged(
                    widget.filter.copyWith(machineName: null),
                  ),
                ),
                for (final m in machinesSorted)
                  _FilterChip(
                    label: m,
                    icon: Icons.precision_manufacturing_outlined,
                    selected: widget.filter.machineName == m,
                    onTap: () => widget.onChanged(
                      widget.filter.copyWith(
                        machineName:
                            widget.filter.machineName == m ? null : m,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _ResultCount extends StatelessWidget {
  final int matched;
  final int total;
  final bool isFiltered;
  const _ResultCount({
    required this.matched,
    required this.total,
    required this.isFiltered,
  });

  @override
  Widget build(BuildContext context) {
    final label = isFiltered ? '$matched / $total' : '$total';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: isFiltered ? DplColors.primaryTint : DplColors.neutralBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isFiltered ? DplColors.primaryDark : DplColors.textSecondary,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _ChipRow extends StatelessWidget {
  final String label;
  final List<Widget> children;
  const _ChipRow({required this.label, required this.children});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.9,
              color: DplColors.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i != children.length - 1) const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? DplColors.primary : DplColors.neutralBg,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 13,
                color: selected ? Colors.white : DplColors.textSecondary,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : DplColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
