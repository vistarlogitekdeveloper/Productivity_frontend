import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_feature_flags.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_dispatch_slip.dart';
import '../../models/dpl_plant.dart';
import '../../models/dpl_production_summary.dart';
import '../providers/dispatch_slips_provider.dart';
import '../providers/production_summary_provider.dart';
import '../services/dispatch_slip_pdf.dart';

/// Accent palette for a plant card. Lets the landing screen cycle
/// three distinct accents across the three plant cards so the eye can
/// distinguish them at a glance.
class PlantCardPalette {
  final Color accent;
  final Color accentDark;
  final Color surface;
  final Color edge;

  /// Solid fill that carries white text (the Send button). Defaults to
  /// [accentDark]; pass a solid tone since dark-mode ink is light.
  final Color? fill;

  const PlantCardPalette({
    required this.accent,
    required this.accentDark,
    required this.surface,
    required this.edge,
    this.fill,
  });
}

/// Full-form plant card — replaces the old "tap to drill in" plant
/// tile. Each card is a self-contained slip request:
///
///   ┌─────────────────────────────────────────────────────┐
///   │ ▌ 🏭  Plant Name                  [N machines]     │  Header
///   │ ▌    PLANT_CODE                                    │
///   │ ▌ ────────────────────────────────────────────     │
///   │ ▌  STATS    Actual  Plan  Done  In-prog  Pending   │  Stats row
///   │ ▌ ────────────────────────────────────────────     │
///   │ ▌  [ Machine ▾ ]                                   │  Form
///   │ ▌  [ Description ▾ smart search ]                  │
///   │ ▌  Customer P/N + Available qty (auto-filled)      │
///   │ ▌  [ Qty ____ ]                                    │
///   │ ▌  [ Vehicle no (optional) _______ ]               │
///   │ ▌  [ Notes (optional) ______________ ]             │
///   │ ▌  [ Reset ]                 [ ✈ Send for PDI ]      │
///   └─────────────────────────────────────────────────────┘
///
/// Holds its own form state so three cards on the landing screen
/// don't fight over a single Notifier.
class PlantCard extends ConsumerStatefulWidget {
  final DplPlant plant;
  final PlantCardPalette palette;

  const PlantCard({
    super.key,
    required this.plant,
    required this.palette,
  });

  @override
  ConsumerState<PlantCard> createState() => _PlantCardState();
}

/// One line in the in-progress slip — a chosen bucket + the qty the
/// user has reserved against it. Multiple cart items get sent as a
/// single multi-item slip when the user hits "Send for PDI".
class _CartItem {
  final DplProductionSummary bucket;
  final int qty;

  const _CartItem({required this.bucket, required this.qty});
}

class _PlantCardState extends ConsumerState<PlantCard> {
  late final TextEditingController _vehicleCtrl;
  late final TextEditingController _notesCtrl;

  /// Machines the user has ticked in the multi-select picker. Empty
  /// while nothing has been chosen yet. Parts dropdown shows buckets
  /// across every selected machine so the user can queue one slip
  /// that spans, say, both Nexon SR and Nexon PR.
  final Set<int> _selectedMachineIds = {};
  bool _submitting = false;
  String? _serverError;

  /// Items the user has added to this slip via the multi-select picker
  /// but not yet sent. One slip can carry multiple
  /// `(machine, part, qty)` lines so the user can spread a large
  /// dispatch across several parts when no single one has enough
  /// stock — e.g. need 927 NOS, top-rank part has 794 available,
  /// second part covers the remaining 133.
  final List<_CartItem> _cartItems = [];

  @override
  void initState() {
    super.initState();
    _vehicleCtrl = TextEditingController();
    _notesCtrl = TextEditingController();
    // Single-machine plants auto-select to skip a click.
    if (widget.plant.machines.length == 1) {
      _selectedMachineIds.add(widget.plant.machines.first.id);
    } else if (widget.plant.machineIds.length == 1) {
      _selectedMachineIds.add(widget.plant.machineIds.first);
    }
  }

