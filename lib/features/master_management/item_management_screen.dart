import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/vistar_palette.dart';
import '../../core/widgets/shimmer_skeleton.dart';
import '../../data/models/master_data_models.dart';
import 'master_management_repository.dart';

class ItemManagementScreen extends ConsumerStatefulWidget {
  const ItemManagementScreen({super.key});

  @override
  ConsumerState<ItemManagementScreen> createState() => _ItemManagementScreenState();
}

class _ItemManagementScreenState extends ConsumerState<ItemManagementScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  bool _isLoading = true;
  bool _isSubmitting = false;
  String _query = '';
  String? _error;
  List<ItemModel> _items = const [];

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadItems);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  MasterManagementRepository get _repo => ref.read(masterManagementRepositoryProvider);

  String _cleanError(Object error) {
    final raw = error.toString();
    const prefix = 'Exception:';
    if (raw.startsWith(prefix)) return raw.substring(prefix.length).trim();
    return raw;
  }

  Future<void> _loadItems() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final items = await _repo.listItems();
      if (!mounted) return;
      setState(() {
        _items = items;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = _cleanError(e);
      });
    }
  }

  Future<void> _withSubmitting(Future<void> Function() action) async {
    setState(() => _isSubmitting = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  List<ItemModel> get _filteredItems {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _items;
    return _items.where((i) {
      return i.itemCode.toLowerCase().contains(q) ||
          i.description.toLowerCase().contains(q) ||
          i.finishWeightG.toString().contains(q);
    }).toList();
  }

  Future<void> _createItem() async {
    final payload = await showDialog<_ItemCreatePayload>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ItemCreateDialog(),
    );
    if (payload == null) return;

    try {
      await _withSubmitting(() async {
        await _repo.createItem(
          itemCode: payload.itemCode,
          description: payload.description,
          finishWeight: payload.finishWeight,
        );
        await _loadItems();
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Item created successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_cleanError(e))),
      );
    }
  }

  Future<void> _editItem(ItemModel item) async {
    final payload = await showDialog<_ItemEditPayload>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ItemEditDialog(item: item),
    );
    if (payload == null) return;

    final codeChanged = payload.itemCode != item.itemCode;
    final descChanged = payload.description != item.description;
    final weightChanged = payload.finishWeight != item.finishWeightG;
    if (!codeChanged && !descChanged && !weightChanged) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No changes detected.')),
      );
      return;
    }

    try {
      await _withSubmitting(() async {
        await _repo.updateItem(
          id: item.id,
          itemCode: codeChanged ? payload.itemCode : null,
          description: descChanged ? payload.description : null,
          finishWeight: weightChanged ? payload.finishWeight : null,
        );
        await _loadItems();
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Item updated successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_cleanError(e))),
      );
    }
  }

  Future<void> _deleteItem(ItemModel item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Item'),
        content: Text('Delete item "${item.itemCode}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: VistarPalette.badSolid),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _withSubmitting(() async {
        await _repo.deleteItem(item.id);
        await _loadItems();
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Item deleted successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_cleanError(e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredItems;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Item Management'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loadItems,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Create Item',
            onPressed: _createItem,
            icon: const Icon(Icons.inventory_2_outlined),
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [VistarPalette.bg, VistarPalette.bg2, VistarPalette.bg],
          ),
        ),
        child: RefreshIndicator(
          onRefresh: _loadItems,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search item code, description, finish weight',
                ),
              ),
              const SizedBox(height: 12),
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: VistarPalette.badBg,
                    borderRadius: BorderRadius.circular(14),
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
                const SizedBox(height: 12),
              ],
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SkeletonList(count: 4),
                )
              else if (filtered.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: VistarPalette.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: VistarPalette.line),
                  ),
                  child: Text(
                    'No items found.',
                    style: TextStyle(color: VistarPalette.txt2),
                  ),
                )
              else
                ...filtered.map(
                  (i) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _ItemCard(
                      item: i,
                      onEdit: () => _editItem(i),
                      onDelete: () => _deleteItem(i),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createItem,
        label: const Text('Create Item'),
        icon: const Icon(Icons.inventory_2_outlined),
      ),
      bottomNavigationBar:
          _isSubmitting ? const ShimmerLinearBar(height: 2) : null,
    );
  }
}

