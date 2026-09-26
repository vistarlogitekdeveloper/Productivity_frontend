import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/dpl_api_service.dart';
import '../../models/dpl_part.dart';

/// Autocomplete field that searches the parts master with a 300ms debounce.
///
/// When [machineName] is set, the search is scoped to that machine via the
/// backend's `?machine_name=` query param — improves match accuracy and
/// keeps the results list short.
class DplPartSearchField extends ConsumerStatefulWidget {
  final DplPart? initialPart;
  final ValueChanged<DplPart?> onChanged;
  final String label;
  final bool enabled;
  final String? machineName;

  const DplPartSearchField({
    super.key,
    required this.onChanged,
    this.initialPart,
    this.label = 'Description',
    this.enabled = true,
    this.machineName,
  });

  @override
  ConsumerState<DplPartSearchField> createState() => _DplPartSearchFieldState();
}

class _DplPartSearchFieldState extends ConsumerState<DplPartSearchField> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<DplPart> _results = const [];
  bool _isSearching = false;
  bool _isOpen = false;
  DplPart? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialPart;
    _ctrl.text = widget.initialPart?.displayLabel ?? '';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String query) async {
    if (!mounted) return;
    setState(() => _isSearching = true);
    final res = await ref.read(dplApiServiceProvider).getParts(
          q: query,
          machineName: widget.machineName,
          page: 1,
          limit: 20,
        );
    if (!mounted) return;
    setState(() {
      _isSearching = false;
      _results = res.isOk ? (res.data?.items ?? const []) : const [];
      _isOpen = true;
    });
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _runSearch(value);
    });
  }

  void _select(DplPart p) {
    setState(() {
      _selected = p;
      _ctrl.text = p.displayLabel;
      _isOpen = false;
      _results = const [];
    });
    widget.onChanged(p);
  }

  void _clearSelection() {
    setState(() {
      _selected = null;
      _ctrl.clear();
      _results = const [];
      _isOpen = false;
    });
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ctrl,
          enabled: widget.enabled,
          onChanged: _onChanged,
          decoration: InputDecoration(
            labelText: widget.label,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _ctrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _clearSelection,
                  ),
          ),
        ),
        if (_isOpen && (_isSearching || _results.isNotEmpty))
          Container(
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border.all(color: VistarPalette.line),
              borderRadius: BorderRadius.circular(12),
            ),
            constraints: const BoxConstraints(maxHeight: 220),
            child: _isSearching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 10),
                        Text('Searching parts...'),
                      ],
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: _results.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final p = _results[i];
                      return ListTile(
                        dense: true,
                        title: Text(
                          p.partNumber.isEmpty ? '—' : p.partNumber,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: p.description.isEmpty
                            ? null
                            : Text(
                                p.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onTap: () => _select(p),
                      );
                    },
                  ),
          ),
        if (_selected != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Selected: ${_selected!.displayLabel}',
              style: TextStyle(
                color: VistarPalette.info,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }
}
