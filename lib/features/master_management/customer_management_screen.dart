import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/vistar_palette.dart';
import '../../core/widgets/shimmer_skeleton.dart';
import '../../data/models/master_data_models.dart';
import 'master_management_repository.dart';

class CustomerManagementScreen extends ConsumerStatefulWidget {
  const CustomerManagementScreen({super.key});

  @override
  ConsumerState<CustomerManagementScreen> createState() => _CustomerManagementScreenState();
}

class _CustomerManagementScreenState extends ConsumerState<CustomerManagementScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  bool _isLoading = true;
  bool _isSubmitting = false;
  String _query = '';
  String? _error;
  List<CustomerModel> _customers = const [];

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadCustomers);
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

  Future<void> _loadCustomers() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final customers = await _repo.listCustomers();
      if (!mounted) return;
      setState(() {
        _customers = customers;
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

  List<CustomerModel> get _filteredCustomers {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _customers;
    return _customers.where((c) => c.name.toLowerCase().contains(q)).toList();
  }

  Future<void> _createCustomer() async {
    final customerName = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CustomerNameDialog(title: 'Create Customer'),
    );
    if (customerName == null) return;

    try {
      await _withSubmitting(() async {
        await _repo.createCustomer(customerName: customerName);
        await _loadCustomers();
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Customer created successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_cleanError(e))),
      );
    }
  }

  Future<void> _editCustomer(CustomerModel customer) async {
    final updatedName = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CustomerNameDialog(
        title: 'Edit Customer',
        initialValue: customer.name,
      ),
    );
    if (updatedName == null) return;

    if (updatedName == customer.name) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No changes detected.')),
      );
      return;
    }

    try {
      await _withSubmitting(() async {
        await _repo.updateCustomer(id: customer.id, customerName: updatedName);
        await _loadCustomers();
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Customer updated successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_cleanError(e))),
      );
    }
  }

  Future<void> _deleteCustomer(CustomerModel customer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Customer'),
        content: Text('Delete customer "${customer.name}"?'),
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
        await _repo.deleteCustomer(customer.id);
        await _loadCustomers();
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Customer deleted successfully.')),
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
    final filtered = _filteredCustomers;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Customer Management'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loadCustomers,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Create Customer',
            onPressed: _createCustomer,
            icon: const Icon(Icons.person_add_alt_1_outlined),
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
          onRefresh: _loadCustomers,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search customer name',
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
                    'No customers found.',
                    style: TextStyle(color: VistarPalette.txt2),
                  ),
                )
              else
                ...filtered.map(
                  (c) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _CustomerCard(
                      customer: c,
                      onEdit: () => _editCustomer(c),
                      onDelete: () => _deleteCustomer(c),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createCustomer,
        label: const Text('Create Customer'),
        icon: const Icon(Icons.person_add_alt_1_outlined),
      ),
      bottomNavigationBar:
          _isSubmitting ? const ShimmerLinearBar(height: 2) : null,
    );
  }
}

class _CustomerCard extends StatelessWidget {
  final CustomerModel customer;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _CustomerCard({
    required this.customer,
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
            customer.name,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _CustomerActionChip(
                icon: Icons.edit_outlined,
                label: 'Edit',
                color: VistarPalette.ok,
                onTap: onEdit,
              ),
              _CustomerActionChip(
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

class _CustomerActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _CustomerActionChip({
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

class _CustomerNameDialog extends StatefulWidget {
  final String title;
  final String initialValue;

  const _CustomerNameDialog({
    required this.title,
    this.initialValue = '',
  });

  @override
  State<_CustomerNameDialog> createState() => _CustomerNameDialogState();
}

class _CustomerNameDialogState extends State<_CustomerNameDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(_nameCtrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _formKey,
          child: TextFormField(
            controller: _nameCtrl,
            decoration: const InputDecoration(labelText: 'Customer Name'),
            validator: (v) {
              final value = (v ?? '').trim();
              if (value.isEmpty) return 'Customer Name is required.';
              if (value.length < 2) return 'Name must be at least 2 characters.';
              return null;
            },
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
          child: const Text('Save'),
        ),
      ],
    );
  }
}
