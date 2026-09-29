import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../models/dpl_pallet.dart';
import '../auditor_providers.dart';
import '../auditor_shell.dart' show startAuditFor;

/// The pallet register, as the auditor browses it.
///
/// Reads `/warehouse/pallets`, not `/qa/pallets` — the QA router role-locks
/// before permissions are consulted, so the auditor cannot call that one
/// however the grid is set.
///
/// Defaults to CLOSED pallets. An open one has no number and no printed label,
/// so there is nothing to scan and its contents change under the auditor while
/// they count; the server refuses it, and listing it here would only be a trap.
/// The filter still offers the other states, because "what happened to the
/// pallet I rejected last week" is a fair question.
class DplPalletsToAuditScreen extends ConsumerStatefulWidget {
  const DplPalletsToAuditScreen({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  ConsumerState<DplPalletsToAuditScreen> createState() =>
      _DplPalletsToAuditScreenState();
}

class _DplPalletsToAuditScreenState
    extends ConsumerState<DplPalletsToAuditScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = ref.read(dplAuditPalletFilterProvider).search;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Debounced, because the field is typed on a handheld and every keystroke
  /// would otherwise be a round trip against a table with every pallet in it.
  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      final n = ref.read(dplAuditPalletFilterProvider.notifier);
      n.set(ref.read(dplAuditPalletFilterProvider).copyWith(search: v));
    });
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(dplAuditPalletFilterProvider);
    final async = ref.watch(dplAuditPalletsProvider);

    final body = Column(
      children: [
        _filterBar(filter),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => DplInlineErrorRetry(
              message: e.toString(),
              onRetry: () => ref.invalidate(dplAuditPalletsProvider),
            ),
            data: (res) {
              if (res.isError) {
                return DplInlineErrorRetry(
                  message: res.error ?? 'Failed to load pallets.',
                  onRetry: () => ref.invalidate(dplAuditPalletsProvider),
                );
              }
              final rows = res.data ?? const <DplPallet>[];
              if (rows.isEmpty) return _empty(filter);
              return RefreshIndicator(
                onRefresh: () async => ref.invalidate(dplAuditPalletsProvider),
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 28),
                  itemCount: rows.length,
                  itemBuilder: (_, i) => _palletRow(rows[i]),
                ),
              );
            },
          ),
        ),
      ],
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: AppBar(title: const Text('Pallets')),
      body: body,
    );
  }

  Widget _filterBar(DplAuditPalletFilter f) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(
        children: [
          TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Pallet number or part',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              suffixIcon: f.hasAny
                  ? IconButton(
                      tooltip: 'Clear filters',
                      icon: const Icon(Icons.filter_alt_off_outlined, size: 20),
                      onPressed: () {
                        _searchCtrl.clear();
                        ref.read(dplAuditPalletFilterProvider.notifier).clear();
                      },
                    )
                  : null,
            ),
            onChanged: _onSearch,
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _choice('Closed', f.status == 'closed',
                    () => _setStatus(f, 'closed')),
                const SizedBox(width: 8),
                _choice('Dispatched', f.status == 'dispatched',
                    () => _setStatus(f, 'dispatched')),
                const SizedBox(width: 8),
                _choice('All', f.status == 'all', () => _setStatus(f, 'all')),
                const SizedBox(width: 16),
                _choice('Full', f.palletType == 'P', () => _setType(f, 'P')),
                const SizedBox(width: 8),
                _choice('Half', f.palletType == 'H', () => _setType(f, 'H')),
                const SizedBox(width: 8),
                _choice('Merged', f.palletType == 'PM', () => _setType(f, 'PM')),
                const SizedBox(width: 16),
                for (final s in const ['A', 'B', 'C']) ...[
                  _choice('Shift $s', f.shiftCode == s, () => _setShift(f, s)),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _setStatus(DplAuditPalletFilter f, String v) => ref
      .read(dplAuditPalletFilterProvider.notifier)
      .set(f.copyWith(status: v));

  // Tapping the selected chip clears it, so a filter can be undone with the
  // same gesture that set it.
  void _setType(DplAuditPalletFilter f, String v) => ref
      .read(dplAuditPalletFilterProvider.notifier)
      .set(f.copyWith(palletType: f.palletType == v ? '' : v));

  void _setShift(DplAuditPalletFilter f, String v) => ref
      .read(dplAuditPalletFilterProvider.notifier)
      .set(f.copyWith(shiftCode: f.shiftCode == v ? '' : v));

  Widget _choice(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      selected: selected,
      onSelected: (_) => onTap(),
      label: Text(label),
    );
  }

  Widget _empty(DplAuditPalletFilter f) {
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        const SizedBox(height: 40),
        Icon(Icons.inventory_2_outlined, size: 40, color: DplColors.textTertiary),
        const SizedBox(height: 14),
        Text(
          f.hasAny
              ? 'No pallets match those filters.'
              : 'No closed pallets yet.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }

  Widget _palletRow(DplPallet p) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DplCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.palletNo.isEmpty ? '#${p.id}' : p.palletNo,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (p.customerPartNo.isNotEmpty) p.customerPartNo,
                      '${p.qty}${p.standardQty == null ? '' : ' / ${p.standardQty}'}',
                      if (p.shiftCode.isNotEmpty) 'Shift ${p.shiftCode}',
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 12,
                      color: DplColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            FilledButton.tonal(
              onPressed: () => startAuditFor(context, ref, palletId: p.id),
              child: const Text('Audit'),
            ),
          ],
        ),
      ),
    );
  }
}
