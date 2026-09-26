import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/vistar_palette.dart';
import '../../../core/design/dpl_theme.dart';
import '../../../core/dpl_api_response.dart';
import '../../../core/dpl_api_service.dart';
import '../../../core/widgets/dpl_app_bar.dart';
import '../../../core/widgets/dpl_empty_state.dart';
import '../../../core/widgets/dpl_error_retry.dart';
import '../../../core/widgets/dpl_snack.dart';
import '../../../models/dpl_location.dart';

/// Search term for the locations master list.
///
/// A hand-written Notifier rather than StateProvider: Riverpod 3 dropped the
/// latter, and every DPL provider in this codebase is written without codegen.
final _locationSearchProvider =
    NotifierProvider.autoDispose<_LocationSearchController, String>(
  _LocationSearchController.new,
);

class _LocationSearchController extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

/// The master list, including retired rows — this is the only screen that
/// should see them, so QA is never offered a location that is out of use.
final _locationsProvider =
    FutureProvider.autoDispose<DplApiResponse<List<DplLocation>>>((ref) async {
  final q = ref.watch(_locationSearchProvider);
  return ref.watch(dplApiServiceProvider).getLocations(
        q: q,
        limit: 200,
        includeInactive: true,
        asManager: true,
      );
});

/// Storage locations master — the list QA's picker reads from.
///
/// Capacity is maintained here and nowhere else. Each row shows how full it is
/// right now, because a capacity you cannot see against current occupancy is a
/// number nobody can act on.
class DplLocationsMasterScreen extends ConsumerStatefulWidget {
  const DplLocationsMasterScreen({super.key});

  @override
  ConsumerState<DplLocationsMasterScreen> createState() =>
      _DplLocationsMasterScreenState();
}

