import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_machine.dart';
import '../../models/dpl_pallet.dart';
import '../../models/dpl_part.dart';
import '../services/pallet_label_pdf.dart';
import 'qa_direct_print_screen.dart'
    show qaDirectPartsProvider, qaDirectPartSearchProvider, qaMachinesProvider;

/// The register's filters. A notifier rather than a StateProvider so every
/// change goes through [DplPalletFilter.copyWith], which is where the "any
/// filter change resets to page 1" rule lives — scattering that across call
/// sites is how you end up on page 4 of a 2-page result.
final palletFilterProvider =
    NotifierProvider.autoDispose<PalletFilterNotifier, DplPalletFilter>(
  PalletFilterNotifier.new,
);

class PalletFilterNotifier extends Notifier<DplPalletFilter> {
  @override
  DplPalletFilter build() => const DplPalletFilter();

  void set(DplPalletFilter next) => state = next;
  void clear() => state = const DplPalletFilter();
  void page(int offset) => state = state.copyWith(offset: offset, limit: state.limit);
}

final palletRegisterProvider =
    FutureProvider.autoDispose<DplApiResponse<DplPalletPage>>((ref) async {
  final filter = ref.watch(palletFilterProvider);
  return ref.watch(dplApiServiceProvider).listPallets(filter);
});

