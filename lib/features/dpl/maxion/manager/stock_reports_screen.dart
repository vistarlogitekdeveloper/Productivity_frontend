import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_empty_state.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_stat_tile.dart';
import '../../models/dpl_report_table.dart';
import '../common/maxion_kit.dart';
import 'manager_maxion_providers.dart';

/// How one tabular report is shown: where its rows live in the payload, which
/// fields make the on-screen table, and which totals head it. The full sheet
/// (every column) is always the Excel download; the screen shows the few
/// columns a manager scans on a phone.
class DplStockReportSpec {
  final String key;
  final String label;
  final String rowsKey;
  final bool dateRange;
  final List<DplReportColumn> columns;

  /// `totals` field → tile label, in display order.
  final Map<String, String> totals;

  const DplStockReportSpec({
    required this.key,
    required this.label,
    required this.rowsKey,
    required this.columns,
    this.dateRange = false,
    this.totals = const {},
  });
}

/// The seven tabular reports (backend API.md §7.4, §8.6, §10.4), in tab
/// order. Field names match the backend's own sheet layouts
/// (`services/reportSheets.js`), so the screen and the Excel file agree.
const Map<String, DplStockReportSpec> dplStockReportSpecs = {
  'fg-stock': DplStockReportSpec(
    key: 'fg-stock',
    label: 'FG stock',
    rowsKey: 'items',
    columns: [
      DplReportColumn('customer_part_no', 'Item code'),
      DplReportColumn('description', 'Description'),
      DplReportColumn('on_hand_qty', 'On hand', numeric: true),
      DplReportColumn('full_pallets', 'Full pallets', numeric: true),
      DplReportColumn('half_pallets', 'Half pallets', numeric: true),
      DplReportColumn('loose_qty', 'Printed, not packed', numeric: true),
      DplReportColumn('loaded_qty', 'Loaded', numeric: true),
      DplReportColumn('unlabelled_qty', 'Unlabelled', numeric: true),
    ],
    totals: {
      'on_hand_qty': 'On hand',
      'full_pallets': 'Full pallets',
      'half_pallets': 'Half pallets',
      'loose_qty': 'Printed, not packed',
      'loaded_qty': 'Loaded',
      'unlabelled_qty': 'Unlabelled',
    },
  ),
  'stock-by-location': DplStockReportSpec(
    key: 'stock-by-location',
    label: 'By location',
    rowsKey: 'locations',
    columns: [
      DplReportColumn('code', 'Location'),
      DplReportColumn('zone', 'Zone'),
      DplReportColumn('capacity_qty', 'Capacity', numeric: true),
      DplReportColumn('stored_qty', 'Stored', numeric: true),
      DplReportColumn('free_qty', 'Free', numeric: true),
      // Not numeric on purpose: the cell parser truncates to an int, and a
      // utilisation of 99.5 % should not read as 99.
      DplReportColumn('utilisation_pct', 'Used %'),
      DplReportColumn('pallets', 'Pallets', numeric: true),
      DplReportColumn('half_pallets', 'Half pallets', numeric: true),
    ],
    totals: {
      'capacity_qty': 'Capacity',
      'stored_qty': 'Stored',
      'pallets': 'Pallets',
      'over_capacity_locations': 'Racks over capacity',
    },
  ),
  'dispatch-register': DplStockReportSpec(
    key: 'dispatch-register',
    label: 'Dispatch register',
    rowsKey: 'lines',
    dateRange: true,
    columns: [
      DplReportColumn('dispatch_date', 'Date'),
      DplReportColumn('trip_number', 'Trip', numeric: true),
      DplReportColumn('vehicle_no', 'Vehicle'),
      DplReportColumn('slip_no', 'Slip'),
      DplReportColumn('invoice_no', 'Invoice'),
      DplReportColumn('customer_part_no', 'Item code'),
      DplReportColumn('qty', 'Qty', numeric: true),
      DplReportColumn('pallet_count', 'Pallets', numeric: true),
    ],
    totals: {'qty': 'Wheels', 'slips': 'Slips', 'trips': 'Trips', 'lines': 'Lines'},
  ),
  'half-pallet-ageing': DplStockReportSpec(
    key: 'half-pallet-ageing',
    label: 'Half-pallet ageing',
    rowsKey: 'pallets',
    columns: [
      DplReportColumn('pallet_no', 'Pallet'),
      DplReportColumn('customer_part_no', 'Item code'),
      DplReportColumn('qty', 'Qty', numeric: true),
      DplReportColumn('short_qty', 'Short by', numeric: true),
      DplReportColumn('location_code', 'Location'),
      DplReportColumn('shift_code', 'Shift'),
      DplReportColumn('age_days', 'Age (days)', numeric: true),
    ],
    totals: {'pallets': 'Half pallets', 'qty': 'Wheels'},
  ),
  'label-reconciliation': DplStockReportSpec(
    key: 'label-reconciliation',
    label: 'Label reconciliation',
    rowsKey: 'groups',
    dateRange: true,
    columns: [
      DplReportColumn('print_date', 'Print date'),
      DplReportColumn('shift_code', 'Shift'),
      DplReportColumn('source', 'Source'),
      DplReportColumn('printed', 'Printed', numeric: true),
      DplReportColumn('packed', 'Packed', numeric: true),
      DplReportColumn('loose', 'Not packed', numeric: true),
      DplReportColumn('loaded', 'Loaded', numeric: true),
      DplReportColumn('dispatched', 'Dispatched', numeric: true),
    ],
    totals: {
      'printed': 'Printed',
      'voided': 'Voided',
      'packed': 'Packed',
      'loose': 'Not packed',
      'loaded': 'Loaded',
      'dispatched': 'Dispatched',
      'on_return_hold': 'Returned, awaiting QA',
    },
  ),
  'returns-register': DplStockReportSpec(
    key: 'returns-register',
    label: 'Returns register',
    rowsKey: 'lines',
    dateRange: true,
    columns: [
      DplReportColumn('received_date', 'Received'),
      DplReportColumn('return_no', 'Return no'),
      DplReportColumn('consignee', 'Consignee'),
      DplReportColumn('customer_part_no', 'Item code'),
      DplReportColumn('serial_no', 'Serial'),
      DplReportColumn('qty', 'Qty', numeric: true),
      DplReportColumn('disposition', 'Decision'),
      DplReportColumn('reason', 'Reason'),
    ],
    totals: {
      'qty': 'Wheels',
      'returns': 'Returns',
      'pending': 'Awaiting QA',
      'restocked': 'Restocked',
      'scrapped': 'Scrapped',
    },
  ),
  'stock-movements': DplStockReportSpec(
    key: 'stock-movements',
    label: 'Stock movements',
    rowsKey: 'lines',
    dateRange: true,
    columns: [
      DplReportColumn('movement_date', 'Date'),
      DplReportColumn('movement_type', 'Type'),
      DplReportColumn('document_no', 'Document'),
      DplReportColumn('customer_part_no', 'Item code'),
      DplReportColumn('lot_no', 'Lot'),
      DplReportColumn('qty', 'Qty', numeric: true),
      DplReportColumn('user_name', 'By'),
      DplReportColumn('note', 'Note'),
    ],
    totals: {'lines': 'Movements', 'net_qty': 'Net qty'},
  ),
};