class _ItemCard extends StatelessWidget {
  final ItemModel item;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ItemCard({
    required this.item,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VistarPalette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${item.itemCode} | ${item.description}',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            'Finish Weight: ${item.finishWeightG.toStringAsFixed(2)}',
            style: TextStyle(color: VistarPalette.txt2),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _ItemActionChip(
                icon: Icons.edit_outlined,
                label: 'Edit',
                color: VistarPalette.ok,
                onTap: onEdit,
              ),
              _ItemActionChip(
                icon: Icons.delete_outline,
                label: 'Delete',
                color: VistarPalette.bad,
                onTap: onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ItemActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ItemActionChip({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemCreatePayload {
  final String itemCode;
  final String description;
  final double finishWeight;

  const _ItemCreatePayload({
    required this.itemCode,
    required this.description,
    required this.finishWeight,
  });
}

class _ItemCreateDialog extends StatefulWidget {
  const _ItemCreateDialog();

  @override
  State<_ItemCreateDialog> createState() => _ItemCreateDialogState();
}

class _ItemCreateDialogState extends State<_ItemCreateDialog> {
  final _formKey = GlobalKey<FormState>();
  final _itemCodeCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  final _finishWeightCtrl = TextEditingController();

  @override
  void dispose() {
    _itemCodeCtrl.dispose();
    _descriptionCtrl.dispose();
    _finishWeightCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      _ItemCreatePayload(
        itemCode: _itemCodeCtrl.text.trim(),
        description: _descriptionCtrl.text.trim(),
        finishWeight: double.parse(_finishWeightCtrl.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Item'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _itemCodeCtrl,
                decoration: const InputDecoration(labelText: 'Item Code'),
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return 'Item Code is required.';
                  return null;
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _descriptionCtrl,
                decoration: const InputDecoration(labelText: 'Description'),
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return 'Description is required.';
                  return null;
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _finishWeightCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Finish Weight'),
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return 'Finish Weight is required.';
                  final weight = double.tryParse(value);
                  if (weight == null || weight <= 0) return 'Enter a valid finish weight.';
                  return null;
                },
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
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _ItemEditPayload {
  final String itemCode;
  final String description;
  final double finishWeight;

  const _ItemEditPayload({
    required this.itemCode,
    required this.description,
    required this.finishWeight,
  });
}

class _ItemEditDialog extends StatefulWidget {
  final ItemModel item;

  const _ItemEditDialog({required this.item});

  @override
  State<_ItemEditDialog> createState() => _ItemEditDialogState();
}

class _ItemEditDialogState extends State<_ItemEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _itemCodeCtrl;
  late final TextEditingController _descriptionCtrl;
  late final TextEditingController _finishWeightCtrl;

  @override
  void initState() {
    super.initState();
    _itemCodeCtrl = TextEditingController(text: widget.item.itemCode);
    _descriptionCtrl = TextEditingController(text: widget.item.description);
    _finishWeightCtrl = TextEditingController(
      text: widget.item.finishWeightG.toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _itemCodeCtrl.dispose();
    _descriptionCtrl.dispose();
    _finishWeightCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      _ItemEditPayload(
        itemCode: _itemCodeCtrl.text.trim(),
        description: _descriptionCtrl.text.trim(),
        finishWeight: double.parse(_finishWeightCtrl.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Item'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _itemCodeCtrl,
                decoration: const InputDecoration(labelText: 'Item Code'),
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return 'Item Code is required.';
                  return null;
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _descriptionCtrl,
                decoration: const InputDecoration(labelText: 'Description'),
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return 'Description is required.';
                  return null;
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _finishWeightCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Finish Weight'),
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return 'Finish Weight is required.';
                  final weight = double.tryParse(value);
                  if (weight == null || weight <= 0) return 'Enter a valid finish weight.';
                  return null;
                },
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
          child: const Text('Apply Changes'),
        ),
      ],
    );
  }
}
