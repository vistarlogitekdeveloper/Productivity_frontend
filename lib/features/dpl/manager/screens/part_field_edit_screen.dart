import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_refresh_icon_button.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_part_field.dart';
import '../../models/dpl_plant.dart';
import '../../summary/providers/plants_provider.dart';
import '../providers/dpl_part_field_provider.dart';
import '../widgets/dpl_part_filter_bar.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_retry.dart';

/// One screen serves all 3 per-part field edits:
///   * Stocking Norm           (configured once)
///   * Customer Opening Stock  (refreshed monthly)
///   * Customer's Today's Plan (updated daily)
///
/// The [kind] parameter drives the title, the helper-text cadence,
/// and which API endpoint the screen talks to. Same edit pattern as
/// `BufferNormsScreen`: draft map of TextEditingControllers, sticky
/// Save bar at the bottom, optimistic re-fetch after a successful
/// upsert.
class PartFieldEditScreen extends ConsumerStatefulWidget {
  final DplPartFieldKind kind;
  const PartFieldEditScreen({super.key, required this.kind});

  @override
  ConsumerState<PartFieldEditScreen> createState() =>
      _PartFieldEditScreenState();
}

class _PartFieldEditScreenState extends ConsumerState<PartFieldEditScreen> {
  /// Per-part edit state. Re-seeded on first data event and after
  /// a successful save (which invalidates the provider).
  final Map<int, _FieldDraft> _drafts = {};

  /// Signature of the page we last seeded from. Lets us detect when
  /// the server's source-of-truth has actually changed (e.g. after a
  /// successful save returns updated values) vs. when build() runs
  /// for unrelated reasons (e.g. user typing). A naive `bool _seeded`
  /// raced with the post-save refresh: the first rebuild after
  /// `setState` ran with stale cached data, the flag flipped to true,
  /// and when the fresh page arrived the early-return skipped it so
  /// the UI never picked up the freshly-saved values.
  String? _seededSignature;

  bool _saving = false;
  String? _saveError;

  /// Search + plant + machine filter. Applied to the loaded page before
  /// rendering so the user can quickly drill into a specific subset.
  /// Lifted to the screen so it survives keystrokes on individual rows
  /// (the filter bar is a child and only emits state changes upwards).
  DplPartFilter _filter = const DplPartFilter();

