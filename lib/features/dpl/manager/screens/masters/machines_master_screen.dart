import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/vistar_palette.dart';
import '../../../../../core/widgets/shimmer_skeleton.dart';
import '../../../core/design/dpl_theme.dart';
import '../../../core/dpl_api_service.dart';
import '../../../core/widgets/dpl_app_bar.dart';
import '../../../core/widgets/dpl_refresh_icon_button.dart';
import '../../../models/dpl_machine.dart';
import '../../providers/dpl_masters_provider.dart';
import '../../widgets/dpl_manager_footer.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_retry.dart';

class DplMachinesMasterScreen extends ConsumerWidget {
  const DplMachinesMasterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncList = ref.watch(dplMachinesProvider);

    return Scaffold(
      appBar: DplAppBar(
        title: 'Machines',
        actions: [
          DplRefreshIconButton(
            onRefresh: () async {
              ref.invalidate(dplMachinesProvider);
              try {
                await ref.read(dplMachinesProvider.future);
              } catch (_) {}
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(dplMachinesProvider);
          await ref.read(dplMachinesProvider.future);
        },
        child: asyncList.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: SkeletonList(count: 4),
          ),
          error: (e, _) => ListView(
            children: [
              DplErrorRetry(
                message: e.toString(),
                onRetry: () => ref.invalidate(dplMachinesProvider),
              ),
            ],
          ),
          data: (res) {
            if (res.isError) {
              return ListView(
                children: [
                  DplErrorRetry(
                    message: res.error ?? 'Failed to load machines.',
                    onRetry: () => ref.invalidate(dplMachinesProvider),
                  ),
                ],
              );
            }
            final items = res.data ?? const <DplMachine>[];
            if (items.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 60),
                  DplEmptyState(
                    icon: Icons.precision_manufacturing_outlined,
                    title: 'No machines yet',
                    message: 'Tap the + button to add your first machine.',
                  ),
                ],
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _MachineCard(
                machine: items[i],
                onEdit: () => _showEditDialog(context, ref, items[i]),
                onDelete: () => _confirmDelete(context, ref, items[i]),
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add Machine'),
      ),
      bottomNavigationBar: const DplManagerFooter(),
    );
  }

  Future<void> _showCreateDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final result = await showDialog<DplMachine>(
      context: context,
      builder: (_) => const _MachineDialog(),
    );
    if (result == null) return;
    final res = await ref.read(dplApiServiceProvider).createMachine(result);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to create machine.');
      return;
    }
    DplSnack.success(context, 'Machine created.');
    ref.invalidate(dplMachinesProvider);
  }

  Future<void> _showEditDialog(
    BuildContext context,
    WidgetRef ref,
    DplMachine existing,
  ) async {
    final result = await showDialog<DplMachine>(
      context: context,
      builder: (_) => _MachineDialog(existing: existing),
    );
    if (result == null) return;
    final res = await ref
        .read(dplApiServiceProvider)
        .updateMachine(existing.id, result);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to update machine.');
      return;
    }
    DplSnack.success(context, 'Machine updated.');
    ref.invalidate(dplMachinesProvider);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    DplMachine machine,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Machine?'),
        content: Text(
          'Delete machine "${machine.code} — ${machine.name}"?',
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
    final res = await ref
        .read(dplApiServiceProvider)
        .deleteMachine(machine.id);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to delete machine.');
      return;
    }
    DplSnack.success(context, 'Machine deleted.');
    ref.invalidate(dplMachinesProvider);
  }
}

class _MachineCard extends StatelessWidget {
  final DplMachine machine;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _MachineCard({
    required this.machine,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey('machine-${machine.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        onDelete();
        return false; // we let the snackbar/refresh handle it
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: VistarPalette.badBg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(Icons.delete, color: VistarPalette.bad),
      ),
      child: InkWell(
        onTap: onEdit,
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${machine.code} — ${machine.name}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (machine.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          machine.description,
                          style:
                              TextStyle(color: DplColors.textSecondary),
                        ),
                      ),
                  ],
                ),
              ),
              if (!machine.isActive)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
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
            ],
          ),
        ),
      ),
    );
  }
}

class _MachineDialog extends StatefulWidget {
  final DplMachine? existing;
  const _MachineDialog({this.existing});

  @override
  State<_MachineDialog> createState() => _MachineDialogState();
}

class _MachineDialogState extends State<_MachineDialog> {
  late final TextEditingController _codeCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  bool _isActive = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _codeCtrl = TextEditingController(text: e?.code ?? '');
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _descCtrl = TextEditingController(text: e?.description ?? '');
    _isActive = e?.isActive ?? true;
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
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

    Navigator.of(context).pop(DplMachine(
      id: widget.existing?.id ?? 0,
      code: _codeCtrl.text.trim(),
      name: _nameCtrl.text.trim(),
      description: _descCtrl.text.trim(),
      isActive: _isActive,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add Machine' : 'Edit Machine'),
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
              TextField(
                controller: _codeCtrl,
                decoration: const InputDecoration(labelText: 'Code'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _descCtrl,
                decoration: const InputDecoration(labelText: 'Description'),
                maxLines: 2,
              ),
              const SizedBox(height: 4),
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
