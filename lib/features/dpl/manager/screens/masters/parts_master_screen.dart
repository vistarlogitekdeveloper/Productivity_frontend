import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/widgets/shimmer_skeleton.dart';
import '../../../core/dpl_api_service.dart';
import '../../../core/widgets/dpl_app_bar.dart';
import '../../../models/dpl_part.dart';
import '../../providers/dpl_masters_provider.dart';
import '../../widgets/dpl_manager_footer.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_retry.dart';

class DplPartsMasterScreen extends ConsumerStatefulWidget {
  const DplPartsMasterScreen({super.key});

  @override
  ConsumerState<DplPartsMasterScreen> createState() =>
      _DplPartsMasterScreenState();
}

class _DplPartsMasterScreenState extends ConsumerState<DplPartsMasterScreen> {
  final _scrollCtrl = ScrollController();
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 200) {
      ref.read(dplPartsControllerProvider.notifier).loadMore();
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      ref.read(dplPartsControllerProvider.notifier).setQuery(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(dplPartsControllerProvider);

    return Scaffold(
      appBar: const DplAppBar(title: 'Description'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search part number / description',
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          ref
                              .read(dplPartsControllerProvider.notifier)
                              .setQuery('');
                          setState(() {});
                        },
                      ),
              ),
            ),
          ),
          const _MachineFilterBar(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () =>
                  ref.read(dplPartsControllerProvider.notifier).refresh(),
              child: asyncState.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: SkeletonList(count: 6),
                ),
                error: (e, _) => ListView(
                  children: [
                    DplErrorRetry(
                      message: e.toString(),
                      onRetry: () => ref
                          .read(dplPartsControllerProvider.notifier)
                          .refresh(),
                    ),
                  ],
                ),
                data: (state) {
                  if (state.error != null && state.items.isEmpty) {
                    return ListView(
                      children: [
                        DplErrorRetry(
                          message: state.error!,
                          onRetry: () => ref
                              .read(dplPartsControllerProvider.notifier)
                              .refresh(),
                        ),
                      ],
                    );
                  }
                  if (state.items.isEmpty) {
                    return ListView(
                      children: const [
                        SizedBox(height: 60),
                        DplEmptyState(
                          icon: Icons.inventory_2_outlined,
                          title: 'No Description found',
                          message: 'Try a different search or add a new description.',
                        ),
                      ],
                    );
                  }
                  return ListView.separated(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: state.items.length +
                        (state.isLoadingMore ? 1 : 0),
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      if (i >= state.items.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            ),
                          ),
                        );
                      }
                      final p = state.items[i];
                      return _PartCard(
                        part: p,
                        onEdit: () => _showEditDialog(context, ref, p),
                        onDelete: () => _confirmDelete(context, ref, p),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add Part'),
      ),
      bottomNavigationBar: const DplManagerFooter(),
    );
  }

  Future<void> _showCreateDialog(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<DplPart>(
      context: context,
      builder: (_) => const _PartDialog(),
    );
    if (result == null) return;
    final res = await ref.read(dplApiServiceProvider).createPart(result);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to create part.');
      return;
    }
    DplSnack.success(context, 'Part created.');
    ref.read(dplPartsControllerProvider.notifier).refresh();
  }

  Future<void> _showEditDialog(
    BuildContext context,
    WidgetRef ref,
    DplPart existing,
  ) async {
    final result = await showDialog<DplPart>(
      context: context,
      builder: (_) => _PartDialog(existing: existing),
    );
    if (result == null) return;
    final res =
        await ref.read(dplApiServiceProvider).updatePart(existing.id, result);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to update part.');
      return;
    }
    DplSnack.success(context, 'Part updated.');
    ref.read(dplPartsControllerProvider.notifier).refresh();
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    DplPart part,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Part?'),
        content: Text('Delete part "${part.displayLabel}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB3261E),
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final res = await ref.read(dplApiServiceProvider).deletePart(part.id);
    if (!context.mounted) return;
    if (res.isError) {
      DplSnack.error(context, res.error ?? 'Failed to delete part.');
      return;
    }
    DplSnack.success(context, 'Part deleted.');
    ref.read(dplPartsControllerProvider.notifier).refresh();
  }
}

class _MachineFilterBar extends ConsumerWidget {
  const _MachineFilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machinesAsync = ref.watch(dplMachinesProvider);
    final partsState = ref.watch(dplPartsControllerProvider).asData?.value;
    final activeMachineName = partsState?.machineName;