class _DplLocationsMasterScreenState
    extends ConsumerState<DplLocationsMasterScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) ref.read(_locationSearchProvider.notifier).set(v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_locationsProvider);

    return Scaffold(
      appBar: const DplAppBar(title: 'Masters — Storage Locations'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('Add Location'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: 'Search code, name or zone',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: _onSearch,
            ),
          ),
          Expanded(
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => DplInlineErrorRetry(
                message: e.toString(),
                onRetry: () => ref.invalidate(_locationsProvider),
              ),
              data: (res) {
                if (res.isError) {
                  return DplInlineErrorRetry(
                    message: res.error ?? 'Failed to load locations.',
                    onRetry: () => ref.invalidate(_locationsProvider),
                  );
                }
                final rows = res.data ?? const <DplLocation>[];
                if (rows.isEmpty) {
                  return const DplEmptyView(
                    title: 'No storage locations yet',
                    message:
                        'Add the racks and floor positions finished goods are '
                        'stored at. QA picks from this list, and the capacity '
                        'you set here is what stops a location being over-filled.',
                    icon: Icons.warehouse_outlined,
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 96),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _LocationTile(
                    location: rows[i],
                    onEdit: () => _edit(rows[i]),
                    onDelete: () => _delete(rows[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(DplLocation? existing) async {
    final result = await showDialog<DplLocation>(
      context: context,
      builder: (_) => _LocationDialog(existing: existing),
    );
    if (result == null || !mounted) return;

    final svc = ref.read(dplApiServiceProvider);
    final res = existing == null
        ? await svc.createLocation(result)
        : await svc.updateLocation(existing.id, result);
    if (!mounted) return;

    if (res.isError) {
      // DUPLICATE_CODE and CAPACITY_BELOW_USED both carry a message that
      // already names the conflict, so surface it as-is.
      DplSnacks.error(context, res.error ?? 'Failed to save the location.');
      return;
    }
    DplSnacks.success(
      context,
      existing == null ? 'Location added.' : 'Location updated.',
    );
    ref.invalidate(_locationsProvider);
  }

  Future<void> _delete(DplLocation location) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${location.code}?'),
        content: const Text(
          'The location is retired, not deleted — anything historically stored '
          'there keeps pointing at it. QA will no longer be offered it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final res = await ref.read(dplApiServiceProvider).deleteLocation(location.id);
    if (!mounted) return;
    if (res.isError) {
      // LOCATION_NOT_EMPTY names how much stock is still on it.
      DplSnacks.error(context, res.error ?? 'Failed to remove the location.');
      return;
    }
    DplSnacks.success(context, 'Location removed.');
    ref.invalidate(_locationsProvider);
  }
}

class _LocationTile extends StatelessWidget {
  final DplLocation location;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _LocationTile({
    required this.location,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final full = location.isFull;

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    location.code,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                ),
                if (!location.isActive)
                  Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Text(
                      'Retired',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: DplColors.textTertiary,
                      ),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: onEdit,
                  tooltip: 'Edit',
                ),
              ],
            ),
            if (location.name.isNotEmpty || location.zone.isNotEmpty)
              Text(
                [
                  if (location.name.isNotEmpty) location.name,
                  if (location.zone.isNotEmpty) 'Zone ${location.zone}',
                ].join(' · '),
                style: TextStyle(color: DplColors.textSecondary, fontSize: 12),
              ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: location.fillRatio,
                minHeight: 6,
                backgroundColor: VistarPalette.surface3,
                valueColor: AlwaysStoppedAnimation(
                  full ? VistarPalette.bad : VistarPalette.ok,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${location.usedQty} / ${location.capacityQty} used · '
              '${location.freeQty} free',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: full ? VistarPalette.bad : DplColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationDialog extends StatefulWidget {
  final DplLocation? existing;

  const _LocationDialog({this.existing});

  @override
  State<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends State<_LocationDialog> {
  late final TextEditingController _codeCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _zoneCtrl;
  late final TextEditingController _capacityCtrl;
  bool _isActive = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _codeCtrl = TextEditingController(text: e?.code ?? '');
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _zoneCtrl = TextEditingController(text: e?.zone ?? '');
    _capacityCtrl =
        TextEditingController(text: e == null ? '' : '${e.capacityQty}');
    _isActive = e?.isActive ?? true;
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    _zoneCtrl.dispose();
    _capacityCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Location code is required.');
      return;
    }
    final capacity = int.tryParse(_capacityCtrl.text.trim());
    if (capacity == null || capacity < 1) {
      setState(() => _error = 'Capacity must be a whole number of 1 or more.');
      return;
    }
    Navigator.of(context).pop(DplLocation(
      id: widget.existing?.id ?? 0,
      code: code,
      name: _nameCtrl.text.trim(),
      zone: _zoneCtrl.text.trim(),
      capacityQty: capacity,
      isActive: _isActive,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final used = widget.existing?.usedQty ?? 0;

    return AlertDialog(
      title: Text(widget.existing == null ? 'Add Location' : 'Edit Location'),
      content: SizedBox(
        width: 420,
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
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Location Code',
                  hintText: 'FG-A-03',
                  helperText: 'What is painted on the rack. Must be unique.',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Name (optional)',
                  hintText: 'Finished goods rack A, level 3',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _zoneCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Zone (optional)',
                  hintText: 'FG, or HB for half-pallet bays',
                  // The zone is not decoration. Putaway reads it to decide
                  // where to send a pallet, and a plant that leaves it blank
                  // gets no suggestion at all — which looks like a broken
                  // feature rather than missing master data. Saying so here is
                  // the only place the connection is visible.
                  helperText:
                      'Putaway uses this. A zone containing HALF or HB is '
                      'treated as half-pallet bays, so half pallets are sent '
                      'there and kept together instead of scattering through '
                      'the main racks.',
                  helperMaxLines: 4,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _capacityCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Capacity (pieces)',
                  prefixIcon: const Icon(Icons.inventory_2_outlined),
                  helperText: used > 0
                      ? 'Cannot be set below the $used pieces currently stored here.'
                      : 'How many pieces this location holds. QA cannot store '
                          'more than this.',
                  helperMaxLines: 3,
                ),
              ),
              if (widget.existing != null)
                SwitchListTile.adaptive(
                  value: _isActive,
                  onChanged: (v) => setState(() => _isActive = v),
                  title: const Text('Active'),
                  subtitle: const Text('Inactive locations are hidden from QA'),
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
