import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_empty_state.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_logistics.dart';
import 'manager_maxion_providers.dart';

/// Parses "12, 14 15" into machine ids, ignoring anything that is not a
/// positive whole number.
List<int> dplParseMachineIds(String raw) => raw
    .split(RegExp(r'[,;\s]+'))
    .map((e) => int.tryParse(e.trim()))
    .whereType<int>()
    .where((e) => e > 0)
    .toSet()
    .toList();

/// Transporters, consignees and dispatch lanes (API.md §8.1, §9).
class DplLogisticsMastersScreen extends ConsumerWidget {
  final bool showAppBar;

  const DplLogisticsMastersScreen({super.key, this.showAppBar = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(dplPermissionsProvider).can(DplPermission.mastersEdit);
    const tabBar = TabBar(
      labelColor: DplColors.primary,
      unselectedLabelColor: DplColors.textSecondary,
      indicatorColor: DplColors.primary,
      tabs: [Tab(text: 'Transporters'), Tab(text: 'Consignees'), Tab(text: 'Lanes')],
    );
    final views = TabBarView(
      children: [
        _TransportersTab(canEdit: canEdit),
        _ConsigneesTab(canEdit: canEdit),
        _LanesTab(canEdit: canEdit),
      ],
    );

    if (!showAppBar) {
      return DefaultTabController(
        length: 3,
        child: Column(
          children: [
            const Material(color: Colors.white, child: tabBar),
            Expanded(child: views),
          ],
        ),
      );
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: DplColors.pageBg,
        appBar: const DplAppBar(
          title: 'Logistics masters',
          bottom: PreferredSize(
            preferredSize: Size.fromHeight(kTextTabBarHeight),
            child: Material(color: Colors.white, child: tabBar),
          ),
        ),
        body: views,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared list scaffolding
// ---------------------------------------------------------------------------

/// Loading / error / empty / list for one master tab, with an Add button on
/// top when the user may edit.
class _MasterList<T> extends StatelessWidget {
  final AsyncValue<DplApiResponse<List<T>>> async;
  final Future<void> Function() onRefresh;
  final bool canEdit;
  final String addLabel;
  final VoidCallback onAdd;
  final String emptyTitle;
  final Widget Function(T item) itemBuilder;
  final Widget? header;

  const _MasterList({
    required this.async,
    required this.onRefresh,
    required this.canEdit,
    required this.addLabel,
    required this.onAdd,
    required this.emptyTitle,
    required this.itemBuilder,
    this.header,
  });

  @override
  Widget build(BuildContext context) {
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => DplInlineErrorRetry(message: e.toString(), onRetry: onRefresh),
      data: (res) {
        if (res.isError) {
          return DplInlineErrorRetry(
            message: res.floorMessage.isEmpty ? 'Could not load.' : res.floorMessage,
            onRetry: onRefresh,
          );
        }
        final items = res.data ?? const [];
        return RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView(
            padding: const EdgeInsets.all(DplSpacing.md),
            children: [
              ?header,
              if (canEdit)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: DplSpacing.sm),
                    child: FilledButton.tonalIcon(
                      onPressed: onAdd,
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(addLabel),
                    ),
                  ),
                ),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: DplSpacing.xxl),
                  child: DplEmptyView(title: emptyTitle, icon: Icons.inventory_2_outlined),
                )
              else
                DplCard(
                  padding: const EdgeInsets.symmetric(vertical: DplSpacing.xs),
                  child: Column(children: [for (final i in items) itemBuilder(i)]),
                ),
            ],
          ),
        );
      },
    );
  }
}

Widget _inactiveChip() => Container(
      padding: const EdgeInsets.symmetric(horizontal: DplSpacing.sm, vertical: 2),
      decoration: BoxDecoration(color: DplColors.neutralBg, borderRadius: BorderRadius.circular(DplRadius.pill)),
      child: Text('Inactive', style: DplText.caption()),
    );

