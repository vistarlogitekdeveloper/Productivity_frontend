import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/theme/vistar_palette.dart';
import '../../core/widgets/shimmer_skeleton.dart';
import '../../data/models/production_entry_model.dart';
import 'report_export_service.dart';
import 'reports_provider.dart';

class ReviewActionsScreen extends ConsumerStatefulWidget {
  final bool embedded;

  const ReviewActionsScreen({
    super.key,
    this.embedded = false,
  });

  @override
  ConsumerState<ReviewActionsScreen> createState() => _ReviewActionsScreenState();
}

class _ReviewActionsScreenState extends ConsumerState<ReviewActionsScreen> {
  static const int _rowsPerPage = 10;
  final TextEditingController _searchCtrl = TextEditingController();
  String _statusFilter = 'PENDING';
  bool _isExporting = false;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _applyFiltersAndLoad(0));
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Map<String, dynamic> _buildApiFilters() {
    final filters = <String, dynamic>{};
    if (_statusFilter != 'ALL') {
      filters['status'] = _statusFilter;
    }
    final search = _searchCtrl.text.trim();
    if (search.isNotEmpty) {
      filters['search'] = search;
    }
    return filters;
  }

  Future<void> _applyFiltersAndLoad(int pageIndex) async {
    ref
        .read(reportsControllerProvider.notifier)
        .updateFilters(_buildApiFilters());
    await _loadPage(pageIndex);
  }

  Future<void> _loadPage(int pageIndex) async {
    await ref.read(reportsControllerProvider.notifier).fetchPage(
          pageIndex,
          _rowsPerPage,
        );
  }

  void _onStatusChanged(String status) {
    if (_statusFilter == status) return;
    setState(() => _statusFilter = status);
    _applyFiltersAndLoad(0);
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _applyFiltersAndLoad(0);
    });
  }

  String _formatError(Object error) {
    final raw = error.toString();
    const prefix = 'Exception:';
    if (raw.startsWith(prefix)) return raw.substring(prefix.length).trim();
    return raw;
  }

  String _safeText(String? value) {
    final text = (value ?? '').trim();
    return text.isEmpty ? '-' : text;
  }

  String _operatorLabel(ProductionEntryModel entry) {
    if (entry.operatorNames.isNotEmpty) return entry.operatorNames.join(', ');
    final name = (entry.operatorName ?? '').trim();
    if (name.isNotEmpty) return name;
    return _safeText(entry.operatorId);
  }

  String _formatDate(String rawDate) {
    final parsed = DateTime.tryParse(rawDate);
    if (parsed == null) return _safeText(rawDate);
    return DateFormat('dd MMM yyyy').format(parsed);
  }

  Future<void> _submitUpdate({
    required int pageIndex,
    required String entryId,
    required Map<String, dynamic> payload,
    required String successMessage,
  }) async {
    try {
      await ref.read(reportsControllerProvider.notifier).updateEntry(
            id: entryId,
            payload: payload,
          );
      await _loadPage(pageIndex);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(successMessage)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_formatError(e))),
      );
    }
  }

  Future<void> _handleReviewFileAction(
    _ReviewFileAction action,
    List<ProductionEntryModel> currentEntries,
  ) async {
    if (currentEntries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No data available to export.')),
      );
      return;
    }

    setState(() => _isExporting = true);
    try {
      final isExcel = action == _ReviewFileAction.downloadExcel ||
          action == _ReviewFileAction.shareExcel;
      final isShare = action == _ReviewFileAction.shareExcel ||
          action == _ReviewFileAction.sharePdf;

      String? path;
      if (isShare) {
        if (isExcel) {
          await ReportExportService.shareExcel(
            reportName: 'review_actions',
            entries: currentEntries,
          );
        } else {
          await ReportExportService.sharePdf(
            reportName: 'review_actions',
            entries: currentEntries,
          );
        }
      } else {
        if (isExcel) {
          path = await ReportExportService.exportExcel(
            reportName: 'review_actions',
            entries: currentEntries,
          );
        } else {
          path = await ReportExportService.exportPdf(
            reportName: 'review_actions',
            entries: currentEntries,
          );
        }
      }

      if (!mounted) return;
      final exportedName = isExcel ? 'Excel' : 'PDF';
      final message = isShare
          ? '$exportedName share opened.'
          : (path == null
                ? '$exportedName download started.'
                : '$exportedName exported to: $path');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_formatError(e))),
      );
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  Future<void> _handleAction(
    ProductionEntryModel entry,
    _ReviewAction action,
    int pageIndex,
  ) async {
    final entryId = entry.id?.trim() ?? '';
    if (entryId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot update entry without an ID.')),
      );
      return;
    }

    switch (action) {
      case _ReviewAction.approve:
        await _submitUpdate(
          pageIndex: pageIndex,
          entryId: entryId,
          payload: const {'approvalStatus': 'APPROVED'},
          successMessage: 'Entry approved.',
        );
        break;
      case _ReviewAction.reject:
        await _submitUpdate(
          pageIndex: pageIndex,
          entryId: entryId,
          payload: const {'approvalStatus': 'REJECTED'},
          successMessage: 'Entry rejected.',
        );
        break;
      case _ReviewAction.edit:
        final payload = await showDialog<Map<String, dynamic>>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _ReviewEntryEditDialog(entry: entry),
        );
        if (payload == null || payload.isEmpty) return;
        await _submitUpdate(
          pageIndex: pageIndex,
          entryId: entryId,
          payload: payload,
          successMessage: 'Entry updated.',
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(reportsControllerProvider);
    final entries = state.entries;
    final isCompactScreen = MediaQuery.of(context).size.width < 920;

    final totalPages =
        state.totalCount == 0 ? 1 : ((state.totalCount + _rowsPerPage - 1) ~/ _rowsPerPage);
    final canGoPrev = state.currentPage > 0;
    final canGoNext = state.currentPage + 1 < totalPages;
    final isBusy = state.isLoading || _isExporting;

    final actionWidgets = <Widget>[
      PopupMenuButton<_ReviewFileAction>(
        tooltip: 'Download / Share',
        icon: const Icon(Icons.download_outlined),
        onSelected: (value) => _handleReviewFileAction(value, entries),
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: _ReviewFileAction.downloadExcel,
            child: ListTile(
              dense: true,
              leading: Icon(Icons.table_view_outlined),
              title: Text('Download Excel'),
            ),
          ),
          PopupMenuItem(
            value: _ReviewFileAction.downloadPdf,
            child: ListTile(
              dense: true,
              leading: Icon(Icons.picture_as_pdf_outlined),
              title: Text('Download PDF'),
            ),
          ),
          PopupMenuDivider(),
          PopupMenuItem(
            value: _ReviewFileAction.shareExcel,
            child: ListTile(
              dense: true,
              leading: Icon(Icons.ios_share_outlined),
              title: Text('Share Excel'),
            ),
          ),
          PopupMenuItem(
            value: _ReviewFileAction.sharePdf,
            child: ListTile(
              dense: true,
              leading: Icon(Icons.share_outlined),
              title: Text('Share PDF'),
            ),
          ),
        ],
      ),
      IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: 'Refresh',
        onPressed: () => _loadPage(state.currentPage),
      ),
    ];

    final content = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [VistarPalette.bg, VistarPalette.bg2, VistarPalette.bg],
        ),
      ),
      child: RefreshIndicator(
        onRefresh: () => _loadPage(state.currentPage),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            if (widget.embedded && isBusy) const ShimmerLinearBar(height: 2),
            if (widget.embedded && isBusy) const SizedBox(height: 10),
            if (widget.embedded)
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Review Actions',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  ...actionWidgets,
                ],
              ),
            if (widget.embedded) const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: VistarPalette.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: VistarPalette.line),
              ),
              child: Text(
                'Review and update entry approval status with direct actions.',
                style: TextStyle(color: VistarPalette.txt2),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: VistarPalette.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: VistarPalette.line),
              ),
              child: Column(
                children: [
                  TextField(
                    controller: _searchCtrl,
                    onChanged: _onSearchChanged,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search machine, item, shift, status',
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 36,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final status in const [
                          'ALL',
                          'PENDING',
                          'APPROVED',
                          'REJECTED',
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(status),
                              selected: _statusFilter == status,
                              onSelected: (_) => _onStatusChanged(status),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (state.isLoading && state.entries.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 30),
                decoration: BoxDecoration(
                  color: VistarPalette.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: VistarPalette.line),
                ),
                child: const ShimmerCenteredPlaceholder(
                  verticalPadding: 8,
                  titleWidth: 230,
                  subtitleWidth: 140,
                ),
              )
            else if (entries.isEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: VistarPalette.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: VistarPalette.line),
                ),
                child: Text(
                  'No entries found for selected filters.',
                  style: TextStyle(color: VistarPalette.txt2),
                ),
              )
            else if (isCompactScreen)
              Column(
                children: [
                  for (final entry in entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _ReviewEntryCard(
                        entry: entry,
                        onEdit: () => _handleAction(
                          entry,
                          _ReviewAction.edit,
                          state.currentPage,
                        ),
                        onApprove: () => _handleAction(
                          entry,
                          _ReviewAction.approve,
                          state.currentPage,
                        ),
                        onReject: () => _handleAction(
                          entry,
                          _ReviewAction.reject,
                          state.currentPage,
                        ),
                      ),
                    ),
                ],
              )
            else
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: VistarPalette.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: VistarPalette.line),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    dataRowMinHeight: 92,
                    dataRowMaxHeight: 120,
                    horizontalMargin: 10,
                    columnSpacing: 14,
                    headingRowColor: WidgetStateProperty.all(
                      VistarPalette.surface2,
                    ),
                    columns: const [
                      DataColumn(label: Text('Date')),
                      DataColumn(label: Text('Shift')),
                      DataColumn(label: Text('Operator')),
                      DataColumn(label: Text('Machine')),
                      DataColumn(label: Text('RC Number')),
                      DataColumn(label: Text('Item')),
                      DataColumn(label: Text('Qty')),
                      DataColumn(label: Text('Reject')),
                      DataColumn(label: Text('Weight (KG)')),
                      DataColumn(label: Text('Status')),
                      DataColumn(label: Text('Actions')),
                    ],
                    rows: entries.map((entry) {
                      final status =
                          _safeText(entry.approvalStatus ?? 'PENDING').toUpperCase();
                      final machine = _safeText(entry.machineName ?? entry.machineId);
                      final rcNumber = _safeText(entry.rcNumber);
                      final item = _safeText(entry.itemDescription ?? entry.itemId);

                      return DataRow(
                        cells: [
                          DataCell(Text(_formatDate(entry.entryDate))),
                          DataCell(Text(_safeText(entry.shift))),
                          DataCell(
                            SizedBox(
                              width: 160,
                              child: Text(
                                _operatorLabel(entry),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          DataCell(
                            SizedBox(
                              width: 190,
                              child: Text(
                                machine,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          DataCell(
                            SizedBox(
                              width: 120,
                              child: Text(
                                rcNumber,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          DataCell(
                            SizedBox(
                              width: 190,
                              child: Text(
                                item,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          DataCell(Text(entry.actualQuantity.toString())),
                          DataCell(Text(entry.rejectionQuantity.toString())),
                          DataCell(Text(entry.weightInKGs.toStringAsFixed(2))),
                          DataCell(_ReviewStatusChip(status: status)),
                          DataCell(
                            _ReviewActionCell(
                              onEdit: () => _handleAction(
                                entry,
                                _ReviewAction.edit,
                                state.currentPage,
                              ),
                              onApprove: () => _handleAction(
                                entry,
                                _ReviewAction.approve,
                                state.currentPage,
                              ),
                              onReject: () => _handleAction(
                                entry,
                                _ReviewAction.reject,
                                state.currentPage,
                              ),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: VistarPalette.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: VistarPalette.line),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact = constraints.maxWidth < 700;
                  if (!isCompact) {
                    return Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: canGoPrev ? () => _loadPage(state.currentPage - 1) : null,
                          icon: const Icon(Icons.chevron_left),
                          label: const Text('Previous'),
                        ),
                        const Spacer(),
                        Text(
                          'Page ${state.currentPage + 1} / $totalPages | ${state.totalCount} records',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: VistarPalette.txt2,
                          ),
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: canGoNext ? () => _loadPage(state.currentPage + 1) : null,
                          icon: const Icon(Icons.chevron_right),
                          label: const Text('Next'),
                        ),
                      ],
                    );
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Page ${state.currentPage + 1} / $totalPages | ${state.totalCount} records',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: VistarPalette.txt2,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: canGoPrev ? () => _loadPage(state.currentPage - 1) : null,
                              icon: const Icon(Icons.chevron_left),
                              label: const Text('Previous'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: canGoNext ? () => _loadPage(state.currentPage + 1) : null,
                              icon: const Icon(Icons.chevron_right),
                              label: const Text('Next'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );

    if (widget.embedded) return content;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review Actions'),
        actions: actionWidgets,
      ),
      body: content,
      bottomNavigationBar:
          isBusy ? const ShimmerLinearBar(height: 2) : null,
    );
  }
}

enum _ReviewAction { edit, approve, reject }
enum _ReviewFileAction { downloadExcel, downloadPdf, shareExcel, sharePdf }

class _ReviewStatusChip extends StatelessWidget {
  final String status;

  const _ReviewStatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    Color bgColor;
    Color textColor;

    if (status == 'APPROVED') {
      bgColor = VistarPalette.okBg;
      textColor = VistarPalette.ok;
    } else if (status == 'REJECTED') {
      bgColor = VistarPalette.badBg;
      textColor = VistarPalette.bad;
    } else {
      bgColor = VistarPalette.warnBg;
      textColor = VistarPalette.warn;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status,
        style: TextStyle(
          color: textColor,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _ReviewEntryCard extends StatelessWidget {
  final ProductionEntryModel entry;
  final VoidCallback onEdit;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _ReviewEntryCard({
    required this.entry,
    required this.onEdit,
    required this.onApprove,
    required this.onReject,
  });

  String _safeText(String? value) {
    final text = (value ?? '').trim();
    return text.isEmpty ? '-' : text;
  }

  String _formatDate(String rawDate) {
    final parsed = DateTime.tryParse(rawDate);
    if (parsed == null) return _safeText(rawDate);
    return DateFormat('dd MMM yyyy').format(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final status = _safeText(entry.approvalStatus ?? 'PENDING').toUpperCase();
    final machine = _safeText(entry.machineName ?? entry.machineId);
    final item = _safeText(entry.itemDescription ?? entry.itemId);

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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '$machine | $item',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ),
              const SizedBox(width: 8),
              _ReviewStatusChip(status: status),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Date: ${_formatDate(entry.entryDate)} | Shift: ${_safeText(entry.shift)}',
            style: TextStyle(color: VistarPalette.txt2),
          ),
          const SizedBox(height: 3),
          Text(
            'Operator: ${_safeText(entry.operatorName ?? entry.operatorId)} | RC: ${_safeText(entry.rcNumber)}',
            style: TextStyle(color: VistarPalette.txt2),
          ),
          const SizedBox(height: 3),
          Text(
            'Actual: ${entry.actualQuantity} | Reject: ${entry.rejectionQuantity} | Weight: ${entry.weightInKGs.toStringAsFixed(2)} KG',
            style: TextStyle(color: VistarPalette.txt2),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MiniAction(
                icon: Icons.edit_outlined,
                label: 'Edit',
                color: VistarPalette.primary,
                onTap: onEdit,
              ),
              _MiniAction(
                icon: Icons.check_circle_outline,
                label: 'Approve',
                color: VistarPalette.ok,
                onTap: onApprove,
              ),
              _MiniAction(
                icon: Icons.cancel_outlined,
                label: 'Reject',
                color: VistarPalette.bad,
                onTap: onReject,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _MiniAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.26)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewActionCell extends StatelessWidget {
  final VoidCallback onEdit;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _ReviewActionCell({
    required this.onEdit,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Row(
            children: [
              _MiniAction(
                icon: Icons.edit_outlined,
                label: 'Edit',
                color: VistarPalette.primary,
                onTap: onEdit,
              ),
              const SizedBox(width: 6),
              _MiniAction(
                icon: Icons.check_circle_outline,
                label: 'Approve',
                color: VistarPalette.ok,
                onTap: onApprove,
              ),
              const SizedBox(width: 6),
              _MiniAction(
                icon: Icons.cancel_outlined,
                label: 'Reject',
                color: VistarPalette.bad,
                onTap: onReject,
              ),
            ],
          ),
          const SizedBox(height: 2),
        ],
      ),
    );
  }
}

class _ReviewEntryEditDialog extends StatefulWidget {
  final ProductionEntryModel entry;

  const _ReviewEntryEditDialog({required this.entry});

  @override
  State<_ReviewEntryEditDialog> createState() => _ReviewEntryEditDialogState();
}

class _ReviewEntryEditDialogState extends State<_ReviewEntryEditDialog> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _shiftCtrl;
  late final TextEditingController _machineCtrl;
  late final TextEditingController _itemCtrl;
  late final TextEditingController _customerCtrl;
  late final TextEditingController _ccd1Ctrl;
  late final TextEditingController _actualCtrl;
  late final TextEditingController _rejectionCtrl;
  late final TextEditingController _startTimeCtrl;
  late final TextEditingController _endTimeCtrl;
  late final TextEditingController _notesCtrl;
  late String _approvalStatus;
  String? _dialogError;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    _shiftCtrl = TextEditingController(text: entry.shift);
    _machineCtrl = TextEditingController(text: entry.machineId);
    _itemCtrl = TextEditingController(text: entry.itemId);
    _customerCtrl = TextEditingController(text: entry.customerId ?? '');
    _ccd1Ctrl = TextEditingController(text: entry.ccd1Quantity.toString());
    _actualCtrl = TextEditingController(text: entry.actualQuantity.toString());
    _rejectionCtrl = TextEditingController(text: entry.rejectionQuantity.toString());
    _startTimeCtrl = TextEditingController(text: _normalizeTime(entry.startTime));
    _endTimeCtrl = TextEditingController(text: _normalizeTime(entry.endTime));
    _notesCtrl = TextEditingController(text: entry.notes ?? '');
    _approvalStatus = (entry.approvalStatus ?? 'PENDING').trim().toUpperCase();
  }

  @override
  void dispose() {
    _shiftCtrl.dispose();
    _machineCtrl.dispose();
    _itemCtrl.dispose();
    _customerCtrl.dispose();
    _ccd1Ctrl.dispose();
    _actualCtrl.dispose();
    _rejectionCtrl.dispose();
    _startTimeCtrl.dispose();
    _endTimeCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  String _normalizeTime(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '';

    final hhmm = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');
    if (hhmm.hasMatch(text)) return text;

    final iso = RegExp(r'T([01]\d|2[0-3]):([0-5]\d)').firstMatch(text);
    if (iso != null) return '${iso.group(1)}:${iso.group(2)}';

    final parsed = DateTime.tryParse(text);
    if (parsed != null) return DateFormat('HH:mm').format(parsed);

    return text;
  }

  int? _parseIntOrNull(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text);
  }

  int? _parseTimeInMinutes(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;
    final match = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(text);
    if (match == null) return null;
    return (int.parse(match.group(1)!) * 60) + int.parse(match.group(2)!);
  }

  String? _validateNumber(String? value, String label) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return null;
    if (int.tryParse(text) == null) return '$label must be a valid number.';
    if (int.parse(text) < 0) return '$label cannot be negative.';
    return null;
  }

  String? _validateTime(String? value, String label) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return null;
    if (_parseTimeInMinutes(text) == null) return '$label must be HH:mm.';
    return null;
  }

  Map<String, dynamic> _buildPayload() {
    final entry = widget.entry;
    final payload = <String, dynamic>{};

    void putIfChanged(String key, dynamic oldValue, dynamic newValue) {
      if (oldValue != newValue) payload[key] = newValue;
    }

    final shift = _shiftCtrl.text.trim();
    final machineId = _machineCtrl.text.trim();
    final itemId = _itemCtrl.text.trim();
    final customerId = _customerCtrl.text.trim();
    final ccd1 = _parseIntOrNull(_ccd1Ctrl.text.trim());
    final actual = _parseIntOrNull(_actualCtrl.text.trim());
    final rejection = _parseIntOrNull(_rejectionCtrl.text.trim());
    final startTime = _startTimeCtrl.text.trim();
    final endTime = _endTimeCtrl.text.trim();
    final notes = _notesCtrl.text.trim();
    final status = _approvalStatus.trim().toUpperCase();

    putIfChanged('shift', entry.shift.trim(), shift);
    putIfChanged('machineId', entry.machineId.trim(), machineId);
    putIfChanged('itemId', entry.itemId.trim(), itemId);
    putIfChanged('customerId', (entry.customerId ?? '').trim(), customerId);
    if (ccd1 != null) putIfChanged('ccd1Quantity', entry.ccd1Quantity, ccd1);
    if (actual != null) putIfChanged('actualQuantity', entry.actualQuantity, actual);
    if (rejection != null) putIfChanged('rejectionQuantity', entry.rejectionQuantity, rejection);
    if (startTime.isNotEmpty) putIfChanged('startTime', _normalizeTime(entry.startTime), startTime);
    if (endTime.isNotEmpty) putIfChanged('endTime', _normalizeTime(entry.endTime), endTime);
    putIfChanged('notes', (entry.notes ?? '').trim(), notes);
    putIfChanged(
      'approvalStatus',
      (entry.approvalStatus ?? 'PENDING').trim().toUpperCase(),
      status,
    );

    return payload;
  }

  void _submit() {
    setState(() => _dialogError = null);
    if (!_formKey.currentState!.validate()) return;

    final actual = _parseIntOrNull(_actualCtrl.text.trim());
    final rejection = _parseIntOrNull(_rejectionCtrl.text.trim());
    if (actual != null && rejection != null && rejection > actual) {
      setState(() => _dialogError = 'Rejection Quantity cannot exceed Actual Quantity.');
      return;
    }

    final start = _parseTimeInMinutes(_startTimeCtrl.text.trim());
    final end = _parseTimeInMinutes(_endTimeCtrl.text.trim());
    if (start != null && end != null && end <= start) {
      setState(() => _dialogError = 'End time must be greater than Start time.');
      return;
    }

    final payload = _buildPayload();
    if (payload.isEmpty) {
      setState(() => _dialogError = 'No changes detected.');
      return;
    }
    Navigator.of(context).pop(payload);
  }

  Widget _adaptivePair({
    required Widget first,
    required Widget second,
    double spacing = 10,
  }) {
    final isCompact = MediaQuery.of(context).size.width < 520;
    if (isCompact) {
      return Column(
        children: [
          first,
          SizedBox(height: spacing),
          second,
        ],
      );
    }

    return Row(
      children: [
        Expanded(child: first),
        SizedBox(width: spacing),
        Expanded(child: second),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('Edit Entry'),
      content: SizedBox(
        width: 560,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_dialogError != null) ...[
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: VistarPalette.badBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: VistarPalette.badLine),
                    ),
                    child: Text(
                      _dialogError!,
                      style: TextStyle(
                        color: VistarPalette.badInk,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                _adaptivePair(
                  first: TextFormField(
                    controller: _shiftCtrl,
                    decoration: const InputDecoration(labelText: 'Shift'),
                  ),
                  second: DropdownButtonFormField<String>(
                    initialValue: _approvalStatus,
                    decoration: const InputDecoration(labelText: 'Approval Status'),
                    items: const [
                      DropdownMenuItem(value: 'PENDING', child: Text('PENDING')),
                      DropdownMenuItem(value: 'APPROVED', child: Text('APPROVED')),
                      DropdownMenuItem(value: 'REJECTED', child: Text('REJECTED')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _approvalStatus = value);
                    },
                  ),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _machineCtrl,
                  decoration: const InputDecoration(labelText: 'Machine ID'),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _itemCtrl,
                  decoration: const InputDecoration(labelText: 'Item ID'),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _customerCtrl,
                  decoration: const InputDecoration(labelText: 'Customer ID'),
                ),
                const SizedBox(height: 10),
                _adaptivePair(
                  first: TextFormField(
                    controller: _ccd1Ctrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'CCD1 Quantity'),
                    validator: (value) => _validateNumber(value, 'CCD1 Quantity'),
                  ),
                  second: TextFormField(
                    controller: _actualCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Actual Quantity'),
                    validator: (value) => _validateNumber(value, 'Actual Quantity'),
                  ),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _rejectionCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Rejection Quantity'),
                  validator: (value) => _validateNumber(value, 'Rejection Quantity'),
                ),
                const SizedBox(height: 10),
                _adaptivePair(
                  first: TextFormField(
                    controller: _startTimeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Start Time',
                      hintText: 'HH:mm',
                    ),
                    validator: (value) => _validateTime(value, 'Start time'),
                  ),
                  second: TextFormField(
                    controller: _endTimeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'End Time',
                      hintText: 'HH:mm',
                    ),
                    validator: (value) => _validateTime(value, 'End time'),
                  ),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _notesCtrl,
                  decoration: const InputDecoration(labelText: 'Notes'),
                  maxLines: 2,
                ),
              ],
            ),
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