  @override
  void dispose() {
    _vehicleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  /// Sum of qty across every row currently in the cart. Drives the
  /// "Send for PDI · N NOS" button label.
  int get _cartTotalQty =>
      _cartItems.fold<int>(0, (sum, it) => sum + it.qty);

  /// Cart commitments keyed by `partId` for buckets that belong to
  /// **any of the currently selected machines**. Passed to the picker
  /// so its per-row "available" can subtract what's already queued —
  /// keeps the user from over-allocating one bucket across multiple
  /// cart entries before the request even hits the backend.
  Map<int, int> _cartCommitmentsForSelectedMachines() {
    final out = <int, int>{};
    for (final it in _cartItems) {
      if (!_selectedMachineIds.contains(it.bucket.machineId)) continue;
      out[it.bucket.partId] = (out[it.bucket.partId] ?? 0) + it.qty;
    }
    return out;
  }

  /// Buckets in the current plant filtered to the set of selected
  /// machines. Returns null while the provider is still loading or
  /// errored.
  List<DplProductionSummary>? _bucketsForSelectedMachines() {
    if (_selectedMachineIds.isEmpty) return const [];
    final async = ref.read(
      dplProductionSummaryByPlantProvider(widget.plant.code),
    );
    final page = async.asData?.value.data;
    if (page == null) return null;
    return page.items
        .where((b) => _selectedMachineIds.contains(b.machineId))
        .toList(growable: false);
  }

  void _onMachinesChanged(Set<int> next) {
    // The cart already supports multi-machine slips (one slip can
    // carry items from machine A and machine B), so we don't clear
    // the cart when the user re-ticks machines — we just rebuild
    // which buckets the picker shows. Cart commitments for machines
    // that are no longer selected remain valid; the user can still
    // see them in the cart list and remove if needed.
    setState(() {
      _selectedMachineIds
        ..clear()
        ..addAll(next);
      _serverError = null;
    });
  }

  void _onPartAdded(PickedPart pick) {
    setState(() {
      _cartItems.add(_CartItem(bucket: pick.bucket, qty: pick.qty));
      _serverError = null;
    });
  }

  void _removeFromCart(int index) {
    setState(() {
      _cartItems.removeAt(index);
      _serverError = null;
    });
  }

  void _resetForm() {
    setState(() {
      _selectedMachineIds.clear();
      if (widget.plant.machines.length == 1) {
        _selectedMachineIds.add(widget.plant.machines.first.id);
      } else if (widget.plant.machineIds.length == 1) {
        _selectedMachineIds.add(widget.plant.machineIds.first);
      }
      _cartItems.clear();
      _vehicleCtrl.clear();
      _notesCtrl.clear();
      _serverError = null;
    });
  }

  Future<void> _submit() async {
    if (_cartItems.isEmpty) {
      setState(() => _serverError =
          'Add at least one description before sending.');
      return;
    }

    setState(() {
      _submitting = true;
      _serverError = null;
    });

    final vehicleNo = _vehicleCtrl.text.trim();
    final notes = _notesCtrl.text.trim();
    final items = List<_CartItem>.from(_cartItems);
    final api = ref.read(dplApiServiceProvider);

    // Fire one slip per cart item — N descriptions in the cart =
    // N separate slips at the backend. Send them sequentially so
    // any per-row failure can be surfaced cleanly to the user
    // (slips that succeeded are already persisted; we leave the
    // failing + remaining rows in the cart so the user can retry).
    final created = <DplDispatchSlip>[];
    DplApiResponse<DplDispatchSlip>? failureRes;
    int failedAtIndex = -1;
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      final res = await api.createDispatchSlip(
        plantCode: widget.plant.code,
        items: [
          DispatchSlipItemRequest(
            machineId: it.bucket.machineId,
            partId: it.bucket.partId,
            qty: it.qty,
          ),
        ],
        vehicleNo: vehicleNo.isEmpty ? null : vehicleNo,
        notes: notes.isEmpty ? null : notes,
      );
      if (!mounted) return;
      if (res.isError) {
        failureRes = res;
        failedAtIndex = i;
        break;
      }
      if (res.data != null) created.add(res.data!);
    }

    if (!mounted) return;

    // Invalidate everything that displays slip / bucket / pipeline
    // data so the page reflects new slips without a manual refresh.
    if (created.isNotEmpty) {
      ref.invalidate(dplProductionSummaryProvider);
      ref.invalidate(dplDispatchSlipsProvider);
      ref.invalidate(dplBucketSlipCountsProvider);
      ref.invalidate(
        dplProductionSummaryByPlantProvider(widget.plant.code),
      );
    }

    if (failureRes != null) {
      // Drop the cart rows that already went out; keep the failed
      // row + any remaining rows so the user can fix qty and retry.
      setState(() {
        if (failedAtIndex > 0) {
          _cartItems.removeRange(0, failedAtIndex);
        }
        _submitting = false;
        final base =
            failureRes!.error ?? 'Failed to create dispatch slip.';
        _serverError = created.isEmpty
            ? base
            : '$base  ·  ${created.length} slip'
                '${created.length == 1 ? "" : "s"} already sent for PDI, '
                '${_cartItems.length} remaining.';
      });
      return;
    }

    // Email each newly-created slip its rendered PDF. We render the
    // SAME PDF the user prints in-app (DispatchSlipPdfBuilder) and
    // upload it as the `pdf` multipart field to
    // `POST /dispatch/slips/:id/email`. Result counts feed into the
    // success toast so the user knows whether SMTP actually went.
    int emailedCount = 0;
    int skippedCount = 0;
    final emailErrors = <String>[];
    for (final slip in created) {
      Uint8List? pdfBytes;
      try {
        pdfBytes = await DispatchSlipPdfBuilder.build(slip);
      } catch (e) {
        emailErrors.add('${slip.slipNo}: PDF render failed');
        continue;
      }
      final emailRes = await api.sendDispatchSlipEmail(
        slip.id,
        pdfBytes: pdfBytes,
        filename: '${slip.slipNo}.pdf',
      );
      if (!mounted) return;
      if (emailRes.isError) {
        emailErrors.add(
          '${slip.slipNo}: ${emailRes.error ?? "email failed"}',
        );
        continue;
      }
      final data = emailRes.data;
      if (data == null) {
        emailErrors.add('${slip.slipNo}: empty email response');
        continue;
      }
      if (data.sent) {
        emailedCount++;
      } else if (data.skipped) {
        skippedCount++;
      } else {
        emailErrors.add(
          '${slip.slipNo}: ${data.reason ?? "email not sent"}',
        );
      }
    }

    if (!mounted) return;

    final fmt = NumberFormat.decimalPattern();
    final totalQty = items.fold<int>(0, (sum, it) => sum + it.qty);
    final slipSummary = created.length == 1
        ? 'Slip ${created.first.slipNo} sent for PDI  ·  '
            '${fmt.format(totalQty)} NOS'
        : '${created.length} slips sent for PDI  ·  '
            '${fmt.format(totalQty)} NOS total';
    DplSnacks.success(context, '$slipSummary.');

    // Surface email status as a follow-up snack so the slip-creation
    // toast stays clean. Order of precedence:
    //   1. errors → red error snack
    //   2. all skipped (SMTP off) → amber/warn message-style snack
    //   3. all emailed → quiet success snack
    if (emailErrors.isNotEmpty) {
      DplSnacks.error(
        context,
        emailedCount > 0
            ? 'Emailed $emailedCount of ${created.length} slip'
                '${created.length == 1 ? "" : "s"}; '
                '${emailErrors.length} failed: '
                '${emailErrors.first}'
            : 'Email failed: ${emailErrors.first}',
      );
    } else if (skippedCount == created.length) {
      DplSnacks.warning(
        context,
        'Slip${created.length == 1 ? "" : "s"} not emailed — '
        'SMTP is not configured on this deploy.',
      );
    } else if (emailedCount == created.length) {
      DplSnacks.success(
        context,
        emailedCount == 1
            ? 'Slip emailed to Dispatch.'
            : '$emailedCount slips emailed to Dispatch.',
      );
    }

    _resetForm();
    setState(() => _submitting = false);
  }

