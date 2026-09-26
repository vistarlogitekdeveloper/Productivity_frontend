import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/dpl_api_service.dart';
import '../../models/dpl_location.dart';

/// Searchable location picker.
///
/// Searches the master server-side with a 300 ms debounce (code, name and zone,
/// case-insensitively) rather than filtering a list held on the client — the
/// location master is the manager's to grow and a warehouse outgrows a
/// dropdown quickly.
///
/// Every row shows remaining room against capacity, and a location without
/// enough space for [requiredQty] is shown but not selectable. Hiding it would
/// leave the operator hunting for a rack that is simply full; showing it
/// greyed with "needs N, has M" tells them to pick another.
class LocationPickerSheet extends ConsumerStatefulWidget {
  /// Pieces about to be stored. Drives the "not enough room" state.
  final int requiredQty;

  /// Pre-selected location, when changing an existing assignment.
  final int? selectedLocationId;

  /// Read the master through the WAREHOUSE router rather than the QA one.
  ///
  /// Same list either way; different door. The QA router is role-locked to
  /// dpl_qa / dpl_supervisor / dpl_manager before any permission is consulted,
  /// so a putaway operator holding `pallet.putaway` but none of those roles is
  /// refused by /qa/locations — the picker would open empty with a 403 and
  /// look like the location master had been wiped.
  final bool fromWarehouse;

  const LocationPickerSheet({
    super.key,
    required this.requiredQty,
    this.selectedLocationId,
    this.fromWarehouse = false,
  });

  /// Returns the chosen location, or null if dismissed.
  static Future<DplLocation?> show(
    BuildContext context, {
    required int requiredQty,
    int? selectedLocationId,
    bool fromWarehouse = false,
  }) {
    return showModalBottomSheet<DplLocation>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => LocationPickerSheet(
        requiredQty: requiredQty,
        selectedLocationId: selectedLocationId,
        fromWarehouse: fromWarehouse,
      ),
    );
  }

  @override
  ConsumerState<LocationPickerSheet> createState() =>
      _LocationPickerSheetState();
}

class _LocationPickerSheetState extends ConsumerState<LocationPickerSheet> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  List<DplLocation> _results = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
  }

  Future<void> _search(String q) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    final res = await ref.read(dplApiServiceProvider).getLocations(
          q: q,
          limit: 50,
          asWarehouse: widget.fromWarehouse,
        );
    if (!mounted) return;

    setState(() {
      _loading = false;
      if (res.isError) {
        _error = res.error ?? 'Failed to load locations.';
        _results = const [];
      } else {
        _results = res.data ?? const [];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Choose a storage location',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Storing ${widget.requiredQty} piece'
                    '${widget.requiredQty == 1 ? '' : 's'}. Locations without '
                    'enough room cannot be selected.',
                    style: TextStyle(
                      color: VistarPalette.txt2,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: 'Search code, name or zone',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear_rounded),
                          onPressed: () {
                            _searchCtrl.clear();
                            _onQueryChanged('');
                            setState(() {});
                          },
                        ),
                ),
                onChanged: (v) {
                  _onQueryChanged(v);
                  setState(() {}); // repaint the clear button
                },
              ),
            ),
            const SizedBox(height: 8),
            Flexible(child: _body()),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: VistarPalette.bad),
            const SizedBox(height: 8),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: VistarPalette.bad),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () => _search(_searchCtrl.text),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, color: VistarPalette.txt3, size: 34),
            const SizedBox(height: 10),
            Text(
              _searchCtrl.text.trim().isEmpty
                  ? 'No storage locations yet. Ask the DPL Manager to add them '
                      'in Masters → Storage Locations.'
                  : 'No location matches "${_searchCtrl.text.trim()}".',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: VistarPalette.txt2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final loc = _results[i];
        final fits = loc.freeQty >= widget.requiredQty;
        final isCurrent = loc.id == widget.selectedLocationId;

        return ListTile(
          enabled: fits || isCurrent,
          selected: isCurrent,
          title: Row(
            children: [
              Expanded(
                child: Text(
                  loc.displayLabel,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isCurrent)
                Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Text(
                    'Current',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: VistarPalette.infoInk,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: loc.fillRatio,
                  minHeight: 5,
                  backgroundColor: VistarPalette.surface3,
                  valueColor: AlwaysStoppedAnimation(
                    loc.isFull
                        ? VistarPalette.bad
                        : (fits
                            ? VistarPalette.ok
                            : VistarPalette.warn),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                fits || isCurrent
                    ? '${loc.usedQty} / ${loc.capacityQty} used · '
                        '${loc.freeQty} free'
                        '${loc.zone.isEmpty ? '' : ' · ${loc.zone}'}'
                    : 'Needs ${widget.requiredQty}, only ${loc.freeQty} free',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: fits || isCurrent
                      ? VistarPalette.txt2
                      : VistarPalette.warn,
                ),
              ),
            ],
          ),
          trailing: fits || isCurrent
              ? const Icon(Icons.chevron_right_rounded)
              : Icon(Icons.block_rounded,
                  size: 18, color: VistarPalette.warn),
          onTap: (fits || isCurrent)
              ? () => Navigator.of(context).pop(loc)
              : null,
        );
      },
    );
  }
}