    return machinesAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (res) {
        if (res.isError) return const SizedBox.shrink();
        final machines = res.data ?? const [];
        if (machines.isEmpty) return const SizedBox.shrink();

        return SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _MachineChip(
                label: 'All machines',
                selected: activeMachineName == null,
                onTap: () => ref
                    .read(dplPartsControllerProvider.notifier)
                    .setMachineName(null),
              ),
              const SizedBox(width: 6),
              for (final m in machines) ...[
                _MachineChip(
                  label: m.name,
                  selected: activeMachineName == m.name,
                  onTap: () => ref
                      .read(dplPartsControllerProvider.notifier)
                      .setMachineName(m.name),
                ),
                const SizedBox(width: 6),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _MachineChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _MachineChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _PartCard extends StatelessWidget {
  final DplPart part;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _PartCard({
    required this.part,
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
          border: Border.all(color: const Color(0xFFE2EAF6)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    part.partNumber.isEmpty ? '—' : part.partNumber,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  if (part.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        part.description,
                        style: const TextStyle(color: Color(0xFF5D6A7A)),
                      ),
                    ),
                  // Surfaced on the row because it is the key QA scans on. A
                  // part with no substrate cannot be reached by a scan at all,
                  // so "—" here is an actionable gap, not decoration.
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.inventory_2_outlined,
                          size: 13,
                          color: Color(0xFF94A3B8),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            part.substratePartNo.isEmpty
                                ? 'No substrate mapped'
                                : part.substratePartNo,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: part.substratePartNo.isEmpty
                                  ? const Color(0xFFB45309)
                                  : const Color(0xFF475569),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (!part.isActive)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  'Inactive',
                  style: TextStyle(
                    color: Color(0xFF5D6A7A),
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: onDelete,
              color: const Color(0xFFB3261E),
            ),
          ],
        ),
      ),
    );
  }
}

class _PartDialog extends ConsumerStatefulWidget {
  final DplPart? existing;
  const _PartDialog({this.existing});

  @override
  ConsumerState<_PartDialog> createState() => _PartDialogState();
}

class _PartDialogState extends ConsumerState<_PartDialog> {
  late final TextEditingController _pnCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _substrateCtrl;
  late final TextEditingController _materialCtrl;
  String? _machineName;
  bool _isActive = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _pnCtrl = TextEditingController(text: e?.partNumber ?? '');
    _descCtrl = TextEditingController(text: e?.description ?? '');
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _substrateCtrl = TextEditingController(text: e?.substratePartNo ?? '');
    _materialCtrl = TextEditingController(text: e?.materialCode ?? '');
    _machineName = (e?.machineName ?? '').isEmpty ? null : e!.machineName;
    _isActive = e?.isActive ?? true;
  }

  @override
  void dispose() {
    _pnCtrl.dispose();
    _descCtrl.dispose();
    _nameCtrl.dispose();
    _substrateCtrl.dispose();
    _materialCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_pnCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Part number is required.');
      return;
    }
    if (_descCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Description is required.');
      return;
    }
    if ((_machineName ?? '').isEmpty) {
      setState(() => _error = 'Machine is required.');
      return;
    }
    Navigator.of(context).pop(DplPart(
      id: widget.existing?.id ?? 0,
      partNumber: _pnCtrl.text.trim(),
      description: _descCtrl.text.trim(),
      name: _nameCtrl.text.trim(),
      // The backend has accepted substrate_part_no since migration 019; this
      // form simply never offered it, which is why no part could be reached by
      // a QA scan until now. `toJsonForWrite()` sends both of these even when
      // blank, so clearing a wrong mapping actually clears it.
      substratePartNo: _substrateCtrl.text.trim(),
      materialCode: _materialCtrl.text.trim(),
      machineName: _machineName!.trim(),
      isActive: _isActive,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final machinesAsync = ref.watch(dplMachinesProvider);
    final machines = machinesAsync.asData?.value.data ?? const [];
    final loadingMachines = machinesAsync.isLoading;

    // If the part's stored machine isn't in the active list (e.g. it
    // was deactivated), keep it visible so the user doesn't lose the
    // existing selection on edit.
    final names = <String>{
      for (final m in machines) m.name,
      if (_machineName != null && _machineName!.isNotEmpty) _machineName!,
    }.toList()
      ..sort();

    return AlertDialog(
      title: Text(widget.existing == null ? 'Add Part' : 'Edit Part'),
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
                    color: const Color(0xFFFFECEA),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFFFB4AA)),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Color(0xFF8F1D18),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                controller: _pnCtrl,
                decoration: const InputDecoration(labelText: 'Part Number'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _descCtrl,
                decoration: const InputDecoration(labelText: 'Description'),
                maxLines: 2,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Display Name (optional)',
                ),
              ),
              const SizedBox(height: 10),
              // The substrate is what QA scans off the raw-material label, and
              // it is what maps that scan back to this customer part. One
              // substrate legitimately serves several customer parts (e.g.
              // 195872440-083 is both 542469500120D1 and 546769500133D1) —
              // QA gets a picker when that happens, so entering the same
              // substrate on more than one part here is correct, not a mistake.
              TextField(
                controller: _substrateCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Substrate Part No.',
                  hintText: '195245450-083',
                  prefixIcon: Icon(Icons.inventory_2_outlined),
                  helperText:
                      'Printed on the raw-material label. QA scans this to '
                      'find the customer part.',
                  helperMaxLines: 3,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _materialCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Material Code (optional)',
                  hintText: '587136190-083',
                  prefixIcon: Icon(Icons.science_outlined),
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _machineName,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Machine',
                  prefixIcon: const Icon(Icons.precision_manufacturing_outlined),
                  helperText: loadingMachines
                      ? 'Loading machines…'
                      : 'Required by the backend (machine_name).',
                ),
                items: [
                  for (final n in names)
                    DropdownMenuItem<String>(value: n, child: Text(n)),
                ],
                onChanged: loadingMachines
                    ? null
                    : (v) => setState(() => _machineName = v),
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
