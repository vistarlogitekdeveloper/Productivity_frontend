import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/vistar_palette.dart';
import '../../core/widgets/shimmer_skeleton.dart';
import '../../data/models/master_data_models.dart';
import 'master_management_repository.dart';

class MachineManagementScreen extends ConsumerStatefulWidget {
  const MachineManagementScreen({super.key});

  @override
  ConsumerState<MachineManagementScreen> createState() => _MachineManagementScreenState();
}

class _MachineManagementScreenState extends ConsumerState<MachineManagementScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  bool _isLoading = true;
  bool _isSubmitting = false;
  String _query = '';
  String? _error;
  List<MachineModel> _machines = const [];

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadMachines);
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

  Future<void> _loadMachines() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final machines = await _repo.listMachines();
      if (!mounted) return;
      setState(() {
        _machines = machines;
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

  List<MachineModel> get _filteredMachines {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _machines;
    return _machines.where((m) {
      return m.machineNumber.toLowerCase().contains(q) ||
          m.name.toLowerCase().contains(q) ||
          m.status.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _createMachine() async {
    final payload = await showDialog<_MachineCreatePayload>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _MachineCreateDialog(),
    );
    if (payload == null) return;

    try {
      await _withSubmitting(() async {
        await _repo.createMachine(
          machineNumber: payload.machineNumber,
          name: payload.name,
        );
        await _loadMachines();
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Machine created successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_cleanError(e))),
      );
    }
  }

  Future<void> _editMachine(MachineModel machine) async {
    final payload = await showDialog<_MachineEditPayload>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MachineEditDialog(machine: machine),
    );
    if (payload == null) return;

    if (payload.name == machine.name && payload.status == machine.status) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No changes detected.')),
      );
      return;
    }

    try {
      await _withSubmitting(() async {
        await _repo.updateMachine(
          id: machine.id,
          name: payload.name != machine.name ? payload.name : null,
          status: payload.status != machine.status ? payload.status : null,
        );
        await _loadMachines();
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Machine updated successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_cleanError(e))),
      );
    }
  }

  Future<void> _deleteMachine(MachineModel machine) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Machine'),
        content: Text(
          'Delete machine "${machine.machineNumber} - ${machine.name}"?',
        ),
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
        await _repo.deleteMachine(machine.id);
        await _loadMachines();
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Machine deleted successfully.')),
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
    final filtered = _filteredMachines;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Machine Management'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loadMachines,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Create Machine',
            onPressed: _createMachine,
            icon: const Icon(Icons.add_business_outlined),
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
          onRefresh: _loadMachines,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search machine number, name, status',
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
                    'No machines found.',
                    style: TextStyle(color: VistarPalette.txt2),
                  ),
                )
              else
                ...filtered.map(
                  (m) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _MachineCard(
                      machine: m,
                      onEdit: () => _editMachine(m),
                      onDelete: () => _deleteMachine(m),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createMachine,
        label: const Text('Create Machine'),
        icon: const Icon(Icons.add_business_outlined),
      ),
      bottomNavigationBar:
          _isSubmitting ? const ShimmerLinearBar(height: 2) : null,
    );
  }
}

class _MachineCard extends StatelessWidget {
  final MachineModel machine;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _MachineCard({
    required this.machine,
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
            '${machine.machineNumber} | ${machine.name}',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            'Status: ${machine.status.isEmpty ? '-' : machine.status}',
            style: TextStyle(color: VistarPalette.txt2),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _MasterActionChip(
                icon: Icons.edit_outlined,
                label: 'Edit',
                color: VistarPalette.ok,
                onTap: onEdit,
              ),
              _MasterActionChip(
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

class _MasterActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _MasterActionChip({
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

class _MachineCreatePayload {
  final String machineNumber;
  final String name;

  const _MachineCreatePayload({
    required this.machineNumber,
    required this.name,
  });
}

class _MachineCreateDialog extends StatefulWidget {
  const _MachineCreateDialog();

  @override
  State<_MachineCreateDialog> createState() => _MachineCreateDialogState();
}

class _MachineCreateDialogState extends State<_MachineCreateDialog> {
  final _formKey = GlobalKey<FormState>();
  final _numberCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  @override
  void dispose() {
    _numberCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      _MachineCreatePayload(
        machineNumber: _numberCtrl.text.trim(),
        name: _nameCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Machine'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _numberCtrl,
                decoration: const InputDecoration(labelText: 'Machine Number'),
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return 'Machine Number is required.';
                  return null;
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: 'Machine Name'),
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return 'Machine Name is required.';
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

class _MachineEditPayload {
  final String name;
  final String status;

  const _MachineEditPayload({
    required this.name,
    required this.status,
  });
}

class _MachineEditDialog extends StatefulWidget {
  final MachineModel machine;

  const _MachineEditDialog({required this.machine});

  @override
  State<_MachineEditDialog> createState() => _MachineEditDialogState();
}

class _MachineEditDialogState extends State<_MachineEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late String _status;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.machine.name);
    final existing = widget.machine.status.trim().toUpperCase();
    const allowed = {'ACTIVE', 'INACTIVE', 'MAINTENANCE'};
    _status = allowed.contains(existing) ? existing : 'ACTIVE';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      _MachineEditPayload(
        name: _nameCtrl.text.trim(),
        status: _status.trim().toUpperCase(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Machine'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: widget.machine.machineNumber,
                enabled: false,
                decoration: const InputDecoration(labelText: 'Machine Number'),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: 'Machine Name'),
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return 'Machine Name is required.';
                  return null;
                },
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: const [
                  DropdownMenuItem(value: 'ACTIVE', child: Text('ACTIVE')),
                  DropdownMenuItem(value: 'INACTIVE', child: Text('INACTIVE')),
                  DropdownMenuItem(value: 'MAINTENANCE', child: Text('MAINTENANCE')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _status = value);
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