  /// True when the plant has no machines assigned in the master data
  /// yet — transitional state during the migration-042 cutover where
  /// the customer hasn't confirmed the real machine mapping.
  bool get _hasNoMachines =>
      widget.plant.machines.isEmpty && widget.plant.machineIds.isEmpty;

  @override
  Widget build(BuildContext context) {
    final bucketsAsync = ref.watch(
      dplProductionSummaryByPlantProvider(widget.plant.code),
    );

    return Container(
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: widget.palette.edge, width: 1.5),
        boxShadow: DplShadows.card,
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left accent strip.
            Container(
              width: 6,
              decoration: BoxDecoration(
                color: widget.palette.accent,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(15),
                  bottomLeft: Radius.circular(15),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _PlantHeader(
                      plant: widget.plant,
                      palette: widget.palette,
                    ),
                    const SizedBox(height: 14),
                    _PlantStatsRow(
                      stats: widget.plant.stats,
                      palette: widget.palette,
                    ),
                    const SizedBox(height: 14),
                    Divider(
                      height: 1,
                      color: DplColors.divider,
                    ),
                    const SizedBox(height: 12),
                    // Transitional state — the plant master moved to a
                    // DB table in migration 042, and until the customer-
                    // confirmed `plant → machines` mapping is INSERTed
                    // some plants legitimately have zero machines.
                    // Render a clear empty-state instead of an
                    // unusable form so the user knows why the
                    // dropdowns aren't there.
                    if (_hasNoMachines)
                      _NoMachinesAssignedState(palette: widget.palette)
                    else if (DplFeatureFlags.enableDispatchTrips)
                      // Trip-driven dispatch is live — point the user
                      // at the Open Trips section instead of showing
                      // the legacy machine-picker form.
                      _TripFlowPointer(palette: widget.palette)
                    else ...[
                      _MachineMultiPicker(
                        plant: widget.plant,
                        selectedIds: _selectedMachineIds,
                        onChanged: _onMachinesChanged,
                      ),
                      // Cart of items queued for this slip request.
                      // Each row will go out as a SEPARATE slip when
                      // the user hits Send for PDI — five descriptions
                      // queued = five slips.
                      if (_cartItems.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _CartList(
                          items: _cartItems,
                          palette: widget.palette,
                          onRemove: _removeFromCart,
                        ),
                      ],
                      const SizedBox(height: 10),
                      // "+ Add description" button — opens a compact
                      // dialog where the user picks ONE part and
                      // enters its qty, then taps Add. Repeat for
                      // each description; each becomes its own slip.
                      _AddPartButton(
                        bucketsAsync: bucketsAsync,
                        hasSelectedMachines: _selectedMachineIds.isNotEmpty,
                        buckets: _bucketsForSelectedMachines(),
                        alreadyInCartByPartId:
                            _cartCommitmentsForSelectedMachines(),
                        onPartAdded: _onPartAdded,
                        palette: widget.palette,
                      ),
                      const SizedBox(height: 12),
                      _VehicleField(controller: _vehicleCtrl),
                      const SizedBox(height: 10),
                      _NotesField(controller: _notesCtrl),
                      if (_serverError != null) ...[
                        const SizedBox(height: 8),
                        _ErrorBox(message: _serverError!),
                      ],
                      const SizedBox(height: 14),
                      _Actions(
                        palette: widget.palette,
                        submitting: _submitting,
                        canSubmit:
                            !_submitting && _cartItems.isNotEmpty,
                        cartItemCount: _cartItems.length,
                        cartTotalQty: _cartTotalQty,
                        onReset: _resetForm,
                        onSubmit: _submit,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlantHeader extends StatelessWidget {
  final DplPlant plant;
  final PlantCardPalette palette;

  const _PlantHeader({required this.plant, required this.palette});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.edge),
          ),
          child: Icon(
            Icons.precision_manufacturing_outlined,
            size: 20,
            color: palette.accentDark,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                plant.name,
                style: TextStyle(
                  color: palette.accentDark,
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                  height: 1.1,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                plant.code,
                style: TextStyle(
                  color: palette.accent,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: palette.edge),
          ),
          child: Text(
            // Graceful empty state — until the customer-confirmed
            // plant→machine mapping lands the master row carries zero
            // machines. Read as "Setup pending" rather than the awkward
            // "0 machines" pill.
            plant.machineCount == 0
                ? 'Setup pending'
                : '${plant.machineCount} machine'
                    '${plant.machineCount == 1 ? "" : "s"}',
            style: TextStyle(
              color: palette.accentDark,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }
}

class _PlantStatsRow extends StatelessWidget {
  final DplPlantStats stats;
  final PlantCardPalette palette;

  const _PlantStatsRow({required this.stats, required this.palette});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    // Production-side stats — always visible, always meaningful.
    final productionRow = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _StatTile(
          label: 'Actual',
          value: fmt.format(stats.totalActualQty),
          unit: 'NOS',
          accent: palette.accentDark,
        ),
        _StatTile(
          label: 'Plan',
          value: fmt.format(stats.totalPlanQty),
          unit: 'NOS',
        ),
        _StatTile(
          label: 'Available',
          value: fmt.format(stats.availableForDispatchQty),
          unit: 'NOS',
          accent: palette.accent,
          emphasised: true,
        ),
      ],
    );

    // Dispatch-side stats — only surface when the plant has any slip
    // activity, so plants with zero slips don't show three meaningless
    // zero tiles. The pending / approved / dispatched colour palette
    // mirrors the slip-status badges used on the QA / PDI inbox so the
    // semantic mapping stays consistent across the app.
    if (!stats.hasAnyDispatchActivity) return productionRow;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        productionRow,
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _StatTile(
              label: 'Pending',
              value: fmt.format(stats.pendingQty),
              unit: 'NOS',
              accent: DplColors.warning,
            ),
            _StatTile(
              label: 'Approved',
              value: fmt.format(stats.approvedQty),
              unit: 'NOS',
              accent: DplColors.info,
            ),
            _StatTile(
              label: 'Dispatched',
              value: fmt.format(stats.dispatchedQty),
              unit: 'NOS',
              accent: DplColors.success,
            ),
          ],
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;
  final Color? accent;
  final bool emphasised;

  const _StatTile({
    required this.label,
    required this.value,
    this.unit,
    this.accent,
    this.emphasised = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: emphasised ? DplColors.primaryTint : DplColors.pageBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: emphasised
              ? (accent ?? DplColors.primary).withValues(alpha: 0.25)
              : DplColors.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: accent ?? DplColors.textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 14.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (unit != null) ...[
                const SizedBox(width: 3),
                Text(
                  unit!,
                  style: TextStyle(
                    color: accent ?? DplColors.textSecondary,
                    fontWeight: FontWeight.w700,
                    fontSize: 9.5,
                  ),
                ),
              ],
            ],
          ),
          Text(
            label,
            style: TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Multi-select machine picker — tap-to-open field that shows a
/// concise summary of which machines are currently ticked, and opens
/// a bottom sheet with a checkbox per machine so the user can build
/// one slip across several machines at once (e.g. Nexon SR + Nexon
/// PR in a single dispatch).
///
/// Each row in the sheet shows the machine name + code plus the same
/// small `actual / in-pipeline` stats line the old single-select
/// dropdown carried, so the user can make an informed pick without
/// drilling into the part picker first. Stats come from the per-plant
/// production-summary buckets that the part picker already loads.
class _MachineMultiPicker extends ConsumerWidget {
  final DplPlant plant;
  final Set<int> selectedIds;
  final ValueChanged<Set<int>> onChanged;

  const _MachineMultiPicker({
    required this.plant,
    required this.selectedIds,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bucketsAsync = ref.watch(
      dplProductionSummaryByPlantProvider(plant.code),
    );
    final statsByMachine = _aggregateStats(
      bucketsAsync.asData?.value.data?.items,
    );
    final entries = _entries();

    return _MachinePickerField(
      label: 'Machine',
      summary: _summary(entries),
      enabled: entries.isNotEmpty,
      onTap: entries.isEmpty
          ? null
          : () => _openPicker(context, entries, statsByMachine),
    );
  }

  /// Normalised list of `(id, label, code)` entries — prefers the
  /// enriched `machines[]` block, falls back to `machineIds` so the
  /// picker never goes empty if master data is missing.
  List<({int id, String label, String code})> _entries() {
    if (plant.machines.isNotEmpty) {
      return [
        for (final m in plant.machines)
          (id: m.id, label: m.label, code: m.code),
      ];
    }
    return [
      for (final id in plant.machineIds)
        (id: id, label: 'Machine #$id', code: ''),
    ];
  }

  /// Short text shown inside the field so the user knows the current
  /// selection at a glance. Reads either "Select machines", a single
  /// machine name, or "N selected · Name, Name…" when more than one.
  String _summary(List<({int id, String label, String code})> entries) {
    if (selectedIds.isEmpty) return 'Tap to select machines';
    if (selectedIds.length == 1) {
      final e = entries.firstWhere(
        (it) => it.id == selectedIds.first,
        orElse: () => (id: selectedIds.first, label: 'Machine #${selectedIds.first}', code: ''),
      );
      return e.code.isNotEmpty && e.code != e.label
          ? '${e.label}  ·  ${e.code}'
          : e.label;
    }
    final names = [
      for (final e in entries)
        if (selectedIds.contains(e.id)) e.label,
    ];
    return '${selectedIds.length} selected  ·  ${names.join(", ")}';
  }

  Future<void> _openPicker(
    BuildContext context,
    List<({int id, String label, String code})> entries,
    Map<int, _MachineStats> statsByMachine,
  ) async {
    final picked = await showModalBottomSheet<Set<int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MachineMultiPickerSheet(
        entries: entries,
        statsByMachine: statsByMachine,
        initiallySelected: Set<int>.from(selectedIds),
      ),
    );
    if (picked != null) onChanged(picked);
  }

  /// Bucket items grouped by `machineId` → `_MachineStats`.
  /// `null` when the per-plant production-summary fetch hasn't landed
  /// yet, so the picker can fall back to showing the name+code only.
  Map<int, _MachineStats> _aggregateStats(
    List<DplProductionSummary>? buckets,
  ) {
    if (buckets == null) return const {};
    final map = <int, _MachineStats>{};
    for (final b in buckets) {
      final existing = map[b.machineId] ?? const _MachineStats();
      map[b.machineId] = existing.add(b);
    }
    return map;
  }
}

/// The on-screen machine "field" — visually mimics a real input so it
/// lines up with the other form fields, but it's actually a tap
/// target that opens the multi-select bottom sheet.
class _MachinePickerField extends StatelessWidget {
  final String label;
  final String summary;
  final bool enabled;
  final VoidCallback? onTap;

  const _MachinePickerField({
    required this.label,
    required this.summary,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.precision_manufacturing_outlined),
          suffixIcon: Icon(
            Icons.arrow_drop_down_rounded,
            color: enabled
                ? DplColors.textSecondary
                : DplColors.textTertiary,
          ),
          enabled: enabled,
          border:
              OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(
          summary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: enabled
                ? DplColors.textPrimary
                : DplColors.textTertiary,
            fontWeight: FontWeight.w600,
            fontSize: 13.5,
          ),
        ),
      ),
    );
  }
}

/// Bottom-sheet for picking multiple machines. Each row carries a
/// checkbox, the machine name+code, and the stats line. Tapping
/// anywhere on the row toggles the checkbox. Sticky footer carries
/// Clear all / Done buttons so the change isn't committed until the
/// user confirms.
class _MachineMultiPickerSheet extends StatefulWidget {
  final List<({int id, String label, String code})> entries;
  final Map<int, _MachineStats> statsByMachine;
  final Set<int> initiallySelected;

  const _MachineMultiPickerSheet({
    required this.entries,
    required this.statsByMachine,
    required this.initiallySelected,
  });

  @override
  State<_MachineMultiPickerSheet> createState() =>
      _MachineMultiPickerSheetState();
}

class _MachineMultiPickerSheetState extends State<_MachineMultiPickerSheet> {
  late final Set<int> _checked;

  @override
  void initState() {
    super.initState();
    _checked = Set<int>.from(widget.initiallySelected);
  }

  void _toggle(int id) {
    setState(() {
      if (_checked.contains(id)) {
        _checked.remove(id);
      } else {
        _checked.add(id);
      }
    });
  }

  void _toggleAll(bool value) {
    setState(() {
      _checked.clear();
      if (value) {
        for (final e in widget.entries) {
          _checked.add(e.id);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final maxSheetHeight = mediaQuery.size.height * 0.75;
    final allChecked = _checked.length == widget.entries.length &&
        widget.entries.isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxSheetHeight),
        child: Container(
          decoration: BoxDecoration(
            color: DplColors.cardBg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: DplShadows.sheet,
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: DplColors.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(20, 4, 12, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Select machines',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: DplColors.textPrimary,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => _toggleAll(!allChecked),
                        child: Text(allChecked ? 'Clear all' : 'Select all'),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: DplColors.divider),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: widget.entries.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                      color: DplColors.divider,
                    ),
                    itemBuilder: (context, i) {
                      final e = widget.entries[i];
                      final stats = widget.statsByMachine[e.id];
                      final checked = _checked.contains(e.id);
                      return InkWell(
                        onTap: () => _toggle(e.id),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                          child: Row(
                            children: [
                              Checkbox(
                                value: checked,
                                onChanged: (_) => _toggle(e.id),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: _MachineDropdownEntry(
                                  label: e.label,
                                  code: e.code,
                                  stats: stats,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Divider(height: 1, color: DplColors.divider),
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Row(
                    children: [
                      Text(
                        _checked.isEmpty
                            ? 'No machines selected'
                            : _checked.length == 1
                                ? '1 machine selected'
                                : '${_checked.length} machines selected',
                        style: TextStyle(
                          color: DplColors.textSecondary,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                      const Spacer(),
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () =>
                            Navigator.of(context).pop(_checked),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Per-machine roll-up over the bucket list.
class _MachineStats {
  final int actualQty;
  final int planQty;
  final int availableQty;

  const _MachineStats({
    this.actualQty = 0,
    this.planQty = 0,
    this.availableQty = 0,
  });

  /// `actual − available` = qty committed to non-rejected slips
  /// (pending_qa + pending_pdi + approved + dispatched). Closest
  /// available approximation of "in pipeline" the bucket data alone
  /// can give us without a separate slip-list fetch — and the right
  /// signal for "how much of this machine's stock is locked up".
  int get inPipelineQty {
    final v = actualQty - availableQty;
    return v < 0 ? 0 : v;
  }

  /// `plan − actual` = qty still to produce.
  int get pendingQty {
    final v = planQty - actualQty;
    return v < 0 ? 0 : v;
  }

  bool get isEmpty => actualQty == 0 && planQty == 0 && availableQty == 0;

  _MachineStats add(DplProductionSummary b) {
    return _MachineStats(
      actualQty: actualQty + b.totalActualQty,
      planQty: planQty + b.totalPlanQty,
      availableQty: availableQty + b.availableForDispatchQty,
    );
  }
}

/// One entry in the open dropdown menu — two lines tall:
///   line 1: machine name + code (the existing `_MachineRow`)
///   line 2: small stats string, dimmed grey
class _MachineDropdownEntry extends StatelessWidget {
  final String label;
  final String code;
  final _MachineStats? stats;

  const _MachineDropdownEntry({
    required this.label,
    required this.code,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final s = stats;
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MachineRow(label: label, code: code),
        if (s != null) ...[
          const SizedBox(height: 2),
          Text(
            s.isEmpty
                ? 'No production yet'
                : '${fmt.format(s.actualQty)} actual'
                    '  ·  ${fmt.format(s.inPipelineQty)} in pipeline',
            style: TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 10.5,
              height: 1.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

class _MachineRow extends StatelessWidget {
  final String label;
  final String code;
  const _MachineRow({required this.label, required this.code});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (code.isNotEmpty && code != label) ...[
          const SizedBox(width: 6),
          Text(
            '· $code',
            style: TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 11.5,
            ),
          ),
        ],
      ],
    );
  }
}

/// "+ Add description" button that opens the single-part picker
/// sheet (`_AddPartSheet`). Replaces the older "tap a description
/// field" pattern — the user explicitly wanted a discrete add action
/// so each description shows up clearly in the cart and goes out as
/// its own slip when they hit Send for PDI.
class _AddPartButton extends StatelessWidget {
  final AsyncValue<dynamic> bucketsAsync;
  final bool hasSelectedMachines;
  final List<DplProductionSummary>? buckets;

  /// Qty already committed in the parent cart, keyed by `partId`. Used
  /// by the picker sheet so the per-row "available" reflects what's
  /// still bookable after subtracting in-cart commitments.
  final Map<int, int> alreadyInCartByPartId;

  /// Called with the chosen (bucket, qty) when the user hits Add in
  /// the picker sheet. Not called when the user cancels.
  final void Function(PickedPart pick) onPartAdded;

  final PlantCardPalette palette;

  const _AddPartButton({
    required this.bucketsAsync,
    required this.hasSelectedMachines,
    required this.buckets,
    required this.alreadyInCartByPartId,
    required this.onPartAdded,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final hint = _hintForState();
    final enabled = hint == null;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: enabled ? () => _openPicker(context) : null,
        icon: const Icon(Icons.add_rounded),
        label: Text(enabled ? 'Add description' : hint),
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.accentDark,
          side: BorderSide(
            color: enabled ? palette.edge : DplColors.divider,
            width: 1.4,
          ),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13.5,
          ),
        ),
      ),
    );
  }

  String? _hintForState() {
    if (!hasSelectedMachines) return 'Select at least one machine first';
    if (buckets == null) {
      if (bucketsAsync is AsyncError) return 'Failed to load parts';
      return 'Loading parts…';
    }
    if (buckets!.isEmpty) {
      return 'No parts with stock for the selected machines';
    }
    return null;
  }

  Future<void> _openPicker(BuildContext context) async {
    final pick = await showModalBottomSheet<PickedPart>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddPartSheet(
        buckets: buckets!,
        alreadyInCartByPartId: alreadyInCartByPartId,
      ),
    );
    if (pick != null) onPartAdded(pick);
  }
}

/// One picked row returned from the bottom-sheet picker. Caller (the
/// plant card) appends each of these to its cart, and each cart row
/// fires its own dispatch slip when the user hits "Send for PDI".
class PickedPart {
  final DplProductionSummary bucket;
  final int qty;
  const PickedPart({required this.bucket, required this.qty});
}

/// Single-part picker — opens as a bottom sheet, the user searches /
/// taps one description and types its qty, then hits Add. The chosen
/// `PickedPart` is returned to the plant card via `Navigator.pop`.
///
///   * Top: search field that filters the bucket list as the user types.
///   * Middle: scrollable list of matching buckets — each row shows
///     description, customer P/N and `available NOS` (already subtracting
///     anything sitting in the parent cart).
///   * Below selection: a "Plan Qty" input pre-validated against the
///     row's remaining-available, plus a tappable summary of the chosen
///     part with an X to switch picks without closing the sheet.
///   * Footer: Cancel + Add buttons; Add is disabled until the user has
///     both selected a description AND entered a qty in `(0, remaining]`.
///
/// We deliberately keep this single-pick — the operator wanted each
/// description queued separately so it goes out as its own slip, and a
/// single-pick sheet keeps that intent obvious. Multi-row picking
/// remains in the operator's hands via repeated taps on "+ Add
/// description".
class _AddPartSheet extends StatefulWidget {
  final List<DplProductionSummary> buckets;

  /// Qty already in the parent cart per `bucket.partId`. Reduces each
  /// row's display "available" + the validator cap so the user can't
  /// double-allocate one bucket across multiple cart entries before
  /// the request even hits the backend.
  final Map<int, int> alreadyInCartByPartId;

  const _AddPartSheet({
    required this.buckets,
    required this.alreadyInCartByPartId,
  });

  @override
  State<_AddPartSheet> createState() => _AddPartSheetState();
}

class _AddPartSheetState extends State<_AddPartSheet> {
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _qtyCtrl = TextEditingController();
  String _query = '';
  DplProductionSummary? _selected;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      final next = _searchCtrl.text;
      if (next == _query) return;
      setState(() => _query = next);
    });
    _qtyCtrl.addListener(() {
      // Footer enable state depends on qty validity — rebuild on every
      // keystroke so the Add button enables/disables as the user types.
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  int _availableFor(DplProductionSummary b) {
    final committed = widget.alreadyInCartByPartId[b.partId] ?? 0;
    final remaining = b.availableForDispatchQty - committed;
    return remaining < 0 ? 0 : remaining;
  }

  List<DplProductionSummary> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.buckets;
    return widget.buckets.where((b) {
      return b.partName.toLowerCase().contains(q) ||
          b.description.toLowerCase().contains(q) ||
          b.customerPartNo.toLowerCase().contains(q) ||
          b.materialCode.toLowerCase().contains(q) ||
          b.substratePartNo.toLowerCase().contains(q);
    }).toList(growable: false);
  }

  /// Parses the current qty input. Returns null when the field is
  /// empty, when it isn't a positive integer, or when it exceeds the
  /// selected bucket's remaining-available.
  int? _validQty() {
    final s = _selected;
    if (s == null) return null;
    final raw = _qtyCtrl.text.trim();
    if (raw.isEmpty) return null;
    final n = int.tryParse(raw);
    if (n == null || n <= 0) return null;
    if (n > _availableFor(s)) return null;
    return n;
  }

  void _select(DplProductionSummary bucket) {
    setState(() {
      _selected = bucket;
      // Clear any qty typed against the previous pick so the caps
      // line up with the new row's remaining-available.
      _qtyCtrl.clear();
    });
  }

  void _clearSelection() {
    setState(() {
      _selected = null;
      _qtyCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final maxSheetHeight = mediaQuery.size.height * 0.85;
    final fmt = NumberFormat.decimalPattern();
    final picked = _validQty();
    final canAdd = picked != null;

    return Padding(
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxSheetHeight),
        child: Container(
          decoration: BoxDecoration(
            color: DplColors.cardBg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: DplShadows.sheet,
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: DplColors.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 12, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Add description',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: DplColors.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Cancel',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: DplColors.divider),
                if (_selected == null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                    child: TextField(
                      controller: _searchCtrl,
                      autofocus: false,
                      decoration: InputDecoration(
                        hintText: 'Search by name, customer P/N, '
                            'material code…',
                        prefixIcon: const Icon(Icons.search_rounded),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        isDense: true,
                      ),
                    ),
                  ),
                  Flexible(
                    child: _visible.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(24),
                            child: Center(
                              child: Text(
                                _query.trim().isEmpty
                                    ? 'No parts with stock for the '
                                        'selected machines.'
                                    : 'No parts match "${_query.trim()}".',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: DplColors.textSecondary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding:
                                const EdgeInsets.symmetric(vertical: 6),
                            itemCount: _visible.length,
                            separatorBuilder: (_, _) => Divider(
                              height: 1,
                              indent: 16,
                              endIndent: 16,
                              color: DplColors.divider,
                            ),
                            itemBuilder: (context, i) {
                              final b = _visible[i];
                              final remaining = _availableFor(b);
                              return InkWell(
                                onTap: remaining > 0
                                    ? () => _select(b)
                                    : null,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      16, 10, 16, 10),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        b.partName.isEmpty
                                            ? b.description
                                            : b.partName,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13.5,
                                          color: DplColors.textPrimary,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        b.customerPartNo.isEmpty
                                            ? (b.materialCode.isEmpty
                                                ? '-'
                                                : b.materialCode)
                                            : b.customerPartNo,
                                        style: TextStyle(
                                          color: DplColors.textSecondary,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 11.5,
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${fmt.format(remaining)} '
                                        'NOS available',
                                        style: TextStyle(
                                          color: remaining > 0
                                              ? DplColors.primaryDark
                                              : DplColors.textTertiary,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ] else ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                      decoration: BoxDecoration(
                        color: DplColors.primaryTint,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: DplColors.primary.withValues(alpha: 0.18),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _selected!.partName.isEmpty
                                      ? _selected!.description
                                      : _selected!.partName,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13.5,
                                    color: DplColors.textPrimary,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _selected!.customerPartNo.isEmpty
                                      ? (_selected!.materialCode.isEmpty
                                          ? '-'
                                          : _selected!.materialCode)
                                      : _selected!.customerPartNo,
                                  style: TextStyle(
                                    color: DplColors.textSecondary,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 11.5,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${fmt.format(_availableFor(_selected!))} '
                                  'NOS available',
                                  style: TextStyle(
                                    color: DplColors.primaryDark,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Change description',
                            onPressed: _clearSelection,
                            icon: const Icon(Icons.close_rounded),
                            color: DplColors.textSecondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                    child: TextField(
                      controller: _qtyCtrl,
                      autofocus: true,
                      keyboardType:
                          const TextInputType.numberWithOptions(),
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(7),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Plan Qty',
                        helperText:
                            'Max ${fmt.format(_availableFor(_selected!))} NOS',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
                Divider(height: 1, color: DplColors.divider),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Row(
                    children: [
                      const Spacer(),
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: canAdd
                            ? () => Navigator.of(context).pop(
                                  PickedPart(
                                    bucket: _selected!,
                                    qty: picked,
                                  ),
                                )
                            : null,
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


/// Cart of items the user has already added to the in-progress slip.
/// Renders as a soft bordered block with one row per item and an
/// inline delete button. Header carries the running totals so the user
/// always sees "how much have I queued so far".
class _CartList extends StatelessWidget {
  final List<_CartItem> items;
  final PlantCardPalette palette;
  final void Function(int index) onRemove;

  const _CartList({
    required this.items,
    required this.palette,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final totalQty = items.fold<int>(0, (s, it) => s + it.qty);
    return Container(
      decoration: BoxDecoration(
        color: palette.surface.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.edge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header row — title + running totals.
          Padding(
            padding:
                const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Icon(
                  Icons.list_alt_rounded,
                  size: 16,
                  color: palette.accentDark,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'In this slip',
                    style: TextStyle(
                      color: palette.accentDark,
                      fontWeight: FontWeight.w800,
                      fontSize: 11.5,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                Text(
                  '${items.length} item'
                  '${items.length == 1 ? "" : "s"} · '
                  '${fmt.format(totalQty)} NOS',
                  style: TextStyle(
                    color: palette.accentDark,
                    fontWeight: FontWeight.w800,
                    fontSize: 11.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.edge),
          // Each cart item.
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) Divider(height: 1, color: palette.edge),
            _CartRow(
              item: items[i],
              palette: palette,
              onRemove: () => onRemove(i),
            ),
          ],
        ],
      ),
    );
  }
}

class _CartRow extends StatelessWidget {
  final _CartItem item;
  final PlantCardPalette palette;
  final VoidCallback onRemove;

  const _CartRow({
    required this.item,
    required this.palette,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final bucket = item.bucket;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bucket.partLabel,
                  style: TextStyle(
                    color: DplColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (bucket.customerPartNo.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    bucket.customerPartNo,
                    style: TextStyle(
                      color: DplColors.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                      letterSpacing: 0.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  '${bucket.machineLabel} · ${fmt.format(item.qty)} NOS',
                  style: TextStyle(
                    color: palette.accentDark,
                    fontWeight: FontWeight.w700,
                    fontSize: 11.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            onPressed: onRemove,
            icon: const Icon(Icons.close_rounded, size: 18),
            color: DplColors.error,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  final PlantCardPalette palette;
  final bool submitting;
  final bool canSubmit;

  /// Number of items that would be sent if the user clicked submit
  /// right now (cart rows + the in-progress row if it's valid).
  /// Drives the button's secondary "X items · N NOS" label.
  final int cartItemCount;
  final int cartTotalQty;

  final VoidCallback onReset;
  final VoidCallback onSubmit;

  const _Actions({
    required this.palette,
    required this.submitting,
    required this.canSubmit,
    required this.cartItemCount,
    required this.cartTotalQty,
    required this.onReset,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    String label;
    if (submitting) {
      label = 'Sending…';
    } else if (cartItemCount == 0) {
      label = 'Send for PDI';
    } else if (cartItemCount == 1) {
      label = 'Send for PDI · 1 slip · ${fmt.format(cartTotalQty)} NOS';
    } else {
      label = 'Send for PDI · $cartItemCount slips · '
          '${fmt.format(cartTotalQty)} NOS';
    }
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: submitting ? null : onReset,
            child: const Text('Reset'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: FilledButton.icon(
            onPressed: canSubmit ? onSubmit : null,
            icon: submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send_rounded),
            label: Text(label),
            style: FilledButton.styleFrom(
              backgroundColor: palette.fill ?? palette.accentDark,
              foregroundColor: Colors.white,
              disabledBackgroundColor: DplColors.neutralBg,
              disabledForegroundColor: DplColors.textTertiary,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Optional vehicle-number input. Backend trims + uppercases server
/// side; we also force uppercase on the FE so what the user sees
/// matches what gets persisted. 32-char cap matches the
/// `vehicle_no VARCHAR(32)` column.
class _VehicleField extends StatelessWidget {
  final TextEditingController controller;
  const _VehicleField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      textCapitalization: TextCapitalization.characters,
      inputFormatters: [
        LengthLimitingTextInputFormatter(32),
        _UpperCaseFormatter(),
      ],
      decoration: InputDecoration(
        labelText: 'Vehicle no (optional)',
        hintText: 'e.g. GJ-01-AB-1234',
        prefixIcon: const Icon(Icons.local_shipping_outlined),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

/// Optional free-text notes — customer ref, special instructions, etc.
class _NotesField extends StatelessWidget {
  final TextEditingController controller;
  const _NotesField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: 2,
      maxLength: 240,
      decoration: InputDecoration(
        labelText: 'Notes (optional)',
        hintText: 'Customer ref, special instructions, etc.',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

/// Inline red error block — shown above the action row when the
/// server rejects a submit, or when local validation catches
/// something before the request goes out.
class _ErrorBox extends StatelessWidget {
  final String message;
  const _ErrorBox({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: DplColors.errorBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DplColors.error),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline,
              size: 18, color: DplColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: DplColors.error,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Friendly empty-state shown in place of the slip-request form when
/// a plant has zero machines assigned in the master data. Currently
/// transitional: migration 042 moved the plant master to a DB table
/// and the customer-confirmed plant-to-machine INSERTs are pending. As
/// soon as backend runs them, this widget disappears and the form
/// renders normally.
/// Replaces the legacy slip-creation form (machine picker + cart +
/// vehicle/notes + Send for PDI) when the trip-driven dispatch flag
/// is on. Points the dispatcher up to the Open Trips section above
/// the plant cards.
class _TripFlowPointer extends StatelessWidget {
  final PlantCardPalette palette;
  const _TripFlowPointer({required this.palette});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.edge),
      ),
      child: Row(
        children: [
          Icon(
            Icons.local_shipping_outlined,
            size: 22,
            color: palette.accentDark,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Slip creation moved to Open Trips',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: palette.accentDark,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Pick a trip from the Open Trips list above, tick the '
                  'parts you want to ship, then tap Send for PDI on the '
                  'trip card.',
                  style: TextStyle(
                    color: DplColors.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 11.5,
                    height: 1.3,
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

class _NoMachinesAssignedState extends StatelessWidget {
  final PlantCardPalette palette;
  const _NoMachinesAssignedState({required this.palette});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.edge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: DplColors.cardBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: palette.edge),
                ),
                child: Icon(
                  Icons.build_outlined,
                  size: 18,
                  color: palette.accentDark,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'No machines assigned yet',
                  style: TextStyle(
                    color: palette.accentDark,
                    fontWeight: FontWeight.w800,
                    fontSize: 13.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            "Once the plant's machine mapping is configured, the slip "
            'request form will appear here. Production stats above will '
            'populate as soon as the assigned machines start producing.',
            style: TextStyle(
              color: palette.accentDark.withValues(alpha: 0.78),
              fontWeight: FontWeight.w600,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// Force-uppercase TextInputFormatter for the vehicle-number field.
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final upper = newValue.text.toUpperCase();
    if (upper == newValue.text) return newValue;
    return TextEditingValue(
      text: upper,
      selection: newValue.selection,
      composing: TextRange.empty,
    );
  }
}
