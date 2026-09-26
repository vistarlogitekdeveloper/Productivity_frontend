import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/vistar_palette.dart';
import '../../../../../core/widgets/shimmer_skeleton.dart';
import '../../../core/design/dpl_theme.dart';
import '../../../core/dpl_api_service.dart';
import '../../../core/dpl_constants.dart';
import '../../../core/widgets/dpl_app_bar.dart';
import '../../../models/dpl_downtime_reason.dart';
import '../../providers/dpl_masters_provider.dart';
import '../../widgets/dpl_manager_footer.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_retry.dart';

class DplDowntimeReasonsMasterScreen extends ConsumerWidget {
  const DplDowntimeReasonsMasterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncList = ref.watch(dplDowntimeReasonsProvider);

    return Scaffold(
      appBar: const DplAppBar(title: 'Downtime Reasons'),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(dplDowntimeReasonsProvider);
          await ref.read(dplDowntimeReasonsProvider.future);
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
                onRetry: () => ref.invalidate(dplDowntimeReasonsProvider),
              ),
            ],
          ),
          data: (res) {
            if (res.isError) {
              return ListView(
                children: [
                  DplErrorRetry(
                    message: res.error ?? 'Failed to load reasons.',
                    onRetry: () =>
                        ref.invalidate(dplDowntimeReasonsProvider),
                  ),
                ],
              );
            }
            final items = res.data ?? const <DplDowntimeReason>[];
            if (items.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 60),
                  DplEmptyState(
                    icon: Icons.report_outlined,
                    title: 'No downtime reasons yet',
                    message:
                        'Add reasons such as "Tool change" or "Power failure".',
                  ),
                ],
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _ReasonCard(
                reason: items[i],
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
        label: const Text('Add Reason'),
      ),
      bottomNavigationBar: const DplManagerFooter(),
    );
  }

  Future<void> _showCreate(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<DplDowntimeReason>(
      context: context,
      builder: (_) => const _ReasonDialog(),
    );
    if (result == null) return;
    final res =
        await ref.read(dplApiServiceProvider).createDowntimeReason(result);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to create reason.');
      return;
    }
    DplSnack.success(context, 'Reason created.');
    ref.invalidate(dplDowntimeReasonsProvider);
  }

  Future<void> _showEdit(
    BuildContext context,
    WidgetRef ref,
    DplDowntimeReason existing,
  ) async {
    final result = await showDialog<DplDowntimeReason>(
      context: context,
      builder: (_) => _ReasonDialog(existing: existing),
    );
    if (result == null) return;
    final res = await ref
        .read(dplApiServiceProvider)
        .updateDowntimeReason(existing.id, result);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to update reason.');
      return;
    }
    DplSnack.success(context, 'Reason updated.');
    ref.invalidate(dplDowntimeReasonsProvider);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    DplDowntimeReason reason,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Reason?'),
        content: Text('Delete reason "${reason.code} — ${reason.name}"?'),
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
        .deleteDowntimeReason(reason.id);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to delete reason.');
      return;
    }
    DplSnack.success(context, 'Reason deleted.');
    ref.invalidate(dplDowntimeReasonsProvider);
  }
}

class _ReasonCard extends StatelessWidget {
  final DplDowntimeReason reason;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ReasonCard({
    required this.reason,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isPlanned = reason.category == DplDowntimeCategory.planned;
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${reason.code} — ${reason.name}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isPlanned
                    ? VistarPalette.infoBg
                    : VistarPalette.warnBg,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                DplDowntimeCategory.label(reason.category),
                style: TextStyle(
                  color: isPlanned
                      ? VistarPalette.info
                      : VistarPalette.warn,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: onDelete,
              color: VistarPalette.bad,
            ),
          ],
        ),
      ),
    );
  }
}

class _ReasonDialog extends StatefulWidget {
  final DplDowntimeReason? existing;
  const _ReasonDialog({this.existing});

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  late final TextEditingController _codeCtrl;
  late final TextEditingController _nameCtrl;
  String _category = DplDowntimeCategory.unplanned;
  bool _isActive = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _codeCtrl = TextEditingController(text: e?.code ?? '');
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _category = e?.category ?? DplDowntimeCategory.unplanned;
    _isActive = e?.isActive ?? true;
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
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
    Navigator.of(context).pop(DplDowntimeReason(
      id: widget.existing?.id ?? 0,
      code: _codeCtrl.text.trim(),
      name: _nameCtrl.text.trim(),
      category: _category,
      isActive: _isActive,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Add Downtime Reason' : 'Edit Reason',
      ),
      content: SizedBox(
        width: 440,
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
            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'Category'),
              items: DplDowntimeCategory.all
                  .map((c) => DropdownMenuItem(
                        value: c,
                        child: Text(DplDowntimeCategory.label(c)),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() => _category = v);
              },
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