  @override
  Widget build(BuildContext context) {
    final asyncPage = ref.watch(dplPartFieldPageProvider(widget.kind));

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: widget.kind.label,
        actions: [
          DplRefreshIconButton(
            onRefresh: () async {
              ref.invalidate(dplPartFieldPageProvider(widget.kind));
              await ref.read(dplPartFieldPageProvider(widget.kind).future);
            },
          ),
        ],
      ),
      body: asyncPage.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => DplErrorRetry(
          message: e.toString(),
          onRetry: () =>
              ref.invalidate(dplPartFieldPageProvider(widget.kind)),
        ),
        data: (res) {
          if (res.isError) {
            return DplErrorRetry(
              message: res.error ?? 'Failed to load.',
              onRetry: () =>
                  ref.invalidate(dplPartFieldPageProvider(widget.kind)),
            );
          }
          final page = res.data!;
          _seedDraftsIfNeeded(page);

          // Filter the entries before splitting into needs-setup /
          // configured. The plants list comes from the cached provider
          // — when it isn't loaded yet, the plant dimension simply
          // matches nothing (so the chip would be inert), which is
          // fine because the plant chips only render when >1 plant is
          // present.
          final plants =
              ref.watch(dplPlantsProvider).asData?.value.data ??
                  const <DplPlant>[];
          final filtered = page.entries
              .where((e) => _filter.accepts(
                    customerPn: e.customerPn,
                    description: e.description,
                    partName: e.partName,
                    machineName: e.machineName,
                    plants: plants,
                  ))
              .toList(growable: false);
          final machineRoster = <String>{
            for (final e in page.entries)
              if (e.machineName.isNotEmpty) e.machineName,
          };

          return Column(
            children: [
              DplPartFilterBar(
                filter: _filter,
                onChanged: (f) => setState(() => _filter = f),
                availableMachineNames: machineRoster,
                totalCount: page.entries.length,
                matchedCount: filtered.length,
              ),
              Expanded(
                child: _Body(
                  entries: filtered,
                  totals: page.totals,
                  drafts: _drafts,
                  kind: widget.kind,
                  isFiltered: !_filter.isEmpty,
                  onClearFilter: () =>
                      setState(() => _filter = const DplPartFilter()),
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: asyncPage.maybeWhen(
        data: (res) {
          if (res.isError) return null;
          return _SaveBar(
            saving: _saving,
            error: _saveError,
            dirtyCount: _countDirty(),
            onSubmit: _save,
          );
        },
        orElse: () => null,
      ),
    );
  }

  /// Snapshot of every part's original value so we can detect dirty
  /// rows after the manager edits. Re-built whenever the provider
  /// refreshes.
  final Map<int, int?> _originalValues = {};

  /// Stable hash of (partId → value) pairs. Two pages with the same
  /// signature describe the same server state — we don't need to
  /// re-seed and would clobber in-progress edits if we did.
  String _signatureFor(DplPartFieldPage page) {
    final sorted = [...page.entries]
      ..sort((a, b) => a.partId.compareTo(b.partId));
    final buf = StringBuffer();
    for (final e in sorted) {
      buf.write(e.partId);
      buf.write('=');
      buf.write(e.value ?? '');
      buf.write(';');
    }
    return buf.toString();
  }

  void _seedDraftsIfNeeded(DplPartFieldPage page) {
    final sig = _signatureFor(page);
    if (_seededSignature == sig && _drafts.isNotEmpty) return;
    // Dispose old controllers so we don't leak when re-seeding after
    // a refresh.
    for (final d in _drafts.values) {
      d.controller.dispose();
    }
    _drafts.clear();
    _originalValues.clear();
    for (final entry in page.entries) {
      final draft = _FieldDraft.fromEntry(entry);
      // Trigger a rebuild on every keystroke so the bottom Save bar
      // re-evaluates the dirty count. Without this listener, the
      // controller's text changes but `_countDirty()` never re-runs
      // and the button stays disabled.
      draft.controller.addListener(_onAnyDraftChanged);
      _drafts[entry.partId] = draft;
      _originalValues[entry.partId] = entry.value;
    }
    _seededSignature = sig;
    _saveError = null;
  }

  void _onAnyDraftChanged() {
    if (!mounted) return;
    setState(() {/* re-evaluate dirty count + button enabled state */});
  }

  @override
  void dispose() {
    for (final d in _drafts.values) {
      d.controller.dispose();
    }
    super.dispose();
  }

  /// A row is "dirty" when its current value differs from the value
  /// the server returned. Empty input ⇒ null (will clear the column).
  int _countDirty() {
    var n = 0;
    for (final d in _drafts.values) {
      final orig = _originalValues[d.partId];
      if (d.currentValue != orig) n++;
    }
    return n;
  }

  Future<void> _save() async {
    final dirty = <DplPartFieldUpsertRequest>[];
    for (final d in _drafts.values) {
      final orig = _originalValues[d.partId];
      if (d.currentValue != orig) {
        dirty.add(
          DplPartFieldUpsertRequest(partId: d.partId, value: d.currentValue),
        );
      }
    }
    if (dirty.isEmpty) {
      setState(() => _saveError = 'No changes to save.');
      return;
    }

    setState(() {
      _saving = true;
      _saveError = null;
    });

    final res = await ref
        .read(dplApiServiceProvider)
        .updatePartField(widget.kind, dirty);

    if (!mounted) return;

    if (res.isError) {
      setState(() {
        _saving = false;
        _saveError = res.error ?? 'Failed to save.';
      });
      return;
    }

    final r = res.data;
    setState(() {
      _saving = false;
    });
    // Signature changes when the server returns the new values, so
    // _seedDraftsIfNeeded will re-seed on its own once the fresh
    // page arrives. No need to force-clear here.
    ref.invalidate(dplPartFieldPageProvider(widget.kind));
    DplSnacks.success(
      context,
      r == null
          ? 'Saved.'
          : 'Saved ${r.upsertedCount} '
              'row${r.upsertedCount == 1 ? "" : "s"} '
              '(${r.updatedCount} updated, '
              '${r.unchangedCount} unchanged).',
    );
  }
}

class _Body extends StatelessWidget {
  final List<DplPartFieldEntry> entries;
  final DplPartFieldTotals totals;
  final Map<int, _FieldDraft> drafts;
  final DplPartFieldKind kind;
  final bool isFiltered;
  final VoidCallback onClearFilter;
  const _Body({
    required this.entries,
    required this.totals,
    required this.drafts,
    required this.kind,
    required this.isFiltered,
    required this.onClearFilter,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      if (isFiltered) {
        return _NoMatchesState(onClear: onClearFilter);
      }
      return const DplEmptyState(
        icon: Icons.inbox_outlined,
        title: 'No parts to configure',
        message: 'Add parts in the masters first.',
      );
    }

    // Split into "needs setup" (value is null) + "configured", with
    // unconfigured rows shown first so the manager's eye lands on
    // the action-needed parts.
    final unconfigured = <DplPartFieldEntry>[];
    final configured = <DplPartFieldEntry>[];
    for (final e in entries) {
      (e.value == null ? unconfigured : configured).add(e);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 100),
      children: [
        _HeaderHint(kind: kind, totals: totals),
        const SizedBox(height: 14),
        if (unconfigured.isNotEmpty) ...[
          _SectionHeader(
            label: 'Needs setup (${unconfigured.length})',
            colour: DplColors.warning,
          ),
          for (final e in unconfigured)
            _FieldEditCard(draft: drafts[e.partId]!, entry: e, kind: kind),
          if (configured.isNotEmpty) const SizedBox(height: 14),
        ],
        if (configured.isNotEmpty) ...[
          _SectionHeader(
            label: 'Configured (${configured.length})',
            colour: DplColors.success,
          ),
          for (final e in configured)
            _FieldEditCard(draft: drafts[e.partId]!, entry: e, kind: kind),
        ],
      ],
    );
  }
}

class _NoMatchesState extends StatelessWidget {
  final VoidCallback onClear;
  const _NoMatchesState({required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_alt_off_rounded,
              size: 56,
              color: DplColors.textTertiary,
            ),
            const SizedBox(height: 12),
            const Text(
              'No parts match the current filters',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              'Try a different search, plant, or machine.',
              style: TextStyle(
                color: DplColors.textSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Clear filters'),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderHint extends StatelessWidget {
  final DplPartFieldKind kind;
  final DplPartFieldTotals totals;
  const _HeaderHint({required this.kind, required this.totals});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: DplColors.primaryTint,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.primary.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(Icons.lightbulb_outline, color: DplColors.primaryDark),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  kind.cadence,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: DplColors.primaryDark,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${totals.configured} of ${totals.totalParts} parts have '
                  'a ${kind.label.toLowerCase()} set.',
                  style: TextStyle(
                    color: DplColors.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final Color colour;
  const _SectionHeader({required this.label, required this.colour});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
              color: DplColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldEditCard extends StatelessWidget {
  final _FieldDraft draft;
  final DplPartFieldEntry entry;
  final DplPartFieldKind kind;
  const _FieldEditCard({
    required this.draft,
    required this.entry,
    required this.kind,
  });

  @override
  Widget build(BuildContext context) {
    final unconfigured = entry.value == null;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: unconfigured ? DplColors.warning : DplColors.divider,
          width: unconfigured ? 1.4 : 1.0,
        ),
      ),
      child: Row(
        children: [
          // Description chip + part name.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: DplColors.primaryTint,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              entry.description.isEmpty ? '-' : entry.description,
              style: TextStyle(
                color: DplColors.primaryDark,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.partName.isEmpty ? entry.customerPn : entry.partName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      entry.customerPn,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: DplColors.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 10.5,
                      ),
                    ),
                    if (entry.machineName.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        '·',
                        style: TextStyle(color: DplColors.textTertiary),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        entry.machineName,
                        style: TextStyle(
                          color: DplColors.textSecondary,
                          fontWeight: FontWeight.w700,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 110,
            child: TextField(
              controller: draft.controller,
              keyboardType: const TextInputType.numberWithOptions(),
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(7),
              ],
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
              decoration: InputDecoration(
                hintText: 'NOS',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                isDense: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SaveBar extends StatelessWidget {
  final bool saving;
  final String? error;
  final int dirtyCount;
  final VoidCallback onSubmit;
  const _SaveBar({
    required this.saving,
    required this.error,
    required this.dirtyCount,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        color: DplColors.cardBg,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: DplColors.errorBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  error!,
                  style: TextStyle(
                    color: DplColors.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                Expanded(
                  child: Text(
                    dirtyCount == 0
                        ? 'No changes'
                        : '$dirtyCount row${dirtyCount == 1 ? "" : "s"} changed',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: saving || dirtyCount == 0 ? null : onSubmit,
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save_rounded),
                  label: Text(saving ? 'Saving…' : 'Save'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────── Draft model ──────────────

/// Per-row edit state. Holds the TextEditingController so typing
/// doesn't trigger provider rebuilds. `currentValue` is what's
/// actually in the field — parsed from the controller text on every
/// change. `null` means "clear this column on save".
class _FieldDraft {
  final int partId;
  final TextEditingController controller;
  int? currentValue;

  _FieldDraft({
    required this.partId,
    required this.controller,
    this.currentValue,
  });

  factory _FieldDraft.fromEntry(DplPartFieldEntry entry) {
    final ctrl = TextEditingController(
      text: entry.value == null ? '' : '${entry.value}',
    );
    final draft = _FieldDraft(
      partId: entry.partId,
      controller: ctrl,
      currentValue: entry.value,
    );
    ctrl.addListener(() {
      final raw = ctrl.text.trim();
      draft.currentValue = raw.isEmpty ? null : int.tryParse(raw);
    });
    return draft;
  }
}
