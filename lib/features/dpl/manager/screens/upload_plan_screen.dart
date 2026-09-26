import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../../../core/widgets/shimmer_skeleton.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_refresh_icon_button.dart';
import '../../models/dpl_carry_candidate.dart';
import '../../models/dpl_excel_preview.dart';
import '../../models/dpl_machine.dart';
import '../../models/dpl_part.dart';
import '../../models/dpl_production_plan_item.dart';
import '../../models/dpl_shift.dart';
import '../../models/dpl_supervisor.dart';
import '../providers/dpl_dashboard_provider.dart';
import '../providers/dpl_masters_provider.dart';
import '../providers/dpl_plan_list_provider.dart';
import '../providers/dpl_shifts_provider.dart';
import '../providers/dpl_upload_plan_provider.dart';
import '../widgets/dpl_date_picker_field.dart';
import '../widgets/dpl_manager_footer.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_retry.dart';
import '../widgets/part_search_field.dart';

class DplUploadPlanScreen extends ConsumerStatefulWidget {
  const DplUploadPlanScreen({super.key});

  @override
  ConsumerState<DplUploadPlanScreen> createState() =>
      _DplUploadPlanScreenState();
}

class _DplUploadPlanScreenState extends ConsumerState<DplUploadPlanScreen> {
  late final TextEditingController _releasedCtrl;
  late final TextEditingController _approvedCtrl;

  /// Machines whose cross-plan carry-forward candidates have already
  /// been fetched + injected into the manual draft. Prevents the same
  /// leftover from being added twice if the screen rebuilds.
  final Set<int> _carriesSeededForMachine = <int>{};

