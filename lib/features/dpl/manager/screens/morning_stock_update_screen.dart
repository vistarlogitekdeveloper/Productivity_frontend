import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_refresh_icon_button.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_customer_snapshot.dart';
import '../../models/dpl_plant.dart';
import '../../summary/providers/plants_provider.dart';
import '../providers/dpl_customer_snapshot_provider.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_retry.dart';

/// Manager / Dispatch daily-entry screen: TML opening stock + the
/// customer's planned consumption per part for the selected date.
///
/// Renders two sections per (plant, date):
///   1. Already entered (N) — pre-filled editable rows with the existing
///      values. Manager can correct typos or update if TML re-calls.
///   2. Needs entry (N) — empty rows for parts that have a buffer norm
///      but no snapshot yet for the date. Manager fills in to unblock
///      the Today's Dispatch Plan calculator.
///
/// "Save" upserts every row where the manager filled in both numbers.
class MorningStockUpdateScreen extends ConsumerStatefulWidget {
  const MorningStockUpdateScreen({super.key});

  @override
  ConsumerState<MorningStockUpdateScreen> createState() =>
      _MorningStockUpdateScreenState();
}

class _MorningStockUpdateScreenState
    extends ConsumerState<MorningStockUpdateScreen> {
  /// Per-part edit state, keyed by partId. Re-seeded when the
  /// (plant, date) pair changes.
  final Map<int, _SnapshotDraft> _drafts = {};
  String? _seededKey;

  bool _saving = false;
  String? _saveError;

  @override
  Widget build(BuildContext context) {
    final plantCode = ref.watch(dplCustomerSnapshotPlantProvider);
    final date = ref.watch(dplCustomerSnapshotDateProvider);
    final asyncPage = ref.watch(dplCustomerSnapshotPageProvider);

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Morning Stock Update',
        actions: [
          DplRefreshIconButton(
            onRefresh: () async {
              ref.invalidate(dplCustomerSnapshotPageProvider);
              await ref.read(dplCustomerSnapshotPageProvider.future);
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FilterBar(plantCode: plantCode, date: date),
          Divider(height: 1, color: DplColors.divider),
          Expanded(
            child: plantCode == null
                ? const _PickAPlantPrompt()
                : asyncPage.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => DplErrorRetry(
                      message: e.toString(),
                      onRetry: () =>
                          ref.invalidate(dplCustomerSnapshotPageProvider),
                    ),
                    data: (res) {
                      if (res == null) return const _PickAPlantPrompt();
                      if (res.isError) {
                        return DplErrorRetry(
                          message: res.error ?? 'Failed to load.',
                          onRetry: () => ref
                              .invalidate(dplCustomerSnapshotPageProvider),
                        );
                      }
                      final page = res.data!;
                      _seedDraftsIfNeeded(page);
                      return _Body(page: page, drafts: _drafts);
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: plantCode == null
          ? null
          : asyncPage.maybeWhen(
              data: (res) {
                if (res == null || res.isError) return null;
                return _SaveBar(
                  saving: _saving,
                  error: _saveError,
                  readyCount:
                      _drafts.values.where((d) => d.isReady).length,
                  onSubmit: () => _save(plantCode, date),
                );
              },
              orElse: () => null,
            ),
    );
  }

  /// Seed drafts from the loaded page. Only re-seeds when the
  /// (plant, date) pair has changed — otherwise the manager's
  /// in-flight edits would be wiped on every keystroke.
  void _seedDraftsIfNeeded(DplCustomerSnapshotsPage page) {
    final key =
        '${page.plantCode}|${DateFormat('yyyy-MM-dd').format(page.snapshotDate)}';
    if (_seededKey == key && _drafts.isNotEmpty) return;
    _drafts.clear();
    for (final entry in page.entries) {
      _drafts[entry.partId] = _SnapshotDraft.fromExisting(entry);
    }
    for (final p in page.missingParts) {
      _drafts[p.partId] = _SnapshotDraft.empty(p.partId);
    }
    _seededKey = key;
    _saveError = null;
  }

  Future<void> _save(String plantCode, DateTime snapshotDate) async {
    final ready = _drafts.values.where((d) => d.isReady).toList();
    if (ready.isEmpty) {
      setState(() => _saveError =
          'No rows are ready to save — fill in both fields for at '
          'least one part first.');
      return;
    }

    setState(() {
      _saving = true;
      _saveError = null;
    });

    final api = ref.read(dplApiServiceProvider);
    final res = await api.upsertCustomerSnapshots(
      plantCode: plantCode,
      snapshotDate: snapshotDate,
      entries: [
        for (final d in ready)
          DplCustomerSnapshotUpsertRequest(
            partId: d.partId,
            tmlOpeningStock: d.tmlOpeningStock!,
            customerPlanQty: d.customerPlanQty!,
            remarks: d.remarksCtrl.text.trim().isEmpty
                ? null
                : d.remarksCtrl.text.trim(),
          ),
      ],
    );

    if (!mounted) return;

    if (res.isError) {
      setState(() {
        _saving = false;
        _saveError = res.error ?? 'Failed to save morning snapshot.';
      });
      return;
    }

    final saved = res.data ?? 0;
    setState(() {
      _saving = false;
      _seededKey = null; // force re-seed from server source-of-truth
    });
    ref.invalidate(dplCustomerSnapshotPageProvider);
    DplSnacks.success(
      context,
      'Saved $saved row${saved == 1 ? "" : "s"}.',
    );
  }
}

class _FilterBar extends ConsumerWidget {
  final String? plantCode;
  final DateTime date;
  const _FilterBar({required this.plantCode, required this.date});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plantsAsync = ref.watch(dplPlantsProvider);
    return Container(
      color: DplColors.cardBg,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Expanded(
            child: plantsAsync.when(
              loading: () => const _FilterSkeleton(label: 'Plant'),
              error: (e, _) => Text(
                'Plants error: $e',
                style: TextStyle(color: DplColors.error),
              ),
              data: (res) {
                final plants =
                    (res.data ?? const <DplPlant>[]).cast<DplPlant>();
                return DropdownButtonFormField<String>(
                  initialValue: plantCode ??
                      (plants.isNotEmpty ? plants.first.code : null),
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Plant',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    isDense: true,
                  ),
                  items: [
                    for (final p in plants)
                      DropdownMenuItem<String>(
                        value: p.code,
                        child: Text('${p.name} · ${p.code}'),
                      ),
                  ],
                  onChanged: (code) {
                    if (code == null) return;
                    ref
                        .read(dplCustomerSnapshotPlantProvider.notifier)
                        .set(code);
                  },
                );
              },
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 170,
            child: InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: date,
                  // Backend allows max 7 days back, no future.
                  firstDate: DateTime.now().subtract(const Duration(days: 7)),
                  lastDate: DateTime.now(),
                );
                if (picked != null) {
                  ref
                      .read(dplCustomerSnapshotDateProvider.notifier)
                      .set(picked);
                }
              },
              borderRadius: BorderRadius.circular(12),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Date',
                  prefixIcon: const Icon(Icons.calendar_today, size: 18),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
                child: Text(
                  DateFormat('EEE, dd MMM yyyy').format(date),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterSkeleton extends StatelessWidget {
  final String label;
  const _FilterSkeleton({required this.label});
  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        isDense: true,
      ),
      child: const SizedBox(height: 18),
    );
  }
}

class _PickAPlantPrompt extends StatelessWidget {
  const _PickAPlantPrompt();
  @override
  Widget build(BuildContext context) {
    return const DplEmptyState(
      icon: Icons.factory_outlined,
      title: 'Pick a plant',
      message:
          'Select a plant above to start entering the morning stock update.',
    );
  }
}

class _Body extends StatelessWidget {
  final DplCustomerSnapshotsPage page;
  final Map<int, _SnapshotDraft> drafts;
  const _Body({required this.page, required this.drafts});

  @override
  Widget build(BuildContext context) {
    final entered = page.entries;
    final missing = page.missingParts;

    if (entered.isEmpty && missing.isEmpty) {
      return const DplEmptyState(
        icon: Icons.inbox_outlined,
        title: 'Nothing to enter',
        message:
            'No parts have a buffer norm on this plant yet. Configure '
            'buffer norms first.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 90),
      children: [
        if (missing.isNotEmpty) ...[
          _SectionHeader(
            label: 'Needs entry (${missing.length})',
            colour: DplColors.warning,
          ),
          for (final p in missing)
            _SnapshotEditCard(
              draft: drafts[p.partId]!,
              customerPn: p.customerPn,
              description: p.description,
              partName: '',
              wasEntered: false,
              enteredBy: null,
              enteredAt: null,
            ),
          if (entered.isNotEmpty) const SizedBox(height: 14),
        ],
        if (entered.isNotEmpty) ...[
          _SectionHeader(
            label: 'Already entered (${entered.length})',
            colour: DplColors.success,
          ),
          for (final e in entered)
            _SnapshotEditCard(
              draft: drafts[e.partId]!,
              customerPn: e.customerPn,
              description: e.description,
              partName: '',
              wasEntered: true,
              enteredBy: e.enteredBy?.name,
              enteredAt: e.enteredAt,
            ),
        ],
      ],
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
            decoration: BoxDecoration(
              color: colour,
              shape: BoxShape.circle,
            ),
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

class _SnapshotEditCard extends StatelessWidget {
  final _SnapshotDraft draft;
  final String customerPn;
  final String description;
  final String partName;
  final bool wasEntered;
  final String? enteredBy;
  final DateTime? enteredAt;

  const _SnapshotEditCard({
    required this.draft,
    required this.customerPn,
    required this.description,
    required this.partName,
    required this.wasEntered,
    required this.enteredBy,
    required this.enteredAt,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: wasEntered ? DplColors.divider : DplColors.warning,
          width: wasEntered ? 1.0 : 1.4,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header — description chip + customer P/N + entered-by stamp.
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: DplColors.primaryTint,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  description.isEmpty ? '-' : description,
                  style: TextStyle(
                    color: DplColors.primaryDark,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  customerPn,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: DplColors.textSecondary,
                    fontWeight: FontWeight.w700,
                    fontSize: 11.5,
                  ),
                ),
              ),
              if (wasEntered && enteredBy != null && enteredBy!.isNotEmpty)
                Text(
                  'by $enteredBy${enteredAt != null ? "  ·  ${DateFormat('HH:mm').format(enteredAt!.toLocal())}" : ""}',
                  style: TextStyle(
                    color: DplColors.textTertiary,
                    fontWeight: FontWeight.w600,
                    fontSize: 10.5,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          // Inputs row — TML opening stock + customer plan today.
          Row(
            children: [
              Expanded(
                child: _NumberField(
                  label: 'TML opening stock',
                  helper: 'NOS at customer end',
                  controller: draft.tmlOpeningCtrl,
                  onChanged: (v) => draft.tmlOpeningStock = v,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _NumberField(
                  label: 'Customer plan',
                  helper: 'NOS today',
                  controller: draft.customerPlanCtrl,
                  onChanged: (v) => draft.customerPlanQty = v,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Optional remarks — small, dim, only renders when user is
          // entering something so it doesn't clutter the typical row.
          TextField(
            controller: draft.remarksCtrl,
            maxLength: 120,
            decoration: InputDecoration(
              labelText: 'Remarks (optional)',
              helperText: 'e.g. "TML hasn\'t shared today\'s data yet"',
              helperStyle: const TextStyle(fontSize: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              counterText: '',
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  final String label;
  final String helper;
  final TextEditingController controller;
  final void Function(int? value) onChanged;
  const _NumberField({
    required this.label,
    required this.helper,
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(),
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(7),
      ],
      decoration: InputDecoration(
        labelText: label,
        helperText: helper.isEmpty ? null : helper,
        helperStyle: const TextStyle(fontSize: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        isDense: true,
      ),
      onChanged: (raw) {
        final parsed = int.tryParse(raw.trim());
        onChanged(parsed);
      },
    );
  }
}

class _SaveBar extends StatelessWidget {
  final bool saving;
  final String? error;
  final int readyCount;
  final VoidCallback onSubmit;

  const _SaveBar({
    required this.saving,
    required this.error,
    required this.readyCount,
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
                    readyCount == 0
                        ? 'No rows ready to save'
                        : '$readyCount row${readyCount == 1 ? "" : "s"} ready',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: saving || readyCount == 0 ? null : onSubmit,
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

/// Per-part edit state for the Morning Stock Update screen. Holds the
/// live TextEditingControllers so typing doesn't trigger provider
/// rebuilds. A draft is "ready" when both numeric fields are filled
/// in with valid non-negative integers.
class _SnapshotDraft {
  final int partId;
  final TextEditingController tmlOpeningCtrl;
  final TextEditingController customerPlanCtrl;
  final TextEditingController remarksCtrl;
  int? tmlOpeningStock;
  int? customerPlanQty;

  _SnapshotDraft({
    required this.partId,
    required this.tmlOpeningCtrl,
    required this.customerPlanCtrl,
    required this.remarksCtrl,
    this.tmlOpeningStock,
    this.customerPlanQty,
  });

  factory _SnapshotDraft.fromExisting(DplCustomerSnapshot entry) {
    return _SnapshotDraft(
      partId: entry.partId,
      tmlOpeningCtrl:
          TextEditingController(text: '${entry.tmlOpeningStock}'),
      customerPlanCtrl:
          TextEditingController(text: '${entry.customerPlanQty}'),
      remarksCtrl: TextEditingController(text: entry.remarks ?? ''),
      tmlOpeningStock: entry.tmlOpeningStock,
      customerPlanQty: entry.customerPlanQty,
    );
  }

  factory _SnapshotDraft.empty(int partId) {
    return _SnapshotDraft(
      partId: partId,
      tmlOpeningCtrl: TextEditingController(),
      customerPlanCtrl: TextEditingController(),
      remarksCtrl: TextEditingController(),
    );
  }

  bool get isReady {
    if (tmlOpeningStock == null || tmlOpeningStock! < 0) return false;
    if (customerPlanQty == null || customerPlanQty! < 0) return false;
    return true;
  }
}