/// The totals to show for [spec]: the configured ones present in [totals],
/// or, when none of those came back, every scalar number the server sent.
List<({String label, String value})> dplReportTotalsTiles(DplStockReportSpec spec, Map<String, dynamic> totals) {
  String fmt(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
  num? asNum(dynamic v) => v is num ? v : num.tryParse(v?.toString() ?? '');

  final configured = <({String label, String value})>[];
  spec.totals.forEach((k, label) {
    final n = asNum(totals[k]);
    if (n != null) configured.add((label: label, value: fmt(n)));
  });
  if (configured.isNotEmpty) return configured;

  return [
    for (final e in totals.entries)
      if (e.value is num) (label: e.key.replaceAll('_', ' '), value: fmt(e.value as num)),
  ];
}

/// Hub for the seven tabular stock and dispatch reports: pick one, see its
/// totals and a scrollable table, download the full sheet as Excel.
class DplStockReportsScreen extends ConsumerStatefulWidget {
  final bool showAppBar;

  const DplStockReportsScreen({super.key, this.showAppBar = true});

  @override
  ConsumerState<DplStockReportsScreen> createState() => _DplStockReportsScreenState();
}

class _DplStockReportsScreenState extends ConsumerState<DplStockReportsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late DateTimeRange _range;
  bool _downloading = false;

  final List<DplStockReportSpec> _specs = dplStockReportSpecs.values.toList();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _range = DateTimeRange(start: today, end: today);
    _tabs = TabController(length: _specs.length, vsync: this)..addListener(_onTab);
  }

  void _onTab() {
    if (!_tabs.indexIsChanging && mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTab);
    _tabs.dispose();
    super.dispose();
  }

  DplStockReportSpec get _spec => _specs[_tabs.index];

  DplReportRequest _requestFor(DplStockReportSpec s) => (
        key: s.key,
        rowsKey: s.rowsKey,
        from: s.dateRange ? ymd(_range.start) : null,
        to: s.dateRange ? ymd(_range.end) : null,
      );

  Future<void> _download() async {
    final s = _spec;
    setState(() => _downloading = true);
    final from = ymd(_range.start);
    final to = ymd(_range.end);
    final res = await ref.read(dplApiServiceProvider).getReportXlsx(
          s.key,
          query: s.dateRange ? {'from': from, 'to': to} : null,
        );
    if (!mounted) return;
    setState(() => _downloading = false);
    // Undated reports are a snapshot as of today, so the file name says so.
    final today = ymd(DateTime.now());
    final name = s.dateRange ? '${s.key}-${from}_$to.xlsx' : '${s.key}-${today}_$today.xlsx';
    await saveServerFile(context, res, fileName: name, mimeType: xlsxMime);
  }

  @override
  Widget build(BuildContext context) {
    final tabBar = TabBar(
      controller: _tabs,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      labelColor: DplColors.primary,
      unselectedLabelColor: DplColors.textSecondary,
      indicatorColor: DplColors.primary,
      tabs: [for (final s in _specs) Tab(text: s.label)],
    );

    final body = Column(
      children: [
        if (!widget.showAppBar) Material(color: Colors.white, child: tabBar),
        _toolbar(),
        Expanded(child: _reportBody(_spec)),
      ],
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Stock reports',
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(kTextTabBarHeight),
          child: Material(color: Colors.white, child: tabBar),
        ),
      ),
      body: body,
    );
  }

  Widget _toolbar() {
    final s = _spec;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(DplSpacing.md, DplSpacing.sm, DplSpacing.md, DplSpacing.sm),
      child: Row(
        children: [
          if (s.dateRange)
            Flexible(child: DplDateRangeBar(range: _range, onChanged: (r) => setState(() => _range = r)))
          else
            Flexible(child: Text('As of now', style: DplText.bodySm().copyWith(color: DplColors.textSecondary))),
          const Spacer(),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(dplReportTableProvider(_requestFor(s))),
          ),
          FilledButton.tonalIcon(
            onPressed: _downloading ? null : _download,
            icon: _downloading
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download, size: 18),
            label: const Text('Excel'),
          ),
        ],
      ),
    );
  }

  Widget _reportBody(DplStockReportSpec spec) {
    final req = _requestFor(spec);
    final async = ref.watch(dplReportTableProvider(req));
    Future<void> refresh() => ref.refresh(dplReportTableProvider(req).future);

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => DplInlineErrorRetry(message: e.toString(), onRetry: refresh),
      data: (res) {
        if (res.isError || res.data == null) {
          return DplInlineErrorRetry(
            message: res.floorMessage.isEmpty ? 'Could not load the report.' : res.floorMessage,
            onRetry: refresh,
          );
        }
        final table = res.data!;
        final tiles = dplReportTotalsTiles(spec, table.totals);
        return RefreshIndicator(
          onRefresh: refresh,
          child: ListView(
            padding: const EdgeInsets.all(DplSpacing.md),
            children: [
              if (tiles.isNotEmpty)
                DplCard(
                  margin: const EdgeInsets.only(bottom: DplSpacing.md),
                  child: Wrap(
                    spacing: DplSpacing.xl,
                    runSpacing: DplSpacing.md,
                    children: [for (final t in tiles) DplStatTile(label: t.label, value: t.value)],
                  ),
                ),
              if (table.rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: DplSpacing.xxl),
                  child: DplEmptyView(
                    title: 'Nothing to show',
                    message: 'This report has no rows for the chosen filters.',
                    icon: Icons.table_rows_outlined,
                  ),
                )
              else
                DplCard(
                  padding: EdgeInsets.zero,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      headingRowHeight: 40,
                      dataRowMinHeight: 36,
                      dataRowMaxHeight: 48,
                      columnSpacing: DplSpacing.xl,
                      headingTextStyle: DplText.bodySm().copyWith(fontWeight: FontWeight.w700),
                      columns: [
                        for (final c in spec.columns) DataColumn(label: Text(c.label), numeric: c.numeric),
                      ],
                      rows: [
                        for (final r in table.rows)
                          DataRow(cells: [
                            for (final c in spec.columns)
                              DataCell(ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 260),
                                child: Text(table.cell(r, c), overflow: TextOverflow.ellipsis),
                              )),
                          ]),
                      ],
                    ),
                  ),
                ),
              if (table.rows.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: DplSpacing.sm),
                  child: Text(
                    '${table.rows.length} rows · the Excel download has every column.',
                    style: DplText.caption(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