/// Every pallet the plant has built, in one place.
///
/// Maxion SSR v3.0 Modules 5 and 6 (merge, de-merge, SPD) all begin by FINDING
/// a pallet, and §5's traceability promise — "scanning it shows the full wheel
/// list from the system" — has nowhere to land until this screen exists. So
/// this is the page those features get built on, not a reporting nicety.
///
/// Read-only today: look, filter, reprint. Nothing here changes what is on the
/// floor, which is why it is gated on its own `pallet.view` and can be handed
/// to dispatch without also handing them a scanner.
class QaPalletRegisterScreen extends ConsumerStatefulWidget {
  const QaPalletRegisterScreen({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  ConsumerState<QaPalletRegisterScreen> createState() =>
      _QaPalletRegisterScreenState();
}

class _QaPalletRegisterScreenState
    extends ConsumerState<QaPalletRegisterScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  bool _busy = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Debounced, because every keystroke would otherwise be a round trip and a
  /// pallet number is twelve characters long.
  void _onSearchChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      final f = ref.read(palletFilterProvider);
      ref.read(palletFilterProvider.notifier).set(f.copyWith(search: v));
    });
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        _filterBar(),
        Expanded(child: _list()),
      ],
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: AppBar(title: const Text('Pallets')),
      body: body,
    );
  }

  // -------------------------------------------------------------------------
  // Filters
  // -------------------------------------------------------------------------

  Widget _filterBar() {
    final f = ref.watch(palletFilterProvider);

    return Container(
      color: DplColors.cardBg,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearchChanged,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Pallet number — try PM26 for merged',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: f.search.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _searchCtrl.clear();
                              _onSearchChanged('');
                            },
                          ),
                    border: const OutlineInputBorder(),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: () => ref.invalidate(palletRegisterProvider),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // The one filter the SSR asks for by name. First in the row
                // because "what is still sitting part-filled" is the question
                // Module 5 exists to answer.
                _chip(
                  label: 'Waiting half pallets',
                  icon: Icons.hourglass_bottom,
                  selected: f.staleHalfOnly,
                  onTap: () => ref.read(palletFilterProvider.notifier).set(
                        f.copyWith(staleHalfOnly: !f.staleHalfOnly),
                      ),
                ),
                _menuChip<String>(
                  label: 'Status',
                  value: f.status,
                  display: _statusLabel,
                  options: const ['', 'open', 'closed', 'merged', 'dispatched'],
                  onSelected: (v) => ref
                      .read(palletFilterProvider.notifier)
                      .set(f.copyWith(status: v)),
                ),
                _menuChip<String>(
                  label: 'Type',
                  value: f.palletType,
                  display: _typeLabel,
                  options: const ['', 'P', 'H', 'PM'],
                  onSelected: (v) => ref
                      .read(palletFilterProvider.notifier)
                      .set(f.copyWith(palletType: v)),
                ),
                _partChip(f),
                _machineChip(f),
                _dateChip(f),
                if (f.isFiltered)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: TextButton.icon(
                      onPressed: () {
                        _searchCtrl.clear();
                        ref.read(palletFilterProvider.notifier).clear();
                      },
                      icon: const Icon(Icons.clear_all, size: 16),
                      label: Text('Clear (${f.activeCount})'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        selected: selected,
        onSelected: (_) => onTap(),
        avatar: icon == null ? null : Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12.5)),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  /// A chip that opens a menu. Shows the chosen value rather than the field
  /// name once something is picked, so a scrolled-off filter is still visible
  /// at a glance — a hidden active filter is how an empty list gets read as
  /// missing data.
  Widget _menuChip<T>({
    required String label,
    required T value,
    required List<T> options,
    required String Function(T) display,
    required ValueChanged<T> onSelected,
  }) {
    final isSet = value != null && value != '';
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: PopupMenuButton<T>(
        onSelected: onSelected,
        itemBuilder: (_) => [
          for (final o in options)
            PopupMenuItem<T>(value: o, child: Text(display(o))),
        ],
        child: Chip(
          label: Text(
            isSet ? display(value) : label,
            style: const TextStyle(fontSize: 12.5),
          ),
          avatar: Icon(
            isSet ? Icons.check : Icons.arrow_drop_down,
            size: 16,
          ),
          backgroundColor: isSet ? DplColors.primary.withValues(alpha: 0.12) : null,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  Widget _partChip(DplPalletFilter f) {
    final parts = ref.watch(qaDirectPartsProvider).asData?.value.data ?? const <DplPart>[];
    DplPart? chosen;
    if (f.partId != null) {
      for (final p in parts) {
        if (p.id == f.partId) {
          chosen = p;
          break;
        }
      }
    }
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        avatar: Icon(f.partId == null ? Icons.arrow_drop_down : Icons.check, size: 16),
        // Falls back to the id when the part is not on the page the picker
        // happens to hold: the search runs server-side, so a filtered-in item
        // can easily not be in the current result set. Showing the raw id is
        // ugly; showing nothing looks like the filter was lost.
        label: Text(
          chosen?.partNumber ?? (f.partId == null ? 'Item' : 'Item #${f.partId}'),
          style: const TextStyle(fontSize: 12.5),
        ),
        backgroundColor:
            f.partId == null ? null : DplColors.primary.withValues(alpha: 0.12),
        visualDensity: VisualDensity.compact,
        onPressed: () async {
          final picked = await showDialog<_PartChoice>(
            context: context,
            builder: (_) => const _PartFilterDialog(),
          );
          if (!mounted) return;
          // The search term is SHARED with the direct-print tab's picker, which
          // is mounted beside this one in the shell's IndexedStack. Left set,
          // that tab would show a part list narrowed by a search its own text
          // field does not display — a list that looks like it lost items.
          // Reset here rather than in the dialog's dispose, where `ref` is
          // already gone.
          ref.read(qaDirectPartSearchProvider.notifier).set('');
          if (picked == null) return;
          ref.read(palletFilterProvider.notifier).set(
                picked.cleared
                    ? f.copyWith(clearPartId: true)
                    : f.copyWith(partId: picked.partId),
              );
        },
      ),
    );
  }

  Widget _machineChip(DplPalletFilter f) {
    final machines =
        ref.watch(qaMachinesProvider).asData?.value.data ?? const <DplMachine>[];
    // No machines loaded means no useful menu — an empty dropdown reads as a
    // broken filter rather than as "nothing to choose from".
    if (machines.isEmpty) return const SizedBox.shrink();
    return _menuChip<int?>(
      label: 'Line',
      value: f.machineId,
      options: <int?>[null, ...machines.map((m) => m.id)],
      display: (v) => v == null ? 'All lines' : _machineName(machines, v),
      onSelected: (v) => ref.read(palletFilterProvider.notifier).set(
            v == null
                ? f.copyWith(clearMachineId: true)
                : f.copyWith(machineId: v),
          ),
    );
  }

  static String _machineName(List<DplMachine> machines, int id) {
    for (final m in machines) {
      if (m.id == id) return m.name.isEmpty ? m.code : m.name;
    }
    return 'Line $id';
  }

  Widget _dateChip(DplPalletFilter f) {
    final has = f.from != null || f.to != null;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        avatar: Icon(has ? Icons.check : Icons.date_range, size: 16),
        label: Text(
          has ? '${_d(f.from)} – ${_d(f.to)}' : 'Packed on',
          style: const TextStyle(fontSize: 12.5),
        ),
        backgroundColor: has ? DplColors.primary.withValues(alpha: 0.12) : null,
        visualDensity: VisualDensity.compact,
        onPressed: () async {
          if (has) {
            ref
                .read(palletFilterProvider.notifier)
                .set(f.copyWith(clearFrom: true, clearTo: true));
            return;
          }
          final now = DateTime.now();
          final range = await showDateRangePicker(
            context: context,
            firstDate: DateTime(now.year - 3),
            lastDate: DateTime(now.year + 1),
            initialDateRange: DateTimeRange(
              start: now.subtract(const Duration(days: 7)),
              end: now,
            ),
          );
          if (range == null || !mounted) return;
          ref
              .read(palletFilterProvider.notifier)
              .set(f.copyWith(from: range.start, to: range.end));
        },
      ),
    );
  }

  static String _d(DateTime? t) {
    if (t == null) return '…';
    return '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}';
  }

  static String _statusLabel(String v) {
    switch (v) {
      case 'open':
        return 'Open';
      case 'closed':
        return 'Closed';
      case 'merged':
        return 'Merged away';
      case 'dispatched':
        return 'Dispatched';
      default:
        return 'Any status';
    }
  }

  static String _typeLabel(String v) {
    switch (v) {
      case 'P':
        return 'Full';
      case 'H':
        return 'Half';
      case 'PM':
        return 'Merged';
      default:
        return 'Any type';
    }
  }

  // -------------------------------------------------------------------------
  // List
  // -------------------------------------------------------------------------

  Widget _list() {
    final async = ref.watch(palletRegisterProvider);
    final f = ref.watch(palletFilterProvider);

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => DplInlineErrorRetry(
        message: e.toString(),
        onRetry: () => ref.invalidate(palletRegisterProvider),
      ),
      data: (res) {
        if (res.isError) {
          return DplInlineErrorRetry(
            message: res.error ?? 'Failed to load the pallet register.',
            onRetry: () => ref.invalidate(palletRegisterProvider),
          );
        }
        final page = res.data ?? const DplPalletPage();
        if (page.pallets.isEmpty) return _empty(f);

        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(palletRegisterProvider),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
            // +2: the count line at the top, the pager at the bottom.
            itemCount: page.pallets.length + 2,
            itemBuilder: (context, i) {
              if (i == 0) return _countLine(page);
              if (i == page.pallets.length + 1) return _pager(page, f);
              return _row(page.pallets[i - 1]);
            },
          ),
        );
      },
    );
  }

  /// "Showing 50 of 2,310" — the difference between a list the storeman trusts
  /// and one they assume is everything on the floor.
  Widget _countLine(DplPalletPage page) {
    final first = page.offset + 1;
    final last = page.offset + page.pallets.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2),
      child: Text(
        page.total <= page.pallets.length
            ? '${page.total} pallet${page.total == 1 ? '' : 's'}'
            : 'Showing $first–$last of ${page.total}',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: DplColors.textSecondary,
        ),
      ),
    );
  }

  Widget _empty(DplPalletFilter f) {
    // "Nothing matches these filters" and "nothing has been packed yet" call
    // for completely different reactions from the reader, so they must not
    // share a message.
    return ListView(
      children: [
        const SizedBox(height: 80),
        Icon(
          f.isFiltered ? Icons.filter_alt_off : Icons.inventory_2_outlined,
          size: 48,
          color: DplColors.textTertiary,
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            f.isFiltered
                ? 'No pallet matches these filters.'
                : 'No pallets have been built yet.',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            f.isFiltered
                ? 'Clear a filter to widen the search.'
                : 'They appear here as soon as the pack point closes one.',
            style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
          ),
        ),
        if (f.isFiltered)
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: TextButton(
                onPressed: () {
                  _searchCtrl.clear();
                  ref.read(palletFilterProvider.notifier).clear();
                },
                child: const Text('Clear filters'),
              ),
            ),
          ),
      ],
    );
  }

  Widget _row(DplPallet p) {
    final stale = (p.ageDays ?? 0) >= 7 && p.palletType == 'H';

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.palletNo.isEmpty ? 'Open — no number yet' : p.palletNo,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: p.palletNo.isEmpty
                            ? DplColors.textSecondary
                            : DplColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      p.customerPartNo.isEmpty
                          ? p.partDescription
                          : '${p.customerPartNo}'
                              '${p.partDescription.isEmpty ? '' : ' · ${p.partDescription}'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: DplColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              _typeBadge(p),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              _fact(Icons.numbers, p.countLabel),
              if (p.machineName.isNotEmpty) _fact(Icons.precision_manufacturing_outlined, p.machineName),
              if (p.shiftCode.isNotEmpty) _fact(Icons.schedule, 'Shift ${p.shiftCode}'),
              // Where it is standing. The single most asked question about a
              // closed pallet, and the reason the register beats a paper log.
              if (p.locationCode.isNotEmpty)
                _fact(Icons.warehouse_outlined, p.locationCode),
              if (p.closedAt != null)
                _fact(Icons.event_available, _fullDate(p.closedAt!)),
              if (p.ageDays != null)
                _fact(
                  Icons.hourglass_bottom,
                  '${p.ageDays} day${p.ageDays == 1 ? '' : 's'} old',
                  // Red once a HALF pallet has been sitting a week. A closed
                  // FULL pallet ageing is just stock; a half one ageing is the
                  // exact thing Module 5 exists to stop.
                  danger: stale,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (p.status != 'closed' && p.status != 'open')
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    p.status == 'merged' ? 'Merged away' : 'Dispatched',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: DplColors.textSecondary,
                    ),
                  ),
                ),
              const Spacer(),
              if (p.palletNo.isNotEmpty) ...[
                IconButton(
                  tooltip: 'Copy pallet number',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: p.palletNo));
                    if (mounted) DplSnacks.success(context, 'Copied ${p.palletNo}.');
                  },
                ),
                TextButton.icon(
                  onPressed: _busy ? null : () => _printLabel(p),
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('Sticker'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _typeBadge(DplPallet p) {
    final open = p.palletNo.isEmpty || p.status == 'open';
    final color = open
        ? DplColors.textSecondary
        : p.palletType == 'P'
            ? DplColors.success
            : p.palletType == 'PM'
                ? DplColors.primary
                : DplColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        open ? 'OPEN' : p.typeLabel.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }

  Widget _fact(IconData icon, String text, {bool danger = false}) {
    final color = danger ? DplColors.error : DplColors.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            color: color,
            fontWeight: danger ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }

  static String _fullDate(DateTime t) {
    final l = t.toLocal();
    return '${l.day.toString().padLeft(2, '0')}/'
        '${l.month.toString().padLeft(2, '0')}/${l.year}';
  }

  Widget _pager(DplPalletPage page, DplPalletFilter f) {
    if (page.total <= page.limit) return const SizedBox(height: 8);
    final canBack = page.offset > 0;
    final canNext = page.hasMore;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton.icon(
            onPressed: canBack
                ? () => ref
                    .read(palletFilterProvider.notifier)
                    .page((page.offset - page.limit).clamp(0, page.total))
                : null,
            icon: const Icon(Icons.chevron_left, size: 18),
            label: const Text('Newer'),
          ),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: canNext
                ? () => ref
                    .read(palletFilterProvider.notifier)
                    .page(page.offset + page.limit)
                : null,
            icon: const Icon(Icons.chevron_right, size: 18),
            label: const Text('Older'),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Reprint
  // -------------------------------------------------------------------------

  /// SSR §5: the pallet label "is reprinted when the pallet changes, for
  /// example on a merge". It also gets torn off by strapping and soaked in the
  /// yard, and without a reprint the only recovery is to break the pallet down
  /// and rebuild it under a new number.
  Future<void> _printLabel(DplPallet p) async {
    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).getPalletLabel(p.id);
    if (!mounted) return;

    if (res.isError || res.data == null) {
      setState(() => _busy = false);
      // The CODE is carried into the message on purpose. "Print sticker is not
      // working" is unactionable; FORBIDDEN_PERMISSION, PALLET_NOT_CLOSED and
      // a 500 each need a different person to do a different thing, and the
      // operator is the only one who can see which it was.
      final code = res.code;
      DplSnacks.error(
        context,
        '${res.error ?? 'Could not load the pallet label.'}'
        '${code == null || code.isEmpty ? '' : ' ($code)'}',
      );
      return;
    }

    final sticker = res.data!;
    try {
      await Printing.layoutPdf(
        name: 'Pallet-${sticker.palletNo}',
        // Both the page box AND the layout format must be the die-cut, with
        // dynamicLayout off. Left on, picking A4 in the print dialog silently
        // rescales the 100 x 75 mm label and the QR stops scanning.
        format: PalletLabelPdf.pageFormat,
        dynamicLayout: false,
        onLayout: (PdfPageFormat _) => PalletLabelPdf.build(sticker),
      );
    } catch (_) {
      if (mounted) {
        DplSnacks.error(context, 'The print sheet failed to open.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// `null` partId with `cleared` true means "show all items" — distinct from
/// the dialog being dismissed, which leaves the filter alone.
class _PartChoice {
  const _PartChoice({this.partId, this.cleared = false});
  final int? partId;
  final bool cleared;
}

/// Searchable item picker. The search runs SERVER-side, so this cannot be a
/// plain local filter over whatever page happens to be loaded — a plant with
/// 128 items would otherwise be unable to find half of them.
class _PartFilterDialog extends ConsumerStatefulWidget {
  const _PartFilterDialog();

  @override
  ConsumerState<_PartFilterDialog> createState() => _PartFilterDialogState();
}

class _PartFilterDialogState extends ConsumerState<_PartFilterDialog> {
  final _ctrl = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) ref.read(qaDirectPartSearchProvider.notifier).set(v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(qaDirectPartsProvider);

    return AlertDialog(
      title: const Text('Filter by item'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _ctrl,
              // NOT autofocused. This is a search box on a register the
              // operator opens to READ; raising the keyboard over the list
              // they came to look at helps nobody.
              onChanged: _onChanged,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Search part number or name',
                prefixIcon: Icon(Icons.search, size: 20),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: async.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => DplInlineErrorRetry(
                  message: e.toString(),
                  onRetry: () => ref.invalidate(qaDirectPartsProvider),
                ),
                data: (res) {
                  final parts = res.data ?? const <DplPart>[];
                  if (parts.isEmpty) {
                    return Center(
                      child: Text(
                        'No item matches that.',
                        style: TextStyle(fontSize: 13, color: DplColors.textSecondary),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: parts.length,
                    itemBuilder: (_, i) {
                      final p = parts[i];
                      return ListTile(
                        dense: true,
                        title: Text(
                          p.partNumber,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: p.name.isEmpty
                            ? null
                            : Text(
                                p.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11.5),
                              ),
                        onTap: () => Navigator.of(context)
                            .pop(_PartChoice(partId: p.id)),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(const _PartChoice(cleared: true)),
          child: const Text('All items'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
