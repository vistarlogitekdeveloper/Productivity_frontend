import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/vistar_palette.dart';
import '../../../../../core/widgets/shimmer_skeleton.dart';
import '../../../core/design/dpl_theme.dart';
import '../../../core/dpl_api_service.dart';
import '../../../core/widgets/dpl_app_bar.dart';
import '../../../core/widgets/dpl_refresh_icon_button.dart';
import '../../../models/dpl_shift.dart';
import '../../providers/dpl_shifts_provider.dart';
import '../../widgets/dpl_manager_footer.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_retry.dart';

class DplShiftsMasterScreen extends ConsumerWidget {
  const DplShiftsMasterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dplShiftsIncludeInactiveProvider);

    return Scaffold(
      appBar: DplAppBar(
        title: 'Shifts',
        actions: [
          DplRefreshIconButton(
            onRefresh: () async {
              ref.invalidate(dplShiftsIncludeInactiveProvider);
              try {
                await ref.read(dplShiftsIncludeInactiveProvider.future);
              } catch (_) {}
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(dplShiftsIncludeInactiveProvider);
          await ref.read(dplShiftsIncludeInactiveProvider.future);
        },
        child: async.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: SkeletonList(count: 3),
          ),
          error: (e, _) => ListView(
            children: [
              DplErrorRetry(
                message: e.toString(),
                onRetry: () =>
                    ref.invalidate(dplShiftsIncludeInactiveProvider),
              ),
            ],
          ),
          data: (res) {
            if (res.isError) {
              return ListView(
                children: [
                  DplErrorRetry(
                    message: res.error ?? 'Failed to load shifts.',
                    onRetry: () =>
                        ref.invalidate(dplShiftsIncludeInactiveProvider),
                  ),
                ],
              );
            }
            final items = res.data ?? const <DplShift>[];
            if (items.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 60),
                  DplEmptyState(
                    icon: Icons.access_time,
                    title: 'No shifts configured',
                    message:
                        'Add Shift A / B / C with their start–end windows.',
                  ),
                ],
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _ShiftCard(
                shift: items[i],
                onEdit: () => _showEdit(context, ref, items[i]),
                onDelete: () => _confirmDelete(context, ref, items[i]),
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreate(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add Shift'),
      ),
      bottomNavigationBar: const DplManagerFooter(),
    );
  }

  Future<void> _showCreate(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<DplShift>(
      context: context,
      builder: (_) => const _ShiftDialog(),
    );
    if (result == null) return;
    final res = await ref.read(dplApiServiceProvider).createShift(result);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to create shift.');
      return;
    }
    DplSnack.success(context, 'Shift created.');
    ref.invalidate(dplShiftsIncludeInactiveProvider);
    ref.invalidate(dplShiftsProvider);
  }

  Future<void> _showEdit(
    BuildContext context,
    WidgetRef ref,
    DplShift existing,
  ) async {
    final result = await showDialog<DplShift>(
      context: context,
      builder: (_) => _ShiftDialog(existing: existing),
    );
    if (result == null) return;
    final res = await ref
        .read(dplApiServiceProvider)
        .updateShift(existing.id, result);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to update shift.');
      return;
    }
    DplSnack.success(context, 'Shift updated.');
    ref.invalidate(dplShiftsIncludeInactiveProvider);
    ref.invalidate(dplShiftsProvider);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    DplShift shift,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Shift?'),
        content: Text('Soft-delete shift "${shift.code} — ${shift.name}"?'),
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
    final res = await ref.read(dplApiServiceProvider).deleteShift(shift.id);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to delete shift.');
      return;
    }
    DplSnack.success(context, 'Shift deleted.');
    ref.invalidate(dplShiftsIncludeInactiveProvider);
    ref.invalidate(dplShiftsProvider);
  }
}

class _ShiftCard extends StatelessWidget {
  final DplShift shift;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ShiftCard({
    required this.shift,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
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
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: VistarPalette.surface3,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                shift.code.isEmpty ? '?' : shift.code,
                style: TextStyle(
                  color: VistarPalette.info,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shift.name.isEmpty ? 'Shift ${shift.code}' : shift.name,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  if (shift.windowLabel.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        shift.windowLabel,
                        style: TextStyle(
                          color: DplColors.textSecondary,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (!shift.isActive)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: VistarPalette.surface3,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'Inactive',
                  style: TextStyle(
                    fontSize: 11,
                    color: DplColors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
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

class _ShiftDialog extends StatefulWidget {
  final DplShift? existing;
  const _ShiftDialog({this.existing});

  @override
  State<_ShiftDialog> createState() => _ShiftDialogState();
}

class _ShiftDialogState extends State<_ShiftDialog> {
  late final TextEditingController _codeCtrl;
  late final TextEditingController _nameCtrl;
  TimeOfDay? _start;
  TimeOfDay? _end;
  bool _isActive = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _codeCtrl = TextEditingController(text: e?.code ?? '');
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _start = _parseTime(e?.startTime);
    _end = _parseTime(e?.endTime);
    _isActive = e?.isActive ?? true;
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  TimeOfDay? _parseTime(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final parts = raw.trim().split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    return TimeOfDay(hour: h, minute: m);
  }

  String _formatTime(TimeOfDay t) {
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm:00';
  }

  Future<void> _pickStart() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _start ?? const TimeOfDay(hour: 6, minute: 0),
    );
    if (picked != null) setState(() => _start = picked);
  }

  Future<void> _pickEnd() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _end ?? const TimeOfDay(hour: 14, minute: 0),
    );
    if (picked != null) setState(() => _end = picked);
  }

  void _submit() {
    if (_codeCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Code is required.');
      return;
    }
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Name is required.');
      return;
    }
    if (_start == null || _end == null) {
      setState(() => _error = 'Start and end time are required.');
      return;
    }
    Navigator.of(context).pop(DplShift(
      id: widget.existing?.id ?? 0,
      code: _codeCtrl.text.trim().toUpperCase(),
      name: _nameCtrl.text.trim(),
      startTime: _formatTime(_start!),
      endTime: _formatTime(_end!),
      isActive: _isActive,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final startLabel = _start == null ? 'Pick start' : _start!.format(context);
    final endLabel = _end == null ? 'Pick end' : _end!.format(context);
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add Shift' : 'Edit Shift'),
      content: SizedBox(
        width: 420,
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
            TextField(
              controller: _codeCtrl,
              decoration:
                  const InputDecoration(labelText: 'Code (A, B, C, ...)'),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickStart,
                    icon: const Icon(Icons.schedule),
                    label: Text('Start: $startLabel'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickEnd,
                    icon: const Icon(Icons.schedule_outlined),
                    label: Text('End: $endLabel'),
                  ),
                ),
              ],
            ),
            if (widget.existing != null)
              SwitchListTile.adaptive(
                value: _isActive,
                onChanged: (v) => setState(() => _isActive = v),
                title: const Text('Active'),
                contentPadding: EdgeInsets.zero,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.existing == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}