String? _nz(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

// ---------------------------------------------------------------------------
// Transporters
// ---------------------------------------------------------------------------

class _TransportersTab extends ConsumerWidget {
  final bool canEdit;

  const _TransportersTab({required this.canEdit});

  Future<void> _open(BuildContext context, WidgetRef ref, [DplTransporter? t]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _MasterDialog(
        kind: 'transporters',
        title: t == null ? 'New transporter' : 'Edit ${t.code}',
        id: t?.id,
        fields: const [
          ('code', 'Code'),
          ('name', 'Name'),
          ('gstin', 'GSTIN (optional)'),
          ('contact_name', 'Contact name (optional)'),
          ('phone', 'Phone (optional)'),
        ],
        initial: {
          'code': t?.code,
          'name': t?.name,
          'gstin': t?.gstin,
          'contact_name': t?.contactName,
          'phone': t?.phone,
        },
        isActive: t?.isActive,
      ),
    );
    if (saved == true) {
      ref.invalidate(dplTransportersProvider);
      if (context.mounted) DplSnacks.success(context, 'Transporter saved.');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _MasterList<DplTransporter>(
      async: ref.watch(dplTransportersProvider),
      onRefresh: () => ref.refresh(dplTransportersProvider.future),
      canEdit: canEdit,
      addLabel: 'Add transporter',
      onAdd: () => _open(context, ref),
      emptyTitle: 'No transporters yet',
      itemBuilder: (t) => ListTile(
        onTap: canEdit ? () => _open(context, ref, t) : null,
        leading: const Icon(Icons.local_shipping_outlined),
        title: Text(t.name),
        subtitle: Text([t.code, ?t.gstin, ?t.contactName, ?t.phone].join(' · ')),
        trailing: t.isActive ? (canEdit ? const Icon(Icons.edit_outlined, size: 18) : null) : _inactiveChip(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Consignees
// ---------------------------------------------------------------------------

class _ConsigneesTab extends ConsumerWidget {
  final bool canEdit;

  const _ConsigneesTab({required this.canEdit});

  Future<void> _open(BuildContext context, WidgetRef ref, [DplConsignee? c]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _MasterDialog(
        kind: 'consignees',
        title: c == null ? 'New consignee' : 'Edit ${c.code}',
        id: c?.id,
        fields: const [
          ('code', 'Code'),
          ('name', 'Name'),
          ('gstin', 'GSTIN (optional)'),
          ('address', 'Address (optional)'),
          ('city', 'City (optional)'),
          ('state', 'State (optional)'),
          ('pincode', 'PIN code (optional)'),
        ],
        initial: {
          'code': c?.code,
          'name': c?.name,
          'gstin': c?.gstin,
          'address': c?.address,
          'city': c?.city,
          'state': c?.state,
          'pincode': c?.pincode,
        },
        isActive: c?.isActive,
      ),
    );
    if (saved == true) {
      ref.invalidate(dplConsigneesProvider);
      if (context.mounted) DplSnacks.success(context, 'Consignee saved.');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _MasterList<DplConsignee>(
      async: ref.watch(dplConsigneesProvider),
      onRefresh: () => ref.refresh(dplConsigneesProvider.future),
      canEdit: canEdit,
      addLabel: 'Add consignee',
      onAdd: () => _open(context, ref),
      emptyTitle: 'No consignees yet',
      itemBuilder: (c) => ListTile(
        onTap: canEdit ? () => _open(context, ref, c) : null,
        leading: const Icon(Icons.factory_outlined),
        title: Text(c.name),
        subtitle: Text([c.code, ?c.city, ?c.state, if (c.gstin != null) 'GSTIN ${c.gstin}'].join(' · ')),
        trailing: c.isActive ? (canEdit ? const Icon(Icons.edit_outlined, size: 18) : null) : _inactiveChip(),
      ),
    );
  }
}

/// Add / edit dialog for a transporter or consignee. [isActive] is null for a
/// new record (the server creates it active) and shows a switch otherwise.
class _MasterDialog extends ConsumerStatefulWidget {
  final String kind;
  final String title;
  final int? id;
  final List<(String key, String label)> fields;
  final Map<String, String?> initial;
  final bool? isActive;

  const _MasterDialog({
    required this.kind,
    required this.title,
    required this.fields,
    required this.initial,
    this.id,
    this.isActive,
  });

  @override
  ConsumerState<_MasterDialog> createState() => _MasterDialogState();
}

class _MasterDialogState extends ConsumerState<_MasterDialog> {
  late final Map<String, TextEditingController> _ctrls = {
    for (final f in widget.fields) f.$1: TextEditingController(text: widget.initial[f.$1] ?? ''),
  };
  late bool _active = widget.isActive ?? true;
  bool _saving = false;
  String? _problem;

  bool get _isEdit => widget.id != null;

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final code = _ctrls['code']!.text.trim();
    final name = _ctrls['name']!.text.trim();
    if (code.isEmpty || name.isEmpty) {
      setState(() => _problem = 'Code and name are required.');
      return;
    }
    final body = <String, dynamic>{
      for (final f in widget.fields)
        if (f.$1 != 'code' || !_isEdit) f.$1: f.$1 == 'code' ? code.toUpperCase() : _nz(_ctrls[f.$1]!.text),
      if (_isEdit) 'is_active': _active,
    };
    setState(() {
      _saving = true;
      _problem = null;
    });
    final res = await ref.read(dplApiServiceProvider).saveLogisticsMaster(widget.kind, body, id: widget.id);
    if (!mounted) return;
    setState(() => _saving = false);
    if (res.isError) {
      setState(() => _problem = res.floorMessage.isEmpty ? 'Could not save.' : res.floorMessage);
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final f in widget.fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: DplSpacing.sm),
                  child: TextField(
                    controller: _ctrls[f.$1],
                    // The code is the key other records point at; it is set once.
                    enabled: !(f.$1 == 'code' && _isEdit),
                    textCapitalization: f.$1 == 'code' || f.$1 == 'gstin'
                        ? TextCapitalization.characters
                        : TextCapitalization.words,
                    keyboardType: f.$1 == 'phone' || f.$1 == 'pincode' ? TextInputType.number : null,
                    maxLines: f.$1 == 'address' ? 3 : 1,
                    decoration: InputDecoration(labelText: f.$2, isDense: true, border: const OutlineInputBorder()),
                  ),
                ),
              if (_isEdit)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  subtitle: const Text('Inactive records cannot be picked on a trip.'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
              if (_problem != null)
                Text(_problem!, style: DplText.bodySm().copyWith(color: DplColors.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Lanes
// ---------------------------------------------------------------------------

class _LanesTab extends ConsumerWidget {
  final bool canEdit;

  const _LanesTab({required this.canEdit});

  Future<void> _open(BuildContext context, WidgetRef ref, [DplLane? lane]) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => _LaneDialog(lane: lane));
    if (saved == true) {
      ref.invalidate(dplLanesProvider);
      if (context.mounted) DplSnacks.success(context, 'Lane saved.');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _MasterList<DplLane>(
      async: ref.watch(dplLanesProvider),
      onRefresh: () => ref.refresh(dplLanesProvider.future),
      canEdit: canEdit,
      addLabel: 'Add lane',
      onAdd: () => _open(context, ref),
      emptyTitle: 'No lanes of your own',
      header: Padding(
        padding: const EdgeInsets.only(bottom: DplSpacing.sm),
        child: Text(
          'A lane is a customer plant you dispatch to, with the machines that feed it. '
          'Trips are planned against a lane.',
          style: DplText.caption(),
        ),
      ),
      itemBuilder: (l) => ListTile(
        onTap: canEdit ? () => _open(context, ref, l) : null,
        leading: const Icon(Icons.alt_route),
        title: Text(l.name),
        subtitle: Text(
          l.machines.isEmpty
              ? '${l.code} · no machines'
              : '${l.code} · ${l.machines.map((m) => m.code.isEmpty ? '#${m.id}' : m.code).join(', ')}',
        ),
        trailing: l.isActive ? (canEdit ? const Icon(Icons.edit_outlined, size: 18) : null) : _inactiveChip(),
      ),
    );
  }
}

class _LaneDialog extends ConsumerStatefulWidget {
  final DplLane? lane;

  const _LaneDialog({this.lane});

  @override
  ConsumerState<_LaneDialog> createState() => _LaneDialogState();
}

class _LaneDialogState extends ConsumerState<_LaneDialog> {
  late final TextEditingController _code = TextEditingController(text: widget.lane?.code ?? '');
  late final TextEditingController _name = TextEditingController(text: widget.lane?.name ?? '');
  late final TextEditingController _machines =
      TextEditingController(text: widget.lane?.machines.map((m) => m.id).join(', ') ?? '');
  late bool _active = widget.lane?.isActive ?? true;
  bool _saving = false;
  String? _problem;

  /// Set once the server answers FIRST_OWN_LANE; the user must then tick
  /// [_confirmOwn] before the create is retried with confirm_own_lanes.
  bool _needsConfirm = false;
  bool _confirmOwn = false;
  String? _confirmMessage;

  bool get _isEdit => widget.lane != null;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _machines.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final code = _code.text.trim().toUpperCase();
    final name = _name.text.trim();
    final machineIds = dplParseMachineIds(_machines.text);
    if (name.isEmpty || (!_isEdit && code.isEmpty)) {
      setState(() => _problem = 'Code and name are required.');
      return;
    }
    setState(() {
      _saving = true;
      _problem = null;
    });
    final api = ref.read(dplApiServiceProvider);
    final res = _isEdit
        ? await api.saveLane({'name': name, 'is_active': _active, 'machine_ids': machineIds}, code: widget.lane!.code)
        : await api.saveLane({
            'code': code,
            'name': name,
            'machine_ids': machineIds,
            if (_confirmOwn) 'confirm_own_lanes': true,
          });
    if (!mounted) return;
    setState(() => _saving = false);
    if (res.isError) {
      if (res.code == 'FIRST_OWN_LANE') {
        setState(() {
          _needsConfirm = true;
          _confirmMessage = res.error;
        });
        return;
      }
      setState(() => _problem = res.floorMessage.isEmpty ? 'Could not save the lane.' : res.floorMessage);
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.lane?.machines ?? const [];
    return AlertDialog(
      title: Text(_isEdit ? 'Edit ${widget.lane!.code}' : 'New lane'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _code,
                enabled: !_isEdit,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Code',
                  hintText: 'e.g. MXN_TATA_PV',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: DplSpacing.sm),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name', isDense: true, border: OutlineInputBorder()),
              ),
              const SizedBox(height: DplSpacing.sm),
              TextField(
                controller: _machines,
                keyboardType: TextInputType.text,
                decoration: InputDecoration(
                  labelText: 'Machine ids',
                  helperText: current.isEmpty
                      ? 'Comma-separated ids of the machines that feed this lane'
                      : 'Now: ${current.map((m) => '${m.id} = ${m.code.isEmpty ? m.name : m.code}').join(', ')}',
                  helperMaxLines: 3,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_isEdit)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
              if (_needsConfirm) ...[
                const SizedBox(height: DplSpacing.md),
                Container(
                  padding: const EdgeInsets.all(DplSpacing.md),
                  decoration: BoxDecoration(
                    color: DplColors.warningBg,
                    borderRadius: BorderRadius.circular(DplRadius.md),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('This is your first lane of your own', style: DplText.body().copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: DplSpacing.xs),
                      Text(
                        _confirmMessage ??
                            'Once it exists, your trip screens show only your own lanes instead of the shared list.',
                        style: DplText.bodySm(),
                      ),
                      const SizedBox(height: DplSpacing.xs),
                      Text(
                        'Every trip from now on must be planned against one of your lanes, so add all of them.',
                        style: DplText.bodySm(),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _confirmOwn,
                        onChanged: (v) => setState(() => _confirmOwn = v ?? false),
                        title: const Text('Yes, switch to our own lanes'),
                      ),
                    ],
                  ),
                ),
              ],
              if (_problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: DplSpacing.sm),
                  child: Text(_problem!, style: DplText.bodySm().copyWith(color: DplColors.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: _saving || (_needsConfirm && !_confirmOwn) ? null : _save,
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_needsConfirm ? 'Create lane' : 'Save'),
        ),
      ],
    );
  }
}
