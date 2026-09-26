import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_refresh_icon_button.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_buffer_norm.dart';
import '../../models/dpl_plant.dart';
import '../../summary/providers/plants_provider.dart';
import '../providers/dpl_buffer_norms_provider.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_retry.dart';

/// Manager-only admin screen: per-plant per-part buffer norms.
///
/// Renders two sections per plant:
///   1. Configured norms — editable rows for parts that already have
///      a `dpl_buffer_norms` row.
///   2. Parts without norms — "needs setup" rows; manager types in
///      the buffer target + trolley capacity to create the norm.
///
/// "Save All" upserts every row where the manager filled in a
/// trolley-capacity > 0 (the minimum gate the backend enforces).
class BufferNormsScreen extends ConsumerStatefulWidget {
  const BufferNormsScreen({super.key});

  @override
  ConsumerState<BufferNormsScreen> createState() => _BufferNormsScreenState();
}

class _BufferNormsScreenState extends ConsumerState<BufferNormsScreen> {
  /// Per-part edit state, keyed by partId. Survives plant switches
  /// (just gets re-seeded from the next plant's loaded data).
  final Map<int, _NormDraft> _drafts = {};

  /// Tracks the plant the drafts were last seeded for, so we know
  /// when the loaded data is for a different plant and the drafts
  /// need to be reset.
  String? _seededForPlant;

  bool _saving = false;
  String? _saveError;

  @override
  Widget build(BuildContext context) {
    final plantCode = ref.watch(dplBufferNormsPlantProvider);
    final asyncPage = ref.watch(dplBufferNormsPageProvider);

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Buffer Norms',
        actions: [
          DplRefreshIconButton(
            onRefresh: () async {
              ref.invalidate(dplBufferNormsPageProvider);
              await ref.read(dplBufferNormsPageProvider.future);
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PlantPicker(plantCode: plantCode),
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
                          ref.invalidate(dplBufferNormsPageProvider),
                    ),
                    data: (res) {
                      if (res == null) return const _PickAPlantPrompt();
                      if (res.isError) {
                        return DplErrorRetry(
                          message: res.error ?? 'Failed to load.',
                          onRetry: () =>
                              ref.invalidate(dplBufferNormsPageProvider),
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
                  dirtyCount: _drafts.values.where((d) => d.isReady).length,
                  onSubmit: () => _save(plantCode),
                );
              },
              orElse: () => null,
            ),
    );
  }

  /// Seed the draft map from the loaded page. Called every build but
  /// only re-seeds when the page's plant differs from `_seededForPlant`
  /// — otherwise the manager's in-flight edits would be wiped on every
  /// rebuild (which happens on every keystroke via the controllers).
  void _seedDraftsIfNeeded(DplBufferNormsPage page) {
    if (_seededForPlant == page.plantCode && _drafts.isNotEmpty) return;
    _drafts.clear();
    for (final norm in page.norms) {
      _drafts[norm.partId] = _NormDraft.fromExisting(norm);
    }
    for (final p in page.partsWithoutNorms) {
      _drafts[p.partId] = _NormDraft.empty(p.partId);
    }
    _seededForPlant = page.plantCode;
    _saveError = null;
  }

  Future<void> _save(String plantCode) async {
    // Build upsert payload from drafts. Skip any row the manager
    // hasn't filled in (`trolley_capacity_qty > 0` is the backend's
    // mandatory floor).
    final ready = _drafts.values.where((d) => d.isReady).toList();
    if (ready.isEmpty) {
      setState(() => _saveError = 'No rows are ready to save — '
          'fill in trolley capacity > 0 first.');
      return;
    }

    setState(() {
      _saving = true;
      _saveError = null;
    });

    final api = ref.read(dplApiServiceProvider);
    final res = await api.upsertBufferNorms(
      plantCode: plantCode,
      norms: [
        for (final d in ready)
          DplBufferNormUpsertRequest(
            partId: d.partId,
            bufferTargetQty: d.bufferTargetQty!,
            trolleyCapacityQty: d.trolleyCapacityQty!,
            tripsPerDay: d.tripsPerDay,
          ),
      ],
    );

    if (!mounted) return;

    if (res.isError) {
      setState(() {
        _saving = false;
        _saveError = res.error ?? 'Failed to save norms.';
      });
      return;
    }

    // Re-fetch so the page splits parts back into "configured" vs
    // "without norms" using the server's source-of-truth.
    final saved = res.data ?? 0;
    setState(() {
      _saving = false;
      _seededForPlant = null; // force re-seed on next data event
    });
    ref.invalidate(dplBufferNormsPageProvider);
    DplSnacks.success(
      context,
      'Saved $saved buffer norm${saved == 1 ? "" : "s"}.',
    );
  }
}

class _PlantPicker extends ConsumerWidget {
  final String? plantCode;
  const _PlantPicker({required this.plantCode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plantsAsync = ref.watch(dplPlantsProvider);
    return Container(
      color: DplColors.cardBg,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: plantsAsync.when(
        loading: () => const _PickerSkeleton(),
        error: (e, _) => Text(
          'Plants error: $e',
          style: TextStyle(color: DplColors.error),
        ),
        data: (res) {
          final plants = (res.data ?? const <DplPlant>[]).cast<DplPlant>();
          return DropdownButtonFormField<String>(
            initialValue:
                plantCode ?? (plants.isNotEmpty ? plants.first.code : null),
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
              ref.read(dplBufferNormsPlantProvider.notifier).set(code);
            },
          );
        },
      ),
    );
  }
}

class _PickerSkeleton extends StatelessWidget {
  const _PickerSkeleton();
  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: 'Plant',
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
      message: 'Select a plant above to edit its buffer norms.',
    );
  }
}