  @override
  void initState() {
    super.initState();
    final s = ref.read(dplUploadPlanControllerProvider);
    _releasedCtrl = TextEditingController(text: s.planReleasedBy);
    _approvedCtrl = TextEditingController(text: s.planApprovedBy);

    // Seed manual drafts as soon as machine master loads.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _trySeedManualDrafts();
    });
  }

  void _trySeedManualDrafts() {
    final machinesAsync = ref.read(dplMachinesProvider);
    machinesAsync.whenData((res) {
      if (res.isOk && res.data != null) {
        final drafts = res.data!
            .map((m) => DplManualMachineDraft(
                  machineId: m.id,
                  machineName: m.name,
                ))
            .toList();
        ref
            .read(dplUploadPlanControllerProvider.notifier)
            .seedManualDrafts(drafts);
        // Once drafts exist, also pull any pending leftover work from
        // previous shifts so the manager starts from work-in-flight
        // instead of a blank page.
        _trySeedCarriesForAllMachines();
      }
    });
  }

  Future<void> _trySeedCarriesForAllMachines() async {
    final state = ref.read(dplUploadPlanControllerProvider);
    final ctrl = ref.read(dplUploadPlanControllerProvider.notifier);
    final svc = ref.read(dplApiServiceProvider);
    for (final draft in state.manualDrafts) {
      if (_carriesSeededForMachine.contains(draft.machineId)) continue;
      _carriesSeededForMachine.add(draft.machineId);
      final res = await svc.getCarryForwardCandidates(
        machineId: draft.machineId,
        forDate: state.planDate,
      );
      if (!mounted) return;
      if (res.isError || res.data == null || res.data!.isEmpty) continue;
      for (final c in res.data!) {
        // Each candidate becomes a normal item in the draft, with
        // `carriedFromItemId` set so the backend links the source and
        // removes it from future candidate calls. Manager can edit
        // qty / remove via the existing item row controls.
        final indexInDraft = ref
                .read(dplUploadPlanControllerProvider)
                .manualDrafts
                .firstWhere((d) => d.machineId == draft.machineId,
                    orElse: () => draft)
                .items
                .length +
            1;
        ctrl.addManualItem(
          draft.machineId,
          DplProductionPlanItem(
            id: 0,
            planNo: indexInDraft,
            sequence: indexInDraft,
            partId: c.partId,
            partNumber: c.partNumber,
            partDescription: c.partDescription,
            partName: c.partName,
            planQty: c.leftoverQty,
            carriedFromItemId: c.sourceItemId,
            remarks: _carryRemarks(c),
          ),
        );
      }
    }
  }

  static String _carryRemarks(DplCarryCandidate c) {
    final date = c.sourcePlanDate;
    final dateStr = date == null
        ? ''
        : ' ${date.day}/${date.month.toString().padLeft(2, '0')}';
    final shift =
        c.sourceShiftCode.isEmpty ? '' : ' Shift ${c.sourceShiftCode}';
    return 'Carry-forward from previous plan$dateStr$shift';
  }

  @override
  void dispose() {
    _releasedCtrl.dispose();
    _approvedCtrl.dispose();
    super.dispose();
  }

  /// Returns user-facing reasons why submit is blocked (if any).
  List<String> _validationBlockers(DplUploadPlanState state) {
    final blockers = <String>[];
    if (state.supervisorUserId == null) blockers.add('Select a supervisor.');
    if (state.planReleasedBy.trim().isEmpty) {
      blockers.add('Fill in "Plan Released By".');
    }
    if (state.planApprovedBy.trim().isEmpty) {
      blockers.add('Fill in "Plan Approved By".');
    }
    if (state.mode == DplUploadMode.excel) {
      if (state.excelPreview == null ||
          state.excelPreview!.machines.isEmpty) {
        blockers.add('Upload and preview an Excel file.');
      }
    } else {
      final hasItems = state.manualDrafts
          .any((d) => d.items.any((i) => i.partId > 0 && i.planQty > 0));
      if (!hasItems) {
        blockers.add('Add at least one plan item to a machine.');
      }
    }
    return blockers;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dplUploadPlanControllerProvider);
    final ctrl = ref.read(dplUploadPlanControllerProvider.notifier);
    final supervisorsAsync = ref.watch(dplSupervisorsProvider);
    final machinesAsync = ref.watch(dplMachinesProvider);

    // Seed manual drafts whenever the machines provider emits.
    ref.listen<AsyncValue<DplApiResponse<List<DplMachine>>>>(
      dplMachinesProvider,
      (_, _) => _trySeedManualDrafts(),
    );

    final blockers = _validationBlockers(state);
    final canSubmit = !state.isSubmitting && blockers.isEmpty;

    return Scaffold(
      appBar: DplAppBar(
        title: 'Upload Production Plan',
        actions: [
          DplRefreshIconButton(
            tooltip: 'Refresh masters',
            onRefresh: () async {
              ref.invalidate(dplSupervisorsProvider);
              ref.invalidate(dplMachinesProvider);
              try {
                await Future.wait([
                  ref.read(dplSupervisorsProvider.future),
                  ref.read(dplMachinesProvider.future),
                ]);
              } catch (_) {}
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          if (state.error != null) ...[
            _ErrorBanner(message: state.error!),
            const SizedBox(height: 12),
          ],
          DplDatePickerField(
            label: 'Plan Date',
            value: state.planDate,
            firstDate: DateTime.now()
                .subtract(const Duration(days: 30)),
            lastDate: DateTime.now().add(const Duration(days: 365)),
            onChanged: ctrl.setDate,
          ),
          const SizedBox(height: 12),
          _SupervisorDropdown(
            supervisorsAsync: supervisorsAsync,
            selectedId: state.supervisorUserId,
            onChanged: ctrl.setSupervisor,
            onRefresh: () => ref.invalidate(dplSupervisorsProvider),
          ),
          const SizedBox(height: 12),
          _ShiftDropdown(
            selectedId: state.shiftId,
            onChanged: ctrl.setShift,
            onRefresh: () => ref.invalidate(dplShiftsProvider),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _releasedCtrl,
            decoration: const InputDecoration(
              labelText: 'Plan Released By',
              prefixIcon: Icon(Icons.outgoing_mail),
            ),
            onChanged: ctrl.setReleasedBy,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _approvedCtrl,
            decoration: const InputDecoration(
              labelText: 'Plan Approved By',
              prefixIcon: Icon(Icons.verified_outlined),
            ),
            onChanged: ctrl.setApprovedBy,
          ),
          const SizedBox(height: 18),
          _ModeToggle(
            mode: state.mode,
            onChanged: ctrl.setMode,
          ),
          const SizedBox(height: 14),
          if (state.mode == DplUploadMode.excel)
            _ExcelSection(state: state, ctrl: ctrl)
          else
            _ManualSection(
              state: state,
              ctrl: ctrl,
              machinesAsync: machinesAsync,
            ),
          const SizedBox(height: 24),
        ],
      ),
      bottomNavigationBar: DplManagerFooter(
        aboveNav: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!canSubmit && blockers.isNotEmpty && !state.isSubmitting)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _BlockersHint(blockers: blockers),
                  ),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed:
                        canSubmit ? () => _submit(context, ref) : null,
                    child: state.isSubmitting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: Center(
                              child:
                                  ShimmerButtonDots(size: 7, spacing: 3.5),
                            ),
                          )
                        : const Text(
                            'Submit Plan',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit(BuildContext context, WidgetRef ref) async {
    final res =
        await ref.read(dplUploadPlanControllerProvider.notifier).submit();
    if (!context.mounted) return;

    if (res.isError) {
      if (res.code == 'CONFLICT' || res.statusCode == 409) {
        final view = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Plan already exists'),
            content: const Text(
                'A plan already exists for this date and machine. View existing plan?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Close'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('View Plans'),
              ),
            ],
          ),
        );
        if (!context.mounted) return;
        if (view == true) {
          // Pop back to the shell so the user can switch to the Plans tab.
          if (context.canPop()) context.pop();
        }
        return;
      }
      DplSnack.error(context, res.error ?? 'Failed to submit plan.');
      return;
    }

    DplSnack.success(context, 'Plan submitted successfully.');
    ref.invalidate(dplPlanListProvider);
    ref.invalidate(dplDashboardSummaryProvider);
    if (context.canPop()) context.pop();
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: VistarPalette.badBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: VistarPalette.badLine),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: VistarPalette.bad),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: VistarPalette.badInk,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlockersHint extends StatelessWidget {
  final List<String> blockers;
  const _BlockersHint({required this.blockers});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: VistarPalette.warnBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: VistarPalette.warnLine),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: VistarPalette.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Before submitting:',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: VistarPalette.warnInk,
                  ),
                ),
                const SizedBox(height: 2),
                for (final b in blockers)
                  Text(
                    '• $b',
                    style: TextStyle(
                      color: VistarPalette.warnInk,
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

class _ShiftDropdown extends ConsumerWidget {
  final int? selectedId;
  final ValueChanged<int?> onChanged;
  final VoidCallback onRefresh;

  const _ShiftDropdown({
    required this.selectedId,
    required this.onChanged,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shiftsAsync = ref.watch(dplShiftsProvider);

    return shiftsAsync.when(
      loading: () => _Skeleton(label: 'Loading shifts...'),
      // If the backend is mid-deploy or shifts are missing, treat this
      // dimension as optional — keep the rest of the form usable.
      error: (e, _) => _OptionalShiftPlaceholder(onRefresh: onRefresh),
      data: (res) {
        if (res.isError) {
          return _OptionalShiftPlaceholder(onRefresh: onRefresh);
        }
        final shifts = res.data ?? const <DplShift>[];

        if (shifts.isEmpty) {
          return _OptionalShiftPlaceholder(
            onRefresh: onRefresh,
            message: 'No shifts configured. Add Shift A / B / C from '
                'Settings → Shifts to pre-tag items here.',
          );
        }

        final hasSelection =
            selectedId != null && shifts.any((s) => s.id == selectedId);

        return DropdownButtonFormField<int?>(
          initialValue: hasSelection ? selectedId : null,
          decoration: const InputDecoration(
            labelText: 'Shift (optional)',
            helperText:
                'Leave blank to let supervisor\'s start time decide the shift.',
            prefixIcon: Icon(Icons.access_time),
          ),
          items: [
            const DropdownMenuItem<int?>(
              value: null,
              child: Text('Auto (decide on START)'),
            ),
            for (final s in shifts)
              DropdownMenuItem<int?>(
                value: s.id,
                child: Text(
                  '${s.name.isEmpty ? "Shift ${s.code}" : s.name}'
                  '${s.windowLabel.isEmpty ? "" : "  •  ${s.windowLabel}"}',
                ),
              ),
          ],
          onChanged: onChanged,
        );
      },
    );
  }
}

/// Shown when shifts can't be loaded — keeps the form usable instead of
/// blocking submit on an optional dimension.
class _OptionalShiftPlaceholder extends StatelessWidget {
  final VoidCallback onRefresh;
  final String message;

  const _OptionalShiftPlaceholder({
    required this.onRefresh,
    this.message =
        'Shifts master not available yet. Items will be auto-tagged on START.',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: VistarPalette.surface2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
      ),
      child: Row(
        children: [
          Icon(Icons.access_time,
              color: DplColors.textSecondary, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: DplColors.textSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Retry'),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}

class _SupervisorDropdown extends StatelessWidget {
  final AsyncValue<DplApiResponse<List<DplSupervisor>>> supervisorsAsync;
  final int? selectedId;
  final ValueChanged<int?> onChanged;
  final VoidCallback onRefresh;

  const _SupervisorDropdown({
    required this.supervisorsAsync,
    required this.selectedId,
    required this.onChanged,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return supervisorsAsync.when(
      loading: () => _Skeleton(label: 'Loading supervisors...'),
      error: (e, _) => _InlineError(
        message: 'Could not load supervisors: $e',
        onRetry: onRefresh,
      ),
      data: (res) {
        if (res.isError) {
          return _InlineError(
            message: res.error ?? 'Failed to load supervisors.',
            onRetry: onRefresh,
          );
        }
        final list = res.data ?? const <DplSupervisor>[];

        if (list.isEmpty) {
          return _InlineError(
            icon: Icons.person_off_outlined,
            message:
                'No supervisors available on the backend yet. Ask an admin to add one.',
            onRetry: onRefresh,
            retryLabel: 'Refresh',
          );
        }

        final hasSelection =
            selectedId != null && list.any((s) => s.userId == selectedId);

        return DropdownButtonFormField<int?>(
          initialValue: hasSelection ? selectedId : null,
          decoration: const InputDecoration(
            labelText: 'Assign Supervisor',
            prefixIcon: Icon(Icons.person_outline),
          ),
          items: [
            const DropdownMenuItem<int?>(
              value: null,
              child: Text('Select supervisor'),
            ),
            for (final s in list)
              DropdownMenuItem<int?>(
                value: s.userId,
                child: Text(
                  s.name.isEmpty ? 'User #${s.userId}' : s.name,
                ),
              ),
          ],
          onChanged: onChanged,
        );
      },
    );
  }
}

class _Skeleton extends StatelessWidget {
  final String label;
  const _Skeleton({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: VistarPalette.surface2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final IconData icon;
  final String retryLabel;

  const _InlineError({
    required this.message,
    required this.onRetry,
    this.icon = Icons.error_outline,
    this.retryLabel = 'Retry',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: VistarPalette.badBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VistarPalette.badLine),
      ),
      child: Row(
        children: [
          Icon(icon, color: VistarPalette.bad),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: VistarPalette.badInk,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: Text(retryLabel)),
        ],
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final DplUploadMode mode;
  final ValueChanged<DplUploadMode> onChanged;

  const _ModeToggle({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<DplUploadMode>(
      segments: const [
        ButtonSegment(
          value: DplUploadMode.excel,
          icon: Icon(Icons.upload_file_outlined),
          label: Text('Upload Excel'),
        ),
        ButtonSegment(
          value: DplUploadMode.manual,
          icon: Icon(Icons.edit_outlined),
          label: Text('Manual Entry'),
        ),
      ],
      selected: {mode},
      onSelectionChanged: (set) => onChanged(set.first),
    );
  }
}

class _ExcelSection extends ConsumerWidget {
  final DplUploadPlanState state;
  final DplUploadPlanController ctrl;

  const _ExcelSection({required this.state, required this.ctrl});

  Future<void> _pickFile(BuildContext context, WidgetRef ref) async {
    try {
      // `withData: true` is required on web (no file path is exposed).
      // On native it loads the bytes into memory — fine for .xlsx plan
      // files which are tiny.
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final picked = result.files.first;
      final bytes = picked.bytes;

      if (bytes == null) {
        if (!context.mounted) return;
        DplSnack.error(
          context,
          'Could not read file contents. Please pick the file again.',
        );
        return;
      }

      final filename = picked.name.isEmpty ? 'plan.xlsx' : picked.name;

      if (!context.mounted) return;
      final res = await ctrl.pickAndUploadExcel(
        bytes: bytes,
        filename: filename,
      );
      if (!context.mounted) return;
      if (res.isError) {
        DplSnack.error(context, res.error ?? 'Failed to parse Excel.');
      } else {
        DplSnack.success(context, 'Preview ready.');
      }
    } catch (e) {
      if (!context.mounted) return;
      DplSnack.error(context, 'Could not open file picker: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = state.excelPreview;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed:
              state.isSubmitting ? null : () => _pickFile(context, ref),
          icon: const Icon(Icons.attach_file_outlined),
          label: Text(preview == null
              ? 'Choose .xlsx file'
              : 'Pick a different .xlsx file'),
        ),
        const SizedBox(height: 12),
        if (preview == null)
          const DplEmptyState(
            icon: Icons.description_outlined,
            title: 'No file selected',
            message:
                'Pick an .xlsx file to parse. The server will preview the plan items per machine.',
          )
        else ...[
          if (preview.warnings.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: VistarPalette.warnBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: VistarPalette.warnLine),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.warning_amber_outlined,
                          color: VistarPalette.warn),
                      SizedBox(width: 8),
                      Text(
                        'Warnings',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: VistarPalette.warn,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  for (final w in preview.warnings)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '• ${w.message}${w.row != null ? " (row ${w.row})" : ""}',
                        style: TextStyle(
                            color: VistarPalette.warnInk,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (preview.machines.isEmpty)
            DplEmptyState(
              icon: Icons.table_view_outlined,
              title: 'Excel uploaded — 0 rows parsed',
              message:
                  'The server accepted the file but extracted no plan rows. '
                  'Make sure each row has a machine, part number and plan quantity, '
                  'and that the machine names match what is in the Machines master.',
              action: OutlinedButton.icon(
                icon: const Icon(Icons.swap_horiz_outlined),
                label: const Text('Switch to Manual Entry'),
                onPressed: () => ctrl.setMode(DplUploadMode.manual),
              ),
            )
          else
            for (final section in preview.machines)
              _ExcelMachineSection(section: section, ctrl: ctrl),
        ],
      ],
    );
  }
}

class _ExcelMachineSection extends StatelessWidget {
  final DplExcelMachineSection section;
  final DplUploadPlanController ctrl;

  const _ExcelMachineSection({required this.section, required this.ctrl});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
      ),
      child: ExpansionTile(
        initiallyExpanded: true,
        shape: const RoundedRectangleBorder(side: BorderSide.none),
        title: Text(
          section.machineName.isEmpty
              ? 'Machine #${section.machineId}'
              : section.machineName,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          'Total plan: ${fmt.format(section.totalPlanQty)}  •  ${section.rows.length} rows',
          style: TextStyle(color: DplColors.textSecondary),
        ),
        children: [
          for (var i = 0; i < section.rows.length; i++)
            _ExcelRowTile(
              row: section.rows[i],
              onQtyChanged: (q) => ctrl.updateExcelRow(
                section.machineId,
                i,
                DplExcelPlanRow(
                  planNo: section.rows[i].planNo,
                  partNumber: section.rows[i].partNumber,
                  partDescription: section.rows[i].partDescription,
                  planQty: q,
                  sequence: section.rows[i].sequence,
                  partId: section.rows[i].partId,
                  warning: section.rows[i].warning,
                ),
              ),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _ExcelRowTile extends StatefulWidget {
  final DplExcelPlanRow row;
  final ValueChanged<int> onQtyChanged;

  const _ExcelRowTile({required this.row, required this.onQtyChanged});

  @override
  State<_ExcelRowTile> createState() => _ExcelRowTileState();
}

class _ExcelRowTileState extends State<_ExcelRowTile> {
  late final TextEditingController _qtyCtrl;

  @override
  void initState() {
    super.initState();
    _qtyCtrl = TextEditingController(text: widget.row.planQty.toString());
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasIssue =
        widget.row.partId == null || (widget.row.warning ?? '').isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: VistarPalette.surface3,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${widget.row.planNo}',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 11,
                color: VistarPalette.info,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.row.partNumber.isEmpty
                      ? '(no part number)'
                      : widget.row.partNumber,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (widget.row.partDescription.isNotEmpty)
                  Text(
                    widget.row.partDescription,
                    style: TextStyle(
                        color: DplColors.textSecondary, fontSize: 12),
                  ),
                if (hasIssue)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      widget.row.warning ?? 'Part not in master.',
                      style: TextStyle(
                        color: VistarPalette.warn,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 80,
            child: TextField(
              controller: _qtyCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Qty',
              ),
              onChanged: (v) {
                final qty = int.tryParse(v.trim()) ?? 0;
                widget.onQtyChanged(qty);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ManualSection extends ConsumerWidget {
  final DplUploadPlanState state;
  final DplUploadPlanController ctrl;
  final AsyncValue<DplApiResponse<List<DplMachine>>> machinesAsync;

  const _ManualSection({
    required this.state,
    required this.ctrl,
    required this.machinesAsync,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.manualDrafts.isEmpty) {
      return machinesAsync.when(
        loading: () => const SkeletonList(count: 3),
        error: (e, _) => DplErrorRetry(
          message: 'Could not load machines: $e',
          onRetry: () => ref.invalidate(dplMachinesProvider),
        ),
        data: (res) {
          if (res.isError) {
            return DplErrorRetry(
              message: res.error ?? 'Failed to load machines.',
              onRetry: () => ref.invalidate(dplMachinesProvider),
            );
          }
          return DplEmptyState(
            icon: Icons.precision_manufacturing_outlined,
            title: 'No machines configured',
            message:
                'Add machines from Settings → Machines before entering plans manually.',
            action: Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => ref.invalidate(dplMachinesProvider),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
                FilledButton.icon(
                  onPressed: () =>
                      context.push('/dpl/manager/masters/machines'),
                  icon: const Icon(Icons.add_business_outlined),
                  label: const Text('Add Machine'),
                ),
              ],
            ),
          );
        },
      );
    }

    final fmt = NumberFormat.decimalPattern();
    final grandTotal = state.manualDrafts
        .fold<int>(0, (a, d) => a + d.totalPlanQty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final d in state.manualDrafts)
          _ManualMachineCard(draft: d, ctrl: ctrl),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            'Grand total: ${fmt.format(grandTotal)}',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: VistarPalette.info,
            ),
          ),
        ),
      ],
    );
  }
}

class _ManualMachineCard extends StatelessWidget {
  final DplManualMachineDraft draft;
  final DplUploadPlanController ctrl;

  const _ManualMachineCard({required this.draft, required this.ctrl});

  Future<void> _addItem(BuildContext context) async {
    final result = await showDialog<DplProductionPlanItem>(
      context: context,
      builder: (_) => _ManualItemDialog(
        defaultPlanNo: draft.items.length + 1,
        defaultSequence: draft.items.length + 1,
        machineName: draft.machineName,
      ),
    );
    if (result == null) return;
    ctrl.addManualItem(draft.machineId, result);
  }

  Future<void> _editItem(BuildContext context, int index) async {
    final existing = draft.items[index];
    final result = await showDialog<DplProductionPlanItem>(
      context: context,
      builder: (_) => _ManualItemDialog(
        existing: existing,
        defaultPlanNo: existing.planNo,
        defaultSequence: existing.sequence,
        machineName: draft.machineName,
      ),
    );
    if (result == null) return;
    ctrl.updateManualItem(draft.machineId, index, result);
  }

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
      ),
      child: ExpansionTile(
        initiallyExpanded: true,
        shape: const RoundedRectangleBorder(side: BorderSide.none),
        title: Text(
          draft.machineName.isEmpty
              ? 'Machine #${draft.machineId}'
              : draft.machineName,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          '${draft.items.length} items  •  Total: ${fmt.format(draft.totalPlanQty)}',
          style: TextStyle(color: DplColors.textSecondary),
        ),
        children: [
          if (draft.items.isEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                'No items yet. Tap "Add item" below.',
                style: TextStyle(color: DplColors.textSecondary),
              ),
            )
          else
            for (var i = 0; i < draft.items.length; i++)
              _ManualItemRow(
                item: draft.items[i],
                onTap: () => _editItem(context, i),
                onDelete: () =>
                    ctrl.removeManualItem(draft.machineId, i),
              ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: () => _addItem(context),
                icon: const Icon(Icons.add),
                label: const Text('Add item'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ManualItemRow extends StatelessWidget {
  final DplProductionPlanItem item;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ManualItemRow({
    required this.item,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: VistarPalette.surface3,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${item.planNo}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    color: VistarPalette.info,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.partNumber.isEmpty
                                ? 'Part #${item.partId}'
                                : item.partNumber,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (item.carriedFromItemId != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: VistarPalette.okBg,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: VistarPalette.ok,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.skip_next_outlined,
                                    size: 11, color: VistarPalette.ok),
                                SizedBox(width: 3),
                                Text(
                                  'Carried',
                                  style: TextStyle(
                                    color: VistarPalette.ok,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (item.partDescription.isNotEmpty)
                      Text(
                        item.partDescription,
                        style: TextStyle(
                          color: DplColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    if ((item.remarks ?? '').isNotEmpty &&
                        item.carriedFromItemId != null)
                      Text(
                        item.remarks!,
                        style: TextStyle(
                          color: VistarPalette.ok,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              Text(
                fmt.format(item.planQty),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              IconButton(
                onPressed: onDelete,
                icon: const Icon(Icons.close, size: 18),
                tooltip: item.carriedFromItemId != null
                    ? 'Skip carry-forward'
                    : 'Remove',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManualItemDialog extends StatefulWidget {
  final DplProductionPlanItem? existing;
  final int defaultPlanNo;
  final int defaultSequence;
  /// Optional — when provided, the part autocomplete scopes its search
  /// to this machine via `?machine_name=`.
  final String? machineName;

  const _ManualItemDialog({
    required this.defaultPlanNo,
    required this.defaultSequence,
    this.existing,
    this.machineName,
  });

  @override
  State<_ManualItemDialog> createState() => _ManualItemDialogState();
}

class _ManualItemDialogState extends State<_ManualItemDialog> {
  late final TextEditingController _planNoCtrl;
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _seqCtrl;
  String? _error;
  int? _selectedPartId;
  String _selectedPartNumber = '';
  String _selectedPartDescription = '';

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _planNoCtrl = TextEditingController(
        text: (e?.planNo ?? widget.defaultPlanNo).toString());
    _qtyCtrl =
        TextEditingController(text: (e?.planQty ?? 0).toString());
    _seqCtrl = TextEditingController(
        text: (e?.sequence ?? widget.defaultSequence).toString());
    if (e != null) {
      _selectedPartId = e.partId;
      _selectedPartNumber = e.partNumber;
      _selectedPartDescription = e.partDescription;
    }
  }

  @override
  void dispose() {
    _planNoCtrl.dispose();
    _qtyCtrl.dispose();
    _seqCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final partId = _selectedPartId ?? 0;
    final planNo = int.tryParse(_planNoCtrl.text.trim()) ?? 0;
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    final seq = int.tryParse(_seqCtrl.text.trim()) ?? 0;

    if (partId <= 0) {
      setState(() => _error = 'Please select a part.');
      return;
    }
    if (planNo <= 0) {
      setState(() => _error = 'Plan number must be greater than 0.');
      return;
    }
    if (qty <= 0) {
      setState(() => _error = 'Plan qty must be greater than 0.');
      return;
    }

    Navigator.of(context).pop(DplProductionPlanItem(
      id: widget.existing?.id ?? 0,
      planNo: planNo,
      partId: partId,
      partNumber: _selectedPartNumber,
      partDescription: _selectedPartDescription,
      planQty: qty,
      sequence: seq,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add item' : 'Edit item'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null) ...[
                _ErrorBanner(message: _error!),
                const SizedBox(height: 10),
              ],
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _planNoCtrl,
                      keyboardType: TextInputType.number,
                      decoration:
                          const InputDecoration(labelText: 'Plan No'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _seqCtrl,
                      keyboardType: TextInputType.number,
                      decoration:
                          const InputDecoration(labelText: 'Sequence'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              DplPartSearchField(
                machineName: widget.machineName,
                initialPart: _selectedPartId == null
                    ? null
                    : DplPart(
                        id: _selectedPartId!,
                        partNumber: _selectedPartNumber,
                        description: _selectedPartDescription,
                      ),
                onChanged: (p) {
                  setState(() {
                    _selectedPartId = p?.id;
                    _selectedPartNumber = p?.partNumber ?? '';
                    _selectedPartDescription = p?.description ?? '';
                  });
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _qtyCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Plan Qty'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.existing == null ? 'Add' : 'Save'),
        ),
      ],
    );
  }
}
