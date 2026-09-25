import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../core/widgets/dpl_stat_tile.dart';
import '../../models/dpl_stock_control.dart';
import '../common/maxion_kit.dart';
import 'manager_maxion_providers.dart';

/// Opening stock from Ekatm (API.md §10.1): pick the sheet, read the preview,
/// then import. Nothing is written until the import button is pressed.
class DplOpeningStockScreen extends ConsumerStatefulWidget {
  final bool showAppBar;

  const DplOpeningStockScreen({super.key, this.showAppBar = true});

  @override
  ConsumerState<DplOpeningStockScreen> createState() => _DplOpeningStockScreenState();
}

class _DplOpeningStockScreenState extends ConsumerState<DplOpeningStockScreen> {
  Uint8List? _bytes;
  String? _fileName;
  DplOpeningImport? _preview;
  DplOpeningImport? _committed;
  bool _acceptErrors = false;
  bool _busy = false;

  Future<void> _pick() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'xls', 'csv'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final f = picked.files.first;
    if (f.bytes == null) {
      if (mounted) DplSnacks.error(context, 'Could not read ${f.name}.');
      return;
    }
    setState(() {
      _bytes = f.bytes;
      _fileName = f.name;
      _preview = null;
      _committed = null;
      _acceptErrors = false;
    });
    await _runPreview();
  }

  Future<void> _runPreview() async {
    if (_bytes == null || _fileName == null) return;
    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).importOpeningStock(bytes: _bytes!, fileName: _fileName!);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.isError || res.data == null) {
      showFloorError(context, res, fallback: 'Could not read that stock file.');
      return;
    }
    setState(() => _preview = res.data);
  }

  Future<void> _commit({bool confirmAdditional = false}) async {
    final p = _preview;
    if (_bytes == null || _fileName == null || p == null) return;
    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).importOpeningStock(
          bytes: _bytes!,
          fileName: _fileName!,
          commit: true,
          acceptErrors: p.errors > 0 && _acceptErrors,
          confirmAdditional: confirmAdditional,
        );
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError) {
      switch (res.code) {
        case 'IMPORT_EXISTS':
          final go = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Opening stock already imported'),
              content: Text(
                '${res.error ?? 'An opening-stock import already exists.'}\n\n'
                'Importing this file ADDS its quantities on top of what is already there. '
                'Only continue if this sheet holds stock the first import did not.',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add it')),
              ],
            ),
          );
          if (go == true && mounted) await _commit(confirmAdditional: true);
          return;
        case 'ALREADY_IMPORTED':
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('This file was already imported'),
              content: Text(
                '${res.error ?? 'This exact file has been imported before.'}\n\n'
                'The same file can never be imported twice, so nothing was changed. '
                'To correct a quantity, raise a stock adjustment instead.',
              ),
              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
            ),
          );
          return;
        default:
          showFloorError(context, res, fallback: 'Could not import the stock file.');
          return;
      }
    }

    setState(() => _committed = res.data);
    ref.invalidate(dplStockLotsProvider);
    DplSnacks.success(context, 'Imported ${res.data?.qty ?? 0} wheels as ${res.data?.importNo ?? 'opening stock'}.');
  }

  void _reset() => setState(() {
        _bytes = null;
        _fileName = null;
        _preview = null;
        _committed = null;
        _acceptErrors = false;
      });

  @override
  Widget build(BuildContext context) {
    final canImport = ref.watch(dplPermissionsProvider).can(DplPermission.stockImport);

    final body = RefreshIndicator(
      onRefresh: () => ref.refresh(dplStockLotsProvider.future),
      child: ListView(
        padding: const EdgeInsets.all(DplSpacing.md),
        children: [
          _pickCard(canImport),
          if (_committed != null) _committedCard(_committed!),
          if (_preview != null && _committed == null) ..._previewCards(_preview!, canImport),
          const SizedBox(height: DplSpacing.lg),
          Text('Unlabelled lot stock', style: DplText.h3()),
          const SizedBox(height: DplSpacing.sm),
          _lots(),
          const SizedBox(height: DplSpacing.xxl),
        ],
      ),
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: const DplAppBar(title: 'Opening stock'),
      body: body,
    );
  }

  Widget _pickCard(bool canImport) {
    return DplCard(
      margin: const EdgeInsets.only(bottom: DplSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Import from Ekatm', style: DplText.h3()),
          const SizedBox(height: DplSpacing.xs),
          Text(
            'Export the stock sheet from Ekatm (Item Code, Batch No, WHM Code, LOC Code, Bal Qty, Fifo) '
            'as .xlsx, .xls or .csv. You will see a preview before anything is saved.',
            style: DplText.bodySm().copyWith(color: DplColors.textSecondary),
          ),
          const SizedBox(height: DplSpacing.md),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _busy || !canImport ? null : _pick,
                icon: const Icon(Icons.upload_file, size: 18),
                label: Text(_fileName == null ? 'Choose file' : 'Choose another'),
              ),
              const SizedBox(width: DplSpacing.md),
              if (_busy) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              if (_fileName != null && !_busy)
                Expanded(child: Text(_fileName!, overflow: TextOverflow.ellipsis, style: DplText.bodySm())),
            ],
          ),
          if (!canImport)
            Padding(
              padding: const EdgeInsets.only(top: DplSpacing.sm),
              child: Text(
                'Importing opening stock needs the stock import permission.',
                style: DplText.bodySm().copyWith(color: DplColors.warning),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _previewCards(DplOpeningImport p, bool canImport) {
    final needsAccept = p.errors > 0;
    final canCommit = canImport && !_busy && p.ok > 0 && (!needsAccept || _acceptErrors);
    return [
      DplCard(
        margin: const EdgeInsets.only(bottom: DplSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Preview', style: DplText.h3()),
            const SizedBox(height: DplSpacing.md),
            _totals(p),
          ],
        ),
      ),
      if (p.unmatchedItems.isNotEmpty)
        _listCard(
          'Items not found (${p.unmatchedItems.length})',
          'These item codes are not in DPL parts. Their rows will not be imported.',
          p.unmatchedItems,
          DplColors.error,
        ),
      if (p.unmappedLocations.isNotEmpty)
        _listCard(
          'Locations not mapped (${p.unmappedLocations.length})',
          'These Ekatm locations have no DPL rack. The stock is still imported, without a rack.',
          p.unmappedLocations,
          DplColors.warning,
        ),
      if (p.problemRows.isNotEmpty)
        DplCard(
          margin: const EdgeInsets.only(bottom: DplSpacing.md),
          padding: const EdgeInsets.symmetric(vertical: DplSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: DplSpacing.lg, vertical: DplSpacing.xs),
                child: Text('Rows with problems (${p.problemRows.length})', style: DplText.h3()),
              ),
              for (final r in p.problemRows.take(200))
                ListTile(
                  dense: true,
                  leading: Icon(
                    r.status == 'error' ? Icons.error_outline : Icons.remove_circle_outline,
                    color: r.status == 'error' ? DplColors.error : DplColors.neutral,
                  ),
                  title: Text('Row ${r.row}${r.itemCode == null ? '' : ' · ${r.itemCode}'}'),
                  subtitle: Text(r.message ?? r.status),
                ),
              if (p.problemRows.length > 200)
                Padding(
                  padding: const EdgeInsets.all(DplSpacing.md),
                  child: Text('…and ${p.problemRows.length - 200} more.', style: DplText.caption()),
                ),
            ],
          ),
        ),
      DplCard(
        margin: const EdgeInsets.only(bottom: DplSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (needsAccept)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _acceptErrors,
                onChanged: (v) => setState(() => _acceptErrors = v ?? false),
                title: const Text('Leave out the rows with errors'),
                subtitle: Text('${p.errors} row${p.errors == 1 ? '' : 's'} will not be imported.'),
              ),
            FilledButton.icon(
              onPressed: canCommit ? () => _commit() : null,
              icon: const Icon(Icons.inventory),
              label: Text('Import ${p.qty} wheels'),
            ),
            TextButton(onPressed: _busy ? null : _reset, child: const Text('Cancel')),
          ],
        ),
      ),
    ];
  }

  Widget _totals(DplOpeningImport p) => Wrap(
        spacing: DplSpacing.xl,
        runSpacing: DplSpacing.md,
        children: [
          DplStatTile(label: 'Rows', value: '${p.rows}', valueStyle: DplText.numMd()),
          DplStatTile(label: 'OK', value: '${p.ok}', valueStyle: DplText.numMd(), valueColor: DplColors.success),
          DplStatTile(label: 'Skipped', value: '${p.skipped}', valueStyle: DplText.numMd()),
          DplStatTile(
            label: 'Errors',
            value: '${p.errors}',
            valueStyle: DplText.numMd(),
            valueColor: p.errors > 0 ? DplColors.error : null,
          ),
          DplStatTile(label: 'Lots', value: '${p.lots}', valueStyle: DplText.numMd()),
          DplStatTile(label: 'Wheels', value: '${p.qty}', valueStyle: DplText.numMd()),
        ],
      );

  Widget _listCard(String title, String hint, List<String> values, Color color) => DplCard(
        margin: const EdgeInsets.only(bottom: DplSpacing.md),
        accentColor: color,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: DplText.h3()),
            const SizedBox(height: DplSpacing.xs),
            Text(hint, style: DplText.bodySm().copyWith(color: DplColors.textSecondary)),
            const SizedBox(height: DplSpacing.sm),
            Wrap(
              spacing: DplSpacing.xs,
              runSpacing: DplSpacing.xs,
              children: [for (final v in values) Chip(label: Text(v), visualDensity: VisualDensity.compact)],
            ),
          ],
        ),
      );

  Widget _committedCard(DplOpeningImport c) => DplCard(
        margin: const EdgeInsets.only(bottom: DplSpacing.md),
        accentColor: DplColors.success,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: DplColors.success),
                const SizedBox(width: DplSpacing.sm),
                Expanded(child: Text('Imported ${c.importNo ?? ''}', style: DplText.h3())),
              ],
            ),
            const SizedBox(height: DplSpacing.md),
            _totals(c),
            const SizedBox(height: DplSpacing.sm),
            Text(
              'The wheels are unlabelled lot stock now. Each old Ekatm label adopted onto a pallet '
              'uses up the oldest lot of that item.',
              style: DplText.bodySm().copyWith(color: DplColors.textSecondary),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _reset, child: const Text('Import another file')),
            ),
          ],
        ),
      );

  Widget _lots() {
    final async = ref.watch(dplStockLotsProvider);
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(DplSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => DplInlineErrorRetry(message: e.toString(), onRetry: () => ref.invalidate(dplStockLotsProvider)),
      data: (res) {
        if (res.isError) {
          return DplInlineErrorRetry(
            message: res.floorMessage.isEmpty ? 'Could not load lots.' : res.floorMessage,
            onRetry: () => ref.invalidate(dplStockLotsProvider),
          );
        }
        final lots = res.data ?? const [];
        if (lots.isEmpty) {
          return DplCard(
            child: Text('No lot stock. Opening stock appears here once it is imported.', style: DplText.bodySm()),
          );
        }
        final remaining = lots.fold<int>(0, (s, l) => s + l.qtyRemaining);
        return DplCard(
          padding: const EdgeInsets.symmetric(vertical: DplSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: DplSpacing.lg, vertical: DplSpacing.xs),
                child: Text('${lots.length} lots · $remaining wheels remaining', style: DplText.caption()),
              ),
              for (final l in lots)
                ListTile(
                  dense: true,
                  title: Text(l.customerPartNo ?? 'Part #${l.partId}'),
                  subtitle: Text([
                    if (l.lotNo != null) 'Lot ${l.lotNo}',
                    ?l.sourceLocationCode,
                    if (l.fifoDate != null) 'FIFO ${l.fifoDate}',
                  ].join(' · ')),
                  trailing: Text('${l.qtyRemaining} / ${l.openingQty}', style: DplText.body()),
                ),
            ],
          ),
        );
      },
    );
  }
}