class _Body extends StatelessWidget {
  final DplBufferNormsPage page;
  final Map<int, _NormDraft> drafts;
  const _Body({required this.page, required this.drafts});

  @override
  Widget build(BuildContext context) {
    final configured = page.norms;
    final missing = page.partsWithoutNorms;

    if (configured.isEmpty && missing.isEmpty) {
      return const DplEmptyState(
        icon: Icons.inbox_outlined,
        title: 'No parts in this plant',
        message: 'Add machines + parts in the masters before configuring norms.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 90),
      children: [
        if (configured.isNotEmpty) ...[
          _SectionHeader(
            label: 'Configured (${configured.length})',
            colour: DplColors.success,
          ),
          for (final norm in configured)
            _NormEditCard(
              draft: drafts[norm.partId]!,
              partName: norm.partName,
              machineName: norm.machineName,
              customerPn: norm.customerPn,
              description: norm.description,
              wasConfigured: true,
            ),
          const SizedBox(height: 14),
        ],
        if (missing.isNotEmpty) ...[
          _SectionHeader(
            label: 'Needs setup (${missing.length})',
            colour: DplColors.warning,
          ),
          for (final p in missing)
            _NormEditCard(
              draft: drafts[p.partId]!,
              partName: '',
              machineName: '',
              customerPn: p.customerPn,
              description: p.description,
              wasConfigured: false,
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

class _NormEditCard extends StatelessWidget {
  final _NormDraft draft;
  final String partName;
  final String machineName;
  final String customerPn;
  final String description;
  final bool wasConfigured;

  const _NormEditCard({
    required this.draft,
    required this.partName,
    required this.machineName,
    required this.customerPn,
    required this.description,
    required this.wasConfigured,
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
          color: wasConfigured ? DplColors.divider : DplColors.warning,
          width: wasConfigured ? 1.0 : 1.4,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header — description code chip + part name + machine label.
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      partName.isEmpty ? customerPn : partName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (partName.isNotEmpty)
                      Text(
                        customerPn,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          color: DplColors.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 10.5,
                        ),
                      ),
                  ],
                ),
              ),
              if (machineName.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: DplColors.neutralBg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    machineName,
                    style: TextStyle(
                      color: DplColors.textSecondary,
                      fontWeight: FontWeight.w700,
                      fontSize: 10.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          // Inputs row — buffer target, trolley capacity, trips/day.
          Row(
            children: [
              Expanded(
                child: _NumberField(
                  label: 'Buffer target',
                  helper: 'NOS at TML',
                  controller: draft.bufferTargetCtrl,
                  onChanged: (v) => draft.bufferTargetQty = v,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _NumberField(
                  label: 'Trolley capacity',
                  helper: 'NOS / trolley',
                  controller: draft.trolleyCapacityCtrl,
                  onChanged: (v) => draft.trolleyCapacityQty = v,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 86,
                child: _NumberField(
                  label: 'Trips / day',
                  helper: '',
                  controller: draft.tripsCtrl,
                  onChanged: (v) => draft.tripsPerDay = v ?? 6,
                ),
              ),
            ],
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
        LengthLimitingTextInputFormatter(6),
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
                        ? 'No rows ready to save'
                        : '$dirtyCount row${dirtyCount == 1 ? "" : "s"} ready',
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

/// Per-part edit state for the Buffer Norms screen. Holds the live
/// TextEditingControllers so typing doesn't trigger provider rebuilds.
/// A draft is "ready" when both buffer target + trolley capacity are
/// filled in with valid non-negative numbers AND trolley capacity > 0.
class _NormDraft {
  final int partId;
  final TextEditingController bufferTargetCtrl;
  final TextEditingController trolleyCapacityCtrl;
  final TextEditingController tripsCtrl;
  int? bufferTargetQty;
  int? trolleyCapacityQty;
  int tripsPerDay;

  _NormDraft({
    required this.partId,
    required this.bufferTargetCtrl,
    required this.trolleyCapacityCtrl,
    required this.tripsCtrl,
    this.bufferTargetQty,
    this.trolleyCapacityQty,
    this.tripsPerDay = 6,
  });

  factory _NormDraft.fromExisting(DplBufferNorm norm) {
    return _NormDraft(
      partId: norm.partId,
      bufferTargetCtrl: TextEditingController(text: '${norm.bufferTargetQty}'),
      trolleyCapacityCtrl:
          TextEditingController(text: '${norm.trolleyCapacityQty}'),
      tripsCtrl: TextEditingController(text: '${norm.tripsPerDay}'),
      bufferTargetQty: norm.bufferTargetQty,
      trolleyCapacityQty: norm.trolleyCapacityQty,
      tripsPerDay: norm.tripsPerDay,
    );
  }

  factory _NormDraft.empty(int partId) {
    return _NormDraft(
      partId: partId,
      bufferTargetCtrl: TextEditingController(),
      trolleyCapacityCtrl: TextEditingController(),
      tripsCtrl: TextEditingController(text: '6'),
      tripsPerDay: 6,
    );
  }

  bool get isReady {
    if (bufferTargetQty == null || bufferTargetQty! < 0) return false;
    if (trolleyCapacityQty == null || trolleyCapacityQty! <= 0) return false;
    if (tripsPerDay <= 0) return false;
    return true;
  }
}
