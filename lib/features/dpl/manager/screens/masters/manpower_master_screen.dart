import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../../core/theme/vistar_palette.dart';
import '../../../../../core/widgets/shimmer_skeleton.dart';
import '../../../core/design/dpl_theme.dart';
import '../../../core/dpl_api_service.dart';
import '../../../core/widgets/dpl_app_bar.dart';
import '../../../core/widgets/dpl_refresh_icon_button.dart';
import '../../../models/dpl_manpower_log.dart';
import '../../../models/dpl_machine.dart';
import '../../../models/dpl_shift.dart';
import '../../providers/dpl_manpower_provider.dart';
import '../../providers/dpl_masters_provider.dart';
import '../../providers/dpl_shifts_provider.dart';
import '../../widgets/dpl_manager_footer.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_retry.dart';

class DplManpowerMasterScreen extends ConsumerWidget {
  const DplManpowerMasterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dplManpowerProvider);
    final filters = ref.watch(dplManpowerFiltersProvider);
    final dateFmt = DateFormat('dd MMM');

    final filterChips = <Widget>[
      if (filters.from != null || filters.to != null)
        InputChip(
          label: Text(_rangeLabel(filters.from, filters.to, dateFmt)),
          onDeleted: () => ref
              .read(dplManpowerFiltersProvider.notifier)
              .update(filters.copyWith(from: null, to: null)),
        ),
      if (filters.shiftId != null)
        InputChip(
          label: Text('Shift #${filters.shiftId}'),
          onDeleted: () => ref
              .read(dplManpowerFiltersProvider.notifier)
              .update(filters.copyWith(shiftId: null)),
        ),
      if (filters.machineId != null)
        InputChip(
          label: Text('Machine #${filters.machineId}'),
          onDeleted: () => ref
              .read(dplManpowerFiltersProvider.notifier)
              .update(filters.copyWith(machineId: null)),
        ),
    ];

    return Scaffold(
      appBar: DplAppBar(
        title: 'Manpower',
        actions: [
          IconButton(
            tooltip: 'Filter',
            icon: const Icon(Icons.filter_alt_outlined),
            onPressed: () => _openFilterSheet(context, ref),
          ),
          DplRefreshIconButton(
            onRefresh: () async {
              ref.invalidate(dplManpowerProvider);
              try {
                await ref.read(dplManpowerProvider.future);
              } catch (_) {}
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (filterChips.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Wrap(spacing: 6, runSpacing: 6, children: filterChips),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(dplManpowerProvider);
                await ref.read(dplManpowerProvider.future);
              },
              child: async.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: SkeletonList(count: 4),
                ),
                error: (e, _) => ListView(
                  children: [
                    DplErrorRetry(
                      message: e.toString(),
                      onRetry: () => ref.invalidate(dplManpowerProvider),
                    ),
                  ],
                ),
                data: (res) {
                  if (res.isError) {
                    return ListView(
                      children: [
                        DplErrorRetry(
                          message:
                              res.error ?? 'Failed to load manpower.',
                          onRetry: () =>
                              ref.invalidate(dplManpowerProvider),
                        ),
                      ],
                    );
                  }
                  final items = res.data ?? const <DplManpowerLog>[];
                  if (items.isEmpty) {
                    return ListView(
                      children: const [
                        SizedBox(height: 60),
                        DplEmptyState(
                          icon: Icons.groups_outlined,
                          title: 'No manpower entries',
                          message:
                              'Record per-shift headcount so the chart can '
                              'compute work-hours and lost-hours.',
                        ),
                      ],
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _ManpowerCard(
                      entry: items[i],
                      onEdit: () => _showEdit(context, ref, items[i]),
                      onDelete: () =>
                          _confirmDelete(context, ref, items[i]),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreate(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add Entry'),
      ),
      bottomNavigationBar: const DplManagerFooter(),
    );
  }

  String _rangeLabel(DateTime? from, DateTime? to, DateFormat fmt) {
    if (from != null && to != null) {
      return '${fmt.format(from)} – ${fmt.format(to)}';
    }
    if (from != null) return 'From ${fmt.format(from)}';
    if (to != null) return 'Until ${fmt.format(to)}';
    return '';
  }

  Future<void> _openFilterSheet(BuildContext context, WidgetRef ref) async {
    final filters = ref.read(dplManpowerFiltersProvider);
    final shiftsAsync = ref.read(dplShiftsProvider);
    final machinesAsync = ref.read(dplMachinesProvider);

    DateTime? from = filters.from;
    DateTime? to = filters.to;
    int? shiftId = filters.shiftId;
    int? machineId = filters.machineId;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) {
        return StatefulBuilder(builder: (ctx, setSheet) {
          Future<void> pickDate(bool isFrom) async {
            final picked = await showDatePicker(
              context: ctx,
              initialDate: (isFrom ? from : to) ?? DateTime.now(),
              firstDate: DateTime(2000),
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
                const Text(
                  'Filter Manpower',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => pickDate(true),
                        icon: const Icon(Icons.date_range_outlined),
                        label: Text(
                          from == null
                              ? 'From'
                              : DateFormat('dd MMM').format(from!),
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
                              : DateFormat('dd MMM').format(to!),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                shiftsAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (res) {
                    if (res.isError) return const SizedBox.shrink();
                    final shifts = res.data ?? const <DplShift>[];
                    return DropdownButtonFormField<int?>(
                      initialValue: shiftId,
                      decoration:
                          const InputDecoration(labelText: 'Shift'),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('All shifts'),
                        ),
                        ...shifts.map(
                          (s) => DropdownMenuItem<int?>(
                            value: s.id,
                            child: Text(
                              s.name.isEmpty
                                  ? 'Shift ${s.code}'
                                  : s.name,
                            ),
                          ),
                        ),
                      ],
                      onChanged: (v) => setSheet(() => shiftId = v),
                    );
                  },
                ),
                const SizedBox(height: 12),
                machinesAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (res) {
                    if (res.isError) return const SizedBox.shrink();
                    final ms = res.data ?? const <DplMachine>[];
                    return DropdownButtonFormField<int?>(
                      initialValue: machineId,
                      decoration:
                          const InputDecoration(labelText: 'Machine'),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('All machines (incl. shift-wide)'),
                        ),
                        ...ms.map(
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
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          ref
                              .read(dplManpowerFiltersProvider.notifier)
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
                              .read(dplManpowerFiltersProvider.notifier)
                              .update(DplManpowerFilters(
                                from: from,
                                to: to,
                                shiftId: shiftId,
                                machineId: machineId,
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

  Future<void> _showCreate(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<DplManpowerLog>(
      context: context,
      builder: (_) => const _ManpowerDialog(),
    );
    if (result == null) return;
    final res =
        await ref.read(dplApiServiceProvider).createManpower(result);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(
        context,
        res.error ?? 'Failed to create manpower entry.',
      );
      return;
    }
    DplSnack.success(context, 'Manpower saved.');
    ref.invalidate(dplManpowerProvider);
  }

  Future<void> _showEdit(
    BuildContext context,
    WidgetRef ref,
    DplManpowerLog existing,
  ) async {
    final result = await showDialog<DplManpowerLog>(
      context: context,
      builder: (_) => _ManpowerDialog(existing: existing),
    );
    if (result == null) return;
    // PUT only accepts headcount changes; if other fields changed,
    // best to delete + recreate. Keep it simple — only push headcount.
    final res = await ref
        .read(dplApiServiceProvider)
        .updateManpower(existing.id, result.headcount);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to update.');
      return;
    }
    DplSnack.success(context, 'Headcount updated.');
    ref.invalidate(dplManpowerProvider);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    DplManpowerLog entry,
  ) async {
    final dateLabel = DateFormat('dd MMM yyyy').format(entry.date);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Manpower Entry?'),
        content: Text(
          'Delete entry for $dateLabel — '
          '${entry.shiftName.isEmpty ? "Shift #${entry.shiftId}" : entry.shiftName}'
          '${entry.machineName.isEmpty ? "" : " — ${entry.machineName}"}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: VistarPalette.badSolid,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final res =
        await ref.read(dplApiServiceProvider).deleteManpower(entry.id);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to delete.');
      return;
    }
    DplSnack.success(context, 'Deleted.');
    ref.invalidate(dplManpowerProvider);
  }
}

class _ManpowerCard extends StatelessWidget {
  final DplManpowerLog entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ManpowerCard({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final dateLabel = DateFormat('dd MMM yyyy (EEE)').format(entry.date);
    final shiftLabel = entry.shiftName.isEmpty
        ? (entry.shiftCode.isEmpty
            ? 'Shift #${entry.shiftId}'
            : 'Shift ${entry.shiftCode}')
        : entry.shiftName;
    final machineLabel = entry.machineId == null
        ? 'Shift-wide'
        : (entry.machineName.isEmpty
            ? 'Machine #${entry.machineId}'
            : entry.machineName);

    return InkWell(
      onTap: onEdit,
      onLongPress: onDelete,
      borderRadius: BorderRadius.circular(14),
      child: Ink(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: DplColors.divider),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: VistarPalette.surface3,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${entry.headcount}',
                style: TextStyle(
                  color: VistarPalette.info,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    dateLabel,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$shiftLabel  •  $machineLabel',
                    style: TextStyle(
                      color: DplColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              color: VistarPalette.bad,
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _ManpowerDialog extends ConsumerStatefulWidget {
  final DplManpowerLog? existing;
  const _ManpowerDialog({this.existing});

  @override
  ConsumerState<_ManpowerDialog> createState() => _ManpowerDialogState();
}

class _ManpowerDialogState extends ConsumerState<_ManpowerDialog> {
  late DateTime _date;
  int? _shiftId;
  int? _machineId; // null = shift-wide
  late final TextEditingController _headcountCtrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _date = e?.date ?? DateTime.now();
    _shiftId = e?.shiftId;
    _machineId = e?.machineId;
    _headcountCtrl =
        TextEditingController(text: (e?.headcount ?? 0).toString());
  }

  @override
  void dispose() {
    _headcountCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _submit() {
    final hc = int.tryParse(_headcountCtrl.text.trim()) ?? 0;
    if (_shiftId == null) {
      setState(() => _error = 'Shift is required.');
      return;
    }
    if (hc <= 0) {
      setState(() => _error = 'Headcount must be greater than 0.');
      return;
    }
    Navigator.of(context).pop(DplManpowerLog(
      id: widget.existing?.id ?? 0,
      date: _date,
      shiftId: _shiftId!,
      machineId: _machineId,
      headcount: hc,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final shiftsAsync = ref.watch(dplShiftsProvider);
    final machinesAsync = ref.watch(dplMachinesProvider);

    return AlertDialog(
      title: Text(isEdit ? 'Edit Headcount' : 'Add Manpower'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: VistarPalette.badBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: VistarPalette.badLine),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: VistarPalette.badInk,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (!isEdit) ...[
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: Text(
                    'Date: ${DateFormat('dd MMM yyyy').format(_date)}',
                  ),
                ),
                const SizedBox(height: 10),
                shiftsAsync.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (_, _) => const Text('Failed to load shifts'),
                  data: (res) {
                    if (res.isError) {
                      return Text(
                        res.error ?? 'Failed to load shifts',
                        style: TextStyle(color: VistarPalette.bad),
                      );
                    }
                    final shifts = res.data ?? const <DplShift>[];
                    return DropdownButtonFormField<int>(
                      initialValue: _shiftId,
                      decoration:
                          const InputDecoration(labelText: 'Shift'),
                      items: shifts
                          .map((s) => DropdownMenuItem<int>(
                                value: s.id,
                                child: Text(
                                  s.name.isEmpty
                                      ? 'Shift ${s.code}'
                                      : s.name,
                                ),
                              ))
                          .toList(),
                      onChanged: (v) => setState(() => _shiftId = v),
                    );
                  },
                ),
                const SizedBox(height: 10),
                machinesAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (res) {
                    if (res.isError) return const SizedBox.shrink();
                    final ms = res.data ?? const <DplMachine>[];
                    return DropdownButtonFormField<int?>(
                      initialValue: _machineId,
                      decoration: const InputDecoration(
                        labelText: 'Machine (optional)',
                        helperText: 'Leave empty for shift-wide headcount',
                      ),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('Shift-wide (no specific machine)'),
                        ),
                        ...ms.map(
                          (m) => DropdownMenuItem<int?>(
                            value: m.id,
                            child: Text(m.name),
                          ),
                        ),
                      ],
                      onChanged: (v) => setState(() => _machineId = v),
                    );
                  },
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                controller: _headcountCtrl,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Headcount'),
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
          child: Text(isEdit ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}
