import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../../../core/widgets/shimmer_skeleton.dart';
import '../../../reports/report_download_stub.dart'
    if (dart.library.html) '../../../reports/report_download_web.dart'
    if (dart.library.io) '../../../reports/report_download_io.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_constants.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_refresh_icon_button.dart';
import '../../models/dpl_downtime_event_detail.dart';
import '../../models/dpl_machine.dart';
import '../../models/dpl_monthly_chart.dart';
import '../../models/dpl_reports.dart';
import '../providers/dpl_daily_log_report_provider.dart';
import '../providers/dpl_masters_provider.dart';
import '../providers/dpl_monthly_chart_provider.dart';
import '../services/dpl_chart_excel_exporter.dart';
import '../services/dpl_chart_style_tokens.dart';
import '../services/dpl_daily_log_exporter.dart';
import '../services/dpl_downtime_exporter.dart';
import '../services/dpl_downtime_matrix_exporter.dart';
import '../providers/dpl_reports_provider.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_retry.dart';
import '../../summary/widgets/buffer_plan_download_sheet.dart';

// =============================================================================
// Tokens
// =============================================================================

Color get _kPrimary => VistarPalette.info;
Color get _kGood => VistarPalette.ok;
Color get _kWarn => VistarPalette.warn;
Color get _kBad => VistarPalette.bad;
Color get _kNeutral => DplColors.textSecondary;
Color get _kBorder => DplColors.divider;
Color get _kSurfaceAlt => VistarPalette.surface2;
const _kMobileBreakpoint = 600.0;

// The Monthly Chart grid mirrors the Excel export 1:1 (DplChartTokens'
// pastel bands, which are fixed), so it stays a light "sheet" in both
// modes and keeps its own light-mode ink.
const _kSheetInk = Colors.black87;
const _kSheetMuted = Color(0xFF5D6A7A);
const _kSheetBorder = Color(0xFFE2EAF6);
const _kSheetPlan = Color(0xFF1D4ED8);
const _kSheetActual = Color(0xFF047857);
const _kSheetDowntime = Color(0xFFB45309);

Color _achievementColor(double pct) {
  if (pct >= 1.0) return _kPrimary;
  if (pct >= 0.9) return _kGood;
  if (pct >= 0.7) return _kWarn;
  return _kBad;
}

String _formatHrsMin(int totalMinutes) {
  if (totalMinutes <= 0) return '0h';
  final h = totalMinutes ~/ 60;
  final m = totalMinutes % 60;
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

bool _isMobile(BuildContext context) =>
    MediaQuery.of(context).size.width < _kMobileBreakpoint;

// =============================================================================
// Screen
// =============================================================================

class DplReportsScreen extends ConsumerStatefulWidget {
  final bool embedded;

  const DplReportsScreen({super.key, this.embedded = false});

  @override
  ConsumerState<DplReportsScreen> createState() => _DplReportsScreenState();
}

class _DplReportsScreenState extends ConsumerState<DplReportsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  int _currentTab = 0;
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 7, vsync: this);
    // Track active tab so the AppBar download icon dispatches correctly.
    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging) return;
      if (_currentTab != _tabCtrl.index) {
        setState(() => _currentTab = _tabCtrl.index);
      }
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  /// Tab-aware export. Tab 1 (Monthly Chart) and tab 6 (Daily Log)
  /// are built entirely client-side from live provider data; every
  /// other tab hits the server-side `/reports/export` endpoint with
  /// the appropriate `type=` slug.
  Future<void> _downloadActiveTab({String format = DplReportFormat.xlsx}) async {
    setState(() => _isDownloading = true);
    try {
      if (_currentTab == 1) {
        // Monthly Chart — client-side, reads live provider data.
        // Only Excel is supported for the custom company format.
        final async = ref.read(dplMonthlyChartProvider);
        final chartRes = async.asData?.value;
        final chart = chartRes?.data;
        if (chart == null || chart.days.isEmpty) {
          if (!mounted) return;
          DplSnack.error(
            context,
            'No chart data to export — load a month first.',
          );
          return;
        }
        final bytes = DplChartExcelExporter.build(chart);
        final monthLabel = DateFormat('yyyy_MM').format(chart.from);
        final fileName = 'dpl_monthly_chart_$monthLabel.xlsx';
        final path = await saveReportBytes(
          bytes: bytes,
          fileName: fileName,
          mimeType:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        );
        if (!mounted) return;
        DplSnack.success(
          context,
          path == null ? 'Downloaded.' : 'Saved: $path',
        );
        return;
      }

      if (_currentTab == 3) {
        // Downtime — client-side. Routes to the active sub-view's
        // exporter so the file always matches what the user is looking
        // at. Both branches re-fetch their provider via `.future` so
        // the autoDispose lifecycle (the unwatched sub-view's provider
        // may have been disposed) doesn't surface as an empty cache.
        final subView = ref.read(dplDowntimeSubViewProvider);
        final range = ref.read(dplReportRangeProvider);

        if (subView == DplDowntimeSubView.reasonMatrix) {
          final res = await ref.read(dplDowntimeEventsProvider.future);
          final events = res.data ?? const <DplDowntimeEventDetail>[];
          final matrix = DplDowntimeMatrix.fromEvents(events);
          if (matrix.isEmpty) {
            if (!mounted) return;
            DplSnack.error(
              context,
              'No downtime events to export for this range.',
            );
            return;
          }
          final isCsv = format == DplReportFormat.csv;
          // PDF is not supported for the matrix view — fall back to
          // Excel so the user's tap still produces a file. The popup
          // menu hides PDF when this sub-view is active (see build),
          // but a stray cached selection should still degrade safely.
          final bytes = isCsv
              ? DplDowntimeMatrixExporter.buildCsv(
                  matrix,
                  from: range.from,
                  to: range.to,
                )
              : DplDowntimeMatrixExporter.buildExcel(
                  matrix,
                  from: range.from,
                  to: range.to,
                );
          final ext = isCsv ? 'csv' : 'xlsx';
          final mime = isCsv
              ? 'text/csv'
              : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
          final fileName =
              'dpl_downtime_reason_matrix_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.$ext';
          final path = await saveReportBytes(
            bytes: bytes,
            fileName: fileName,
            mimeType: mime,
          );
          if (!mounted) return;
          DplSnack.success(
            context,
            path == null ? 'Downloaded.' : 'Saved: $path',
          );
          return;
        }

        // Summary sub-view (default).
        final res = await ref.read(dplDowntimeByDateReportProvider.future);
        final report = res.data;
        if (report == null || report.isEmpty) {
          if (!mounted) return;
          DplSnack.error(
            context,
            'No downtime data to export for this range.',
          );
          return;
        }
        final isPdf = format == DplReportFormat.pdf;
        final bytes = isPdf
            ? await DplDowntimeExporter.buildPdf(
                report,
                from: range.from,
                to: range.to,
              )
            : DplDowntimeExporter.buildExcel(
                report,
                from: range.from,
                to: range.to,
              );
        final ext = isPdf ? 'pdf' : 'xlsx';
        final mime = isPdf
            ? 'application/pdf'
            : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
        final fileName =
            'dpl_downtime_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.$ext';
        final path = await saveReportBytes(
          bytes: bytes,
          fileName: fileName,
          mimeType: mime,
        );
        if (!mounted) return;
        DplSnack.success(
          context,
          path == null ? 'Downloaded.' : 'Saved: $path',
        );
        return;
      }

      if (_currentTab == 6) {
        // Daily Log — client-side, walks the in-memory plan/item rows.
        final async = ref.read(dplDailyLogReportProvider);
        final res = async.asData?.value;
        final report = res?.data;
        if (report == null || report.isEmpty) {
          if (!mounted) return;
          DplSnack.error(
            context,
            'No daily log data to export for this range.',
          );
          return;
        }
        final range = ref.read(dplReportRangeProvider);
        final isPdf = format == DplReportFormat.pdf;
        final bytes = isPdf
            ? await DplDailyLogExporter.buildPdf(
                report,
                from: range.from,
                to: range.to,
              )
            : DplDailyLogExporter.buildExcel(
                report,
                from: range.from,
                to: range.to,
              );
        final ext = isPdf ? 'pdf' : 'xlsx';
        final mime = isPdf
            ? 'application/pdf'
            : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
        final fileName =
            'dpl_daily_log_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.$ext';
        final path = await saveReportBytes(
          bytes: bytes,
          fileName: fileName,
          mimeType: mime,
        );
        if (!mounted) return;
        DplSnack.success(
          context,
          path == null ? 'Downloaded.' : 'Saved: $path',
        );
        return;
      }

      // Server-side export for the remaining tabs. (Tabs 1, 3, and 6
      // are handled above with client-side exporters.)
      final type = switch (_currentTab) {
        0 => 'plan-vs-actual', // Overview
        2 => 'plan-vs-actual', // Machines
        4 => 'supervisor-performance',
        5 => 'part-wise',
        _ => 'plan-vs-actual',
      };
      await _exportReport(context, ref, type: type, format: format);
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mobile = _isMobile(context);

    final body = NestedScrollView(
      headerSliverBuilder: (context, innerBoxIsScrolled) => [
        SliverToBoxAdapter(
          child: Column(
            children: [
              const _RangeBar(),
              const _MachineFilterBar(),
              const _AtAGlanceStrip(),
            ],
          ),
        ),
        SliverPersistentHeader(
          pinned: true,
          delegate: _StickyTabBar(
            child: Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: TabBar(
                controller: _tabCtrl,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: _kPrimary,
                unselectedLabelColor: _kNeutral,
                indicatorColor: _kPrimary,
                indicatorWeight: 3,
                labelPadding: EdgeInsets.symmetric(
                  horizontal: mobile ? 12 : 18,
                ),
                tabs: mobile
                    ? const [
                        Tab(icon: Icon(Icons.dashboard_outlined), text: 'Home'),
                        Tab(icon: Icon(Icons.grid_on_outlined), text: 'Chart'),
                        Tab(
                            icon: Icon(Icons.precision_manufacturing_outlined),
                            text: 'Mach.'),
                        Tab(
                            icon: Icon(Icons.timer_off_outlined),
                            text: 'Down.'),
                        Tab(
                            icon: Icon(Icons.supervisor_account_outlined),
                            text: 'Sup.'),
                        Tab(
                            icon: Icon(Icons.inventory_2_outlined),
                            text: 'Parts'),
                        Tab(
                            icon: Icon(Icons.event_note_outlined),
                            text: 'Log'),
                      ]
                    : const [
                        Tab(
                            icon: Icon(Icons.dashboard_outlined),
                            text: 'Overview'),
                        Tab(
                            icon: Icon(Icons.grid_on_outlined),
                            text: 'Monthly Chart'),
                        Tab(
                            icon: Icon(Icons.precision_manufacturing_outlined),
                            text: 'Machines'),
                        Tab(
                            icon: Icon(Icons.timer_off_outlined),
                            text: 'Downtime'),
                        Tab(
                            icon: Icon(Icons.supervisor_account_outlined),
                            text: 'Supervisors'),
                        Tab(
                            icon: Icon(Icons.inventory_2_outlined),
                            text: 'Parts'),
                        Tab(
                            icon: Icon(Icons.event_note_outlined),
                            text: 'Daily Log'),
                      ],
              ),
            ),
          ),
        ),
      ],
      body: TabBarView(
        controller: _tabCtrl,
        children: const [
          _OverviewTab(),
          _MonthlyChartTab(),
          _MachinesTab(),
          _DowntimeTab(),
          _SupervisorsTab(),
          _PartsTab(),
          _DailyLogTab(),
        ],
      ),
    );

    final scaffold = Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Reports',
        actions: [
          IconButton(
            tooltip: 'Download Buffer Creation Plan (all plants)',
            icon: const Icon(Icons.calendar_view_month_outlined),
            onPressed: () => BufferPlanDownloadSheet.show(context),
          ),
          PopupMenuButton<String>(
            tooltip: 'Download',
            enabled: !_isDownloading,
            icon: _isDownloading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: DplColors.primary,
                    ),
                  )
                : const Icon(Icons.download_outlined),
            onSelected: (value) => _downloadActiveTab(format: value),
            itemBuilder: (context) {
              // Downtime → Reason Matrix offers Excel + CSV (no PDF).
              // Every other tab offers Excel and (except the chart tab)
              // PDF.
              final onMatrix = _currentTab == 3 &&
                  ref.read(dplDowntimeSubViewProvider) ==
                      DplDowntimeSubView.reasonMatrix;
              return [
                const PopupMenuItem(
                  value: DplReportFormat.xlsx,
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.table_view_outlined),
                    title: Text('Download Excel'),
                  ),
                ),
                if (onMatrix)
                  const PopupMenuItem(
                    value: DplReportFormat.csv,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.description_outlined),
                      title: Text('Download CSV'),
                    ),
                  ),
                if (!onMatrix && _currentTab != 1)
                  const PopupMenuItem(
                    value: DplReportFormat.pdf,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.picture_as_pdf_outlined),
                      title: Text('Download PDF'),
                    ),
                  ),
              ];
            },
          ),
          DplRefreshIconButton(
            tooltip: 'Refresh all',
            onRefresh: () async {
              ref.invalidate(dplPlanVsActualReportProvider);
              ref.invalidate(dplDowntimeReportProvider);
              ref.invalidate(dplSupervisorPerformanceReportProvider);
              ref.invalidate(dplPartWiseReportProvider);
              ref.invalidate(dplMonthlyChartProvider);
              // Hold the spinner until at least one fetch completes
              // so the user sees the icon morph back when fresh data
              // is on screen, not the instant they tap.
              try {
                await Future.wait([
                  ref.read(dplPlanVsActualReportProvider.future),
                  ref.read(dplMonthlyChartProvider.future),
                ]);
              } catch (_) {
                // Errors surface inline through the per-tab state.
              }
            },
          ),
        ],
      ),
      body: body,
    );

    // `widget.embedded` is kept on the constructor for backwards-
    // compat, but the manager shell now always mounts this screen
    // standalone so the AppBar (with the download icon) is visible.
    return scaffold;
  }
}

/// Pinned TabBar helper.
class _StickyTabBar extends SliverPersistentHeaderDelegate {
  final Widget child;
  const _StickyTabBar({required this.child});

  @override
  double get minExtent => 52;
  @override
  double get maxExtent => 52;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        border: Border(bottom: BorderSide(color: _kBorder)),
      ),
      child: child,
    );
  }

  @override
  bool shouldRebuild(_StickyTabBar oldDelegate) => false;
}

// =============================================================================
// Sticky filters (range + machine) — drive every tab
// =============================================================================

class _RangeBar extends ConsumerWidget {
  const _RangeBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(dplReportRangeProvider);
    final fmt = DateFormat('dd MMM');

    Future<void> pickRange({required bool isFrom}) async {
      final picked = await showDatePicker(
        context: context,
        initialDate: (isFrom ? range.from : range.to) ?? DateTime.now(),
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
      );
      if (picked == null) return;
      ref.read(dplReportRangeProvider.notifier).set(
            DplReportRange(
              from: isFrom ? picked : range.from,
              to: isFrom ? range.to : picked,
              machineId: range.machineId,
            ),
          );
    }

    Future<void> quickRange(int days) async {
      final today = DateTime.now();
      final from = DateTime(today.year, today.month, today.day - (days - 1));
      ref.read(dplReportRangeProvider.notifier).set(
            DplReportRange(
              from: from,
              to: DateTime(today.year, today.month, today.day),
              machineId: range.machineId,
            ),
          );
    }

    void mtd() {
      final today = DateTime.now();
      ref.read(dplReportRangeProvider.notifier).set(
            DplReportRange(
              from: DateTime(today.year, today.month, 1),
              to: DateTime(today.year, today.month, today.day),
              machineId: range.machineId,
            ),
          );
    }

    final rangeLabel = range.from == null && range.to == null
        ? 'All time'
        : '${range.from == null ? "…" : fmt.format(range.from!)} → '
            '${range.to == null ? "…" : fmt.format(range.to!)}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      color: DplColors.pageBg,
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () async {
                await pickRange(isFrom: true);
                if (!context.mounted) return;
                await pickRange(isFrom: false);
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: DplColors.cardBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _kBorder),
                ),
                child: Row(
                  children: [
                    Icon(Icons.date_range, size: 18, color: _kPrimary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        rangeLabel,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(Icons.expand_more,
                        size: 18, color: _kNeutral),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _quickChip('7D', () => quickRange(7)),
          const SizedBox(width: 6),
          _quickChip('30D', () => quickRange(30)),
          const SizedBox(width: 6),
          _quickChip('MTD', mtd),
          if (range.from != null || range.to != null) ...[
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Clear range',
              icon: Icon(Icons.clear, size: 18, color: _kNeutral),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () => ref
                  .read(dplReportRangeProvider.notifier)
                  .set(const DplReportRange()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _quickChip(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: DplColors.cardBg,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 12,
            color: _kNeutral,
          ),
        ),
      ),
    );
  }
}

class _MachineFilterBar extends ConsumerWidget {
  const _MachineFilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machinesAsync = ref.watch(dplMachinesProvider);
    final range = ref.watch(dplReportRangeProvider);
    final selected = range.machineId;

    return machinesAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (res) {
        if (res.isError) return const SizedBox.shrink();
        final machines = res.data ?? const <DplMachine>[];
        if (machines.isEmpty) return const SizedBox.shrink();

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          color: DplColors.pageBg,
          child: SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _filterChip(
                  label: 'All machines',
                  selected: selected == null,
                  onTap: () => ref
                      .read(dplReportRangeProvider.notifier)
                      .set(DplReportRange(
                        from: range.from,
                        to: range.to,
                      )),
                ),
                const SizedBox(width: 6),
                for (final m in machines) ...[
                  _filterChip(
                    label: m.name,
                    selected: selected == m.id,
                    onTap: () => ref
                        .read(dplReportRangeProvider.notifier)
                        .set(DplReportRange(
                          from: range.from,
                          to: range.to,
                          machineId: m.id,
                        )),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _filterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? VistarPalette.infoSolid : DplColors.cardBg,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? VistarPalette.infoSolid : _kBorder,
            ),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12,
              color: selected ? Colors.white : _kNeutral,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// At-a-glance KPI strip — responsive
// =============================================================================

class _AtAGlanceStrip extends ConsumerWidget {
  const _AtAGlanceStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pvaAsync = ref.watch(dplPlanVsActualReportProvider);
    final dtAsync = ref.watch(dplDowntimeReportProvider);
    final fmt = NumberFormat.decimalPattern();

    final report = pvaAsync.asData?.value.data ??
        DplPlanVsActualReport.empty();
    final downtime =
        dtAsync.asData?.value.data ?? DplDowntimeReport.empty();
    final totalDowntimeMin =
        downtime.rows.fold<int>(0, (s, r) => s + r.totalMinutes);

    final cards = <Widget>[
      _KpiCard(
        label: 'Plan',
        value: fmt.format(report.totalPlan),
        icon: Icons.flag_outlined,
        color: _kPrimary,
      ),
      _KpiCard(
        label: 'Actual',
        value: fmt.format(report.totalActual),
        icon: Icons.check_circle_outline,
        color: _kGood,
      ),
      _KpiCard(
        label: 'Achievement',
        value: '${(report.completionPct * 100).round()}%',
        icon: Icons.trending_up,
        color: _achievementColor(report.completionPct),
      ),
      _KpiCard(
        label: 'Downtime',
        value: _formatHrsMin(totalDowntimeMin),
        icon: Icons.timer_off_outlined,
        color: _kWarn,
      ),
    ];

    final mobile = _isMobile(context);
    return Container(
      color: DplColors.pageBg,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: mobile
          ? SizedBox(
              height: 84,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: cards.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (_, i) => SizedBox(width: 160, child: cards[i]),
              ),
            )
          : GridView.count(
              crossAxisCount: 4,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 2.4,
              children: cards,
            ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _KpiCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: _kNeutral,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Shared section header + small bits
// =============================================================================

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  const _SectionHeader({
    required this.icon,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: _kPrimary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }
}

class _AchievementRing extends StatelessWidget {
  final double pct;
  final String label;
  final Color color;
  final double size;

  const _AchievementRing({
    required this.pct,
    required this.label,
    required this.color,
    this.size = 56,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: pct.clamp(0.0, 1.0),
              strokeWidth: 5,
              backgroundColor: VistarPalette.surface3,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: size * 0.22,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniKv extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _MiniKv({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: _kNeutral,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 14,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _RankBadge extends StatelessWidget {
  final int rank;
  const _RankBadge({required this.rank});

  @override
  Widget build(BuildContext context) {
    final colors = [
      const Color(0xFFFBBF24),
      const Color(0xFFCBD5E1),
      const Color(0xFFB45309),
    ];
    final color = rank <= 3 ? colors[rank - 1] : _kBorder;
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1.4),
      ),
      child: Text(
        '$rank',
        style: const TextStyle(
          fontWeight: FontWeight.w900,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _EmptyScroll extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  const _EmptyScroll({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 60),
        DplEmptyState(icon: icon, title: title, message: message),
      ],
    );
  }
}

// =============================================================================
// Export helper
// =============================================================================

Future<void> _exportReport(
  BuildContext context,
  WidgetRef ref, {
  required String type,
  String format = DplReportFormat.xlsx,
}) async {
  final range = ref.read(dplReportRangeProvider);
  final res = await ref.read(dplApiServiceProvider).exportReportBytes(
        type: type,
        format: format,
        from: range.from,
        to: range.to,
        machineId: range.machineId,
      );
  if (!context.mounted) return;

  if (res.isError) {
    DplSnack.error(context, res.error ?? 'Failed to export report.');
    return;
  }
  try {
    final ext = format == DplReportFormat.pdf
        ? 'pdf'
        : format == DplReportFormat.csv
            ? 'csv'
            : 'xlsx';
    final mime = format == DplReportFormat.pdf
        ? 'application/pdf'
        : format == DplReportFormat.csv
            ? 'text/csv'
            : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    final fileName =
        'dpl_${type.replaceAll('-', '_')}_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.$ext';
    final path = await saveReportBytes(
      bytes: res.data!,
      fileName: fileName,
      mimeType: mime,
    );
    if (!context.mounted) return;
    DplSnack.success(context, path == null ? 'Exported.' : 'Saved: $path');
  } catch (e) {
    if (!context.mounted) return;
    DplSnack.error(context, 'Saved but could not write file: $e');
  }
}

// =============================================================================
// Tab 1 — Overview
// =============================================================================

class _OverviewTab extends ConsumerWidget {
  const _OverviewTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pvaAsync = ref.watch(dplPlanVsActualReportProvider);
    final dtAsync = ref.watch(dplDowntimeReportProvider);
    final svAsync = ref.watch(dplSupervisorPerformanceReportProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(dplPlanVsActualReportProvider);
        ref.invalidate(dplDowntimeReportProvider);
        ref.invalidate(dplSupervisorPerformanceReportProvider);
        ref.invalidate(dplPartWiseReportProvider);
        await ref.read(dplPlanVsActualReportProvider.future);
      },
      child: pvaAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: SkeletonList(count: 4),
        ),
        error: (e, _) => DplErrorRetry(
          message: e.toString(),
          onRetry: () => ref.invalidate(dplPlanVsActualReportProvider),
        ),
        data: (res) {
          if (res.isError) {
            return DplErrorRetry(
              message: res.error ?? 'Failed to load overview.',
              onRetry: () => ref.invalidate(dplPlanVsActualReportProvider),
            );
          }
          final pva = res.data ?? DplPlanVsActualReport.empty();

          // Roll up rows by machine (we may have per-day rows from group_by=day).
          final byMachine = <int, _MachineRollup>{};
          for (final r in pva.rows) {
            final acc = byMachine.putIfAbsent(
              r.machineId,
              () => _MachineRollup(
                machineId: r.machineId,
                machineName: r.machineName,
              ),
            );
            acc.planQty += r.planQty;
            acc.actualQty += r.actualQty;
          }
          final machines = byMachine.values.toList()
            ..sort((a, b) => b.actualQty.compareTo(a.actualQty));

          if (machines.isEmpty) {
            return const _EmptyScroll(
              icon: Icons.bar_chart_outlined,
              title: 'No data for this range',
              message:
                  'Pick a wider date range or wait for production to be logged.',
            );
          }

          final downtime =
              dtAsync.asData?.value.data ?? DplDowntimeReport.empty();
          final supervisors = svAsync.asData?.value.data ??
              DplSupervisorPerformanceReport.empty();

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _SectionHeader(
                icon: Icons.precision_manufacturing_outlined,
                title: 'Machine performance',
              ),
              const SizedBox(height: 8),
              for (final m in machines) ...[
                _MachineOverviewCard(rollup: m),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 12),
              _SectionHeader(
                icon: Icons.warning_amber_outlined,
                title: 'Top downtime reasons',
              ),
              const SizedBox(height: 8),
              _TopDowntimeReasons(report: downtime),
              const SizedBox(height: 16),
              _SectionHeader(
                icon: Icons.emoji_events_outlined,
                title: 'Top performers',
              ),
              const SizedBox(height: 8),
              _TopPerformers(supervisors: supervisors, machines: machines),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Export overview to Excel'),
                  onPressed: () =>
                      _exportReport(context, ref, type: 'plan-vs-actual'),
                ),
              ),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }
}

class _MachineRollup {
  final int machineId;
  final String machineName;
  int planQty = 0;
  int actualQty = 0;

  _MachineRollup({
    required this.machineId,
    required this.machineName,
  });

  double get completionPct => planQty <= 0 ? 0 : actualQty / planQty;
  int get variance => actualQty - planQty;
}

class _MachineOverviewCard extends StatelessWidget {
  final _MachineRollup rollup;
  const _MachineOverviewCard({required this.rollup});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final pct = (rollup.completionPct * 100).round();
    final color = _achievementColor(rollup.completionPct);
    final variance = rollup.variance;
    final varianceLabel = variance >= 0 ? '+$variance' : variance.toString();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _AchievementRing(
            pct: rollup.completionPct,
            label: '$pct%',
            color: color,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rollup.machineName.isEmpty
                      ? 'Machine #${rollup.machineId}'
                      : rollup.machineName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    _MiniKv(label: 'Plan', value: fmt.format(rollup.planQty)),
                    _MiniKv(
                      label: 'Actual',
                      value: fmt.format(rollup.actualQty),
                      color: _kGood,
                    ),
                    _MiniKv(
                      label: 'Var',
                      value: varianceLabel,
                      color: variance >= 0 ? _kGood : _kBad,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: rollup.completionPct,
                    minHeight: 5,
                    backgroundColor: VistarPalette.surface3,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopDowntimeReasons extends StatelessWidget {
  final DplDowntimeReport report;
  const _TopDowntimeReasons({required this.report});

  @override
  Widget build(BuildContext context) {
    if (report.rows.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: DplColors.cardBg,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, color: _kGood),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'No downtime logged in this range.',
                style: TextStyle(color: _kNeutral, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    }

    final sorted = [...report.rows]
      ..sort((a, b) => b.totalMinutes.compareTo(a.totalMinutes));
    final top = sorted.take(5).toList();
    final maxMin = top.first.totalMinutes;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          for (final r in top) ...[
            _DowntimeReasonRow(row: r, maxMinutes: maxMin),
            if (r != top.last)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Divider(height: 1),
              ),
          ],
        ],
      ),
    );
  }
}

class _DowntimeReasonRow extends StatelessWidget {
  final DplDowntimeRow row;
  final int maxMinutes;
  const _DowntimeReasonRow({required this.row, required this.maxMinutes});

  @override
  Widget build(BuildContext context) {
    final isPlanned = row.category == DplDowntimeCategory.planned;
    final color = isPlanned ? _kPrimary : _kWarn;
    final ratio = maxMinutes == 0 ? 0.0 : row.totalMinutes / maxMinutes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                isPlanned ? 'Planned' : 'Unplanned',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 10,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                row.reasonName.isEmpty ? 'Reason' : row.reasonName,
                style: const TextStyle(fontWeight: FontWeight.w800),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              _formatHrsMin(row.totalMinutes),
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: ratio.clamp(0.0, 1.0),
            minHeight: 4,
            backgroundColor: VistarPalette.surface3,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${row.occurrences} event${row.occurrences == 1 ? "" : "s"}'
          '${row.avgMinutes > 0 ? "  •  avg ${row.avgMinutes.toStringAsFixed(1)} min" : ""}',
          style: TextStyle(color: _kNeutral, fontSize: 11),
        ),
      ],
    );
  }
}

class _TopPerformers extends StatelessWidget {
  final DplSupervisorPerformanceReport supervisors;
  final List<_MachineRollup> machines;
  const _TopPerformers({required this.supervisors, required this.machines});

  @override
  Widget build(BuildContext context) {
    final svRows = [...supervisors.rows]
      ..sort((a, b) => b.completionPct.compareTo(a.completionPct));
    final topSv = svRows.take(3).toList();
    final mcRows = [...machines]
      ..sort((a, b) => b.actualQty.compareTo(a.actualQty));
    final topMc = mcRows.take(3).toList();

    return Container(
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          _PerformerSection(
            title: 'Supervisors',
            icon: Icons.person_outline,
            isEmpty: topSv.isEmpty,
            isEmptyMessage: 'No supervisor data yet.',
            child: Column(
              children: [
                for (var i = 0; i < topSv.length; i++) ...[
                  _SupervisorRow(rank: i + 1, row: topSv[i]),
                  if (i != topSv.length - 1) const Divider(height: 14),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          _PerformerSection(
            title: 'Machines',
            icon: Icons.precision_manufacturing_outlined,
            isEmpty: topMc.isEmpty,
            isEmptyMessage: 'No machine data yet.',
            child: Column(
              children: [
                for (var i = 0; i < topMc.length; i++) ...[
                  _MachinePerformerRow(rank: i + 1, rollup: topMc[i]),
                  if (i != topMc.length - 1) const Divider(height: 14),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PerformerSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final bool isEmpty;
  final String isEmptyMessage;
  const _PerformerSection({
    required this.title,
    required this.icon,
    required this.child,
    required this.isEmpty,
    required this.isEmptyMessage,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: _kNeutral),
              const SizedBox(width: 6),
              Text(
                title.toUpperCase(),
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: _kNeutral,
                  letterSpacing: 0.6,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (isEmpty)
            Text(
              isEmptyMessage,
              style: TextStyle(color: _kNeutral),
            )
          else
            child,
        ],
      ),
    );
  }
}

class _SupervisorRow extends StatelessWidget {
  final int rank;
  final DplSupervisorPerformanceRow row;
  const _SupervisorRow({required this.rank, required this.row});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final pct = (row.completionPct * 100).round();
    final color = _achievementColor(row.completionPct);
    return Row(
      children: [
        _RankBadge(rank: rank),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.supervisorName.isEmpty
                    ? 'User #${row.supervisorUserId}'
                    : row.supervisorName,
                style: const TextStyle(fontWeight: FontWeight.w800),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                '${fmt.format(row.totalActual)} / ${fmt.format(row.totalPlan)}'
                ' • ${row.plansHandled} plans',
                style: TextStyle(color: _kNeutral, fontSize: 12),
              ),
            ],
          ),
        ),
        Text(
          '$pct%',
          style: TextStyle(color: color, fontWeight: FontWeight.w900),
        ),
      ],
    );
  }
}

class _MachinePerformerRow extends StatelessWidget {
  final int rank;
  final _MachineRollup rollup;
  const _MachinePerformerRow({required this.rank, required this.rollup});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final pct = (rollup.completionPct * 100).round();
    final color = _achievementColor(rollup.completionPct);
    return Row(
      children: [
        _RankBadge(rank: rank),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                rollup.machineName.isEmpty
                    ? 'Machine #${rollup.machineId}'
                    : rollup.machineName,
                style: const TextStyle(fontWeight: FontWeight.w800),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                '${fmt.format(rollup.actualQty)} / ${fmt.format(rollup.planQty)}',
                style: TextStyle(color: _kNeutral, fontSize: 12),
              ),
            ],
          ),
        ),
        Text(
          '$pct%',
          style: TextStyle(color: color, fontWeight: FontWeight.w900),
        ),
      ],
    );
  }
}

// =============================================================================
// Tab 2 — Monthly Chart (mobile-friendly grid)
// =============================================================================

class _MonthlyChartTab extends ConsumerStatefulWidget {
  const _MonthlyChartTab();

  @override
  ConsumerState<_MonthlyChartTab> createState() => _MonthlyChartTabState();
}

class _MonthlyChartTabState extends ConsumerState<_MonthlyChartTab> {
  int? _focusMachineId; // null = show all
  bool _compact = false; // hide downtime rows when true

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(dplMonthlyChartProvider);
    final mobile = _isMobile(context);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(dplMonthlyChartProvider);
        await ref.read(dplMonthlyChartProvider.future);
      },
      child: async.when(
        // RefreshIndicator needs a scrollable child — wrap the skeleton
        // in a ListView so it scrolls within the viewport instead of
        // overflowing the bottom by ~113px.
        loading: () => ListView(
          padding: const EdgeInsets.all(16),
          children: const [SkeletonList(count: 4)],
        ),
        error: (e, _) => ListView(
          children: [
            DplErrorRetry(
              message: e.toString(),
              onRetry: () => ref.invalidate(dplMonthlyChartProvider),
            ),
          ],
        ),
        data: (res) {
          if (res.isError) {
            return ListView(
              children: [
                DplErrorRetry(
                  message: res.error ?? 'Failed to load monthly chart.',
                  onRetry: () => ref.invalidate(dplMonthlyChartProvider),
                ),
              ],
            );
          }
          final chart = res.data ??
              DplMonthlyChart.empty(DateTime.now(), DateTime.now());
          if (chart.days.isEmpty ||
              chart.machines.isEmpty ||
              chart.shifts.isEmpty) {
            return const _EmptyScroll(
              icon: Icons.grid_on_outlined,
              title: 'No chart data',
              message:
                  'Pick a month with logged production, or check that shifts + '
                  'machines exist in the masters.',
            );
          }

          // On mobile, default-focus the first machine for readability.
          if (mobile &&
              _focusMachineId == null &&
              chart.machines.isNotEmpty) {
            _focusMachineId = chart.machines.first.id;
          }

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _ChartCumulativeCard(chart: chart),
              const SizedBox(height: 10),
              _ChartToolbar(
                chart: chart,
                focusMachineId: _focusMachineId,
                compact: _compact,
                onFocusChanged: (v) =>
                    setState(() => _focusMachineId = v),
                onCompactChanged: (v) => setState(() => _compact = v),
              ),
              const SizedBox(height: 10),
              _ChartGrid(
                chart: chart,
                focusMachineId: mobile
                    ? (_focusMachineId ?? chart.machines.first.id)
                    : _focusMachineId,
                compact: _compact,
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

class _ChartCumulativeCard extends ConsumerWidget {
  final DplMonthlyChart chart;
  const _ChartCumulativeCard({required this.chart});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = chart.cumulative;
    final fmt = NumberFormat.decimalPattern();
    final pct = (c.achievementPct * 100).round();
    final lostPct = (c.lostPct * 100).round();
    final dateFmt = DateFormat('dd MMM');
    final mobile = _isMobile(context);

    final headerRow = Row(
      children: [
        Expanded(
          child: Text(
            '${dateFmt.format(chart.from)} → ${dateFmt.format(chart.to)}'
            '  •  ${chart.days.length}d',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
              color: _kNeutral,
            ),
          ),
        ),
        TextButton.icon(
          onPressed: () => _pickMonth(context, ref),
          icon: const Icon(Icons.calendar_month_outlined, size: 18),
          label: const Text('Month'),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );

    final cards = [
      _CumKv(
          label: 'Cum Plan',
          value: fmt.format(c.planQty),
          color: _kPrimary),
      _CumKv(
          label: 'Cum Actual',
          value: fmt.format(c.actualQty),
          color: _kGood),
      _CumKv(
          label: 'Achievement',
          value: '$pct%',
          color: _achievementColor(c.achievementPct)),
      _CumKv(
          label: 'Downtime',
          value: _formatHrsMin(c.totalDowntimeMinutes),
          color: _kWarn),
      _CumKv(
          label: 'Man-Hrs',
          value: c.totalManHours.toStringAsFixed(0),
          color: _kNeutral),
      _CumKv(
          label: 'Lost MH',
          value:
              '${c.totalLostManHours.toStringAsFixed(0)} ($lostPct%)',
          color: _kBad),
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          headerRow,
          const SizedBox(height: 10),
          mobile
              ? SizedBox(
                  height: 70,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: cards.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, i) =>
                        SizedBox(width: 130, child: cards[i]),
                  ),
                )
              : Wrap(
                  spacing: 14,
                  runSpacing: 8,
                  children: [
                    for (final c in cards) SizedBox(width: 130, child: c),
                  ],
                ),
        ],
      ),
    );
  }

  Future<void> _pickMonth(BuildContext context, WidgetRef ref) async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: chart.from,
      firstDate: DateTime(2020),
      lastDate: DateTime(today.year + 1, 12, 31),
      helpText: 'Pick any day in the target month',
    );
    if (picked == null) return;
    ref.read(dplMonthlyChartRangeProvider.notifier).setMonth(picked);
  }
}

class _CumKv extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _CumKv({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: _kNeutral,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w900,
            fontSize: 16,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _ChartToolbar extends StatelessWidget {
  final DplMonthlyChart chart;
  final int? focusMachineId;
  final bool compact;
  final ValueChanged<int?> onFocusChanged;
  final ValueChanged<bool> onCompactChanged;

  const _ChartToolbar({
    required this.chart,
    required this.focusMachineId,
    required this.compact,
    required this.onFocusChanged,
    required this.onCompactChanged,
  });

  @override
  Widget build(BuildContext context) {
    final mobile = _isMobile(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          // Machine focus dropdown
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int?>(
                value: focusMachineId,
                isExpanded: true,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: DplColors.textPrimary,
                ),
                items: [
                  if (!mobile)
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('All machines'),
                    ),
                  for (final m in chart.machines)
                    DropdownMenuItem<int?>(
                      value: m.id,
                      child: Text(m.name),
                    ),
                ],
                onChanged: onFocusChanged,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Compact toggle
          FilterChip(
            label: Text(compact ? 'Plan / Actual' : 'Plan / Actual / DT'),
            selected: compact,
            onSelected: onCompactChanged,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// Frozen left columns (shift + row label) + horizontally scrollable
/// day cells with synchronised vertical scrolling.
class _ChartGrid extends StatefulWidget {
  final DplMonthlyChart chart;
  final int? focusMachineId;
  final bool compact;

  const _ChartGrid({
    required this.chart,
    required this.focusMachineId,
    required this.compact,
  });

  @override
  State<_ChartGrid> createState() => _ChartGridState();
}

class _ChartGridState extends State<_ChartGrid> {
  final _hCtrl = ScrollController();
  final _vCtrlLeft = ScrollController();
  final _vCtrlRight = ScrollController();
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _vCtrlLeft.addListener(_syncLeftToRight);
    _vCtrlRight.addListener(_syncRightToLeft);
  }

  @override
  void dispose() {
    _vCtrlLeft.removeListener(_syncLeftToRight);
    _vCtrlRight.removeListener(_syncRightToLeft);
    _hCtrl.dispose();
    _vCtrlLeft.dispose();
    _vCtrlRight.dispose();
    super.dispose();
  }

  void _syncLeftToRight() {
    if (_syncing) return;
    if (!_vCtrlRight.hasClients) return;
    _syncing = true;
    _vCtrlRight.jumpTo(_vCtrlLeft.offset);
    _syncing = false;
  }

  void _syncRightToLeft() {
    if (_syncing) return;
    if (!_vCtrlLeft.hasClients) return;
    _syncing = true;
    _vCtrlLeft.jumpTo(_vCtrlRight.offset);
    _syncing = false;
  }

  @override
  Widget build(BuildContext context) {
    final mobile = _isMobile(context);
    final leftColWidth = mobile ? 110.0 : 180.0;
    final dayColWidth = mobile ? 38.0 : 50.0;
    final rowHeight = mobile ? 30.0 : 32.0;
    const headerHeight = 38.0;
    final totalColWidth = mobile ? 56.0 : 70.0;

    final c = widget.chart;
    final machinesToShow = widget.focusMachineId == null
        ? c.machines
        : c.machines.where((m) => m.id == widget.focusMachineId).toList();

    final rowDefs = <_RowDef>[];
    for (final machine in machinesToShow) {
      // Map back to the chart-wide machine index so the band color matches
      // the Excel export exactly (where machines are colored by their
      // position in `chart.machines`, not in the filtered view).
      final machineIdx = c.machines.indexWhere((m) => m.id == machine.id);
      for (final shift in c.shifts) {
        final dataRow = c.rows.firstWhere(
          (r) => r.machineId == machine.id && r.shiftId == shift.id,
          orElse: () => DplChartRow(
            machineId: machine.id,
            shiftId: shift.id,
            daily: const [],
            totals: DplChartTotals.empty(),
          ),
        );
        rowDefs.add(_RowDef(
          machineName: machine.name,
          machineIndex: machineIdx < 0 ? 0 : machineIdx,
          shiftCode: shift.code,
          shiftName: shift.name,
          kind: _RowKind.plan,
          row: dataRow,
          isFirstInGroup: true,
        ));
        rowDefs.add(_RowDef(
          machineName: machine.name,
          machineIndex: machineIdx < 0 ? 0 : machineIdx,
          shiftCode: shift.code,
          shiftName: shift.name,
          kind: _RowKind.actual,
          row: dataRow,
          isFirstInGroup: false,
        ));
        if (!widget.compact) {
          rowDefs.add(_RowDef(
            machineName: machine.name,
            machineIndex: machineIdx < 0 ? 0 : machineIdx,
            shiftCode: shift.code,
            shiftName: shift.name,
            kind: _RowKind.downtime,
            row: dataRow,
            isFirstInGroup: false,
          ));
        }
      }
    }

    final totalHeight = headerHeight + (rowDefs.length * rowHeight);
    final renderHeight = totalHeight > 560 ? 560.0 : totalHeight;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _kSheetBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        height: renderHeight,
        child: Row(
          children: [
            // ---- Frozen left columns ----
            SizedBox(
              width: leftColWidth,
              child: Column(
                children: [
                  Container(
                    height: headerHeight,
                    decoration: BoxDecoration(
                      color: DplChartTokens.dateBand,
                      border: const Border(
                        right: BorderSide(color: _kSheetBorder),
                        bottom: BorderSide(color: _kSheetBorder),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    alignment: Alignment.centerLeft,
                    child: const Text(
                      'Shift / Row',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 11,
                        color: _kSheetInk,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: _vCtrlLeft,
                      itemCount: rowDefs.length,
                      itemExtent: rowHeight,
                      itemBuilder: (_, i) => _LeftCell(def: rowDefs[i]),
                    ),
                  ),
                ],
              ),
            ),
            // ---- Scrollable day columns ----
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                controller: _hCtrl,
                child: SizedBox(
                  width:
                      c.days.length * dayColWidth + totalColWidth,
                  child: Column(
                    children: [
                      Container(
                        height: headerHeight,
                        decoration: BoxDecoration(
                          color: DplChartTokens.dateBand,
                          border: const Border(
                              bottom: BorderSide(color: _kSheetBorder)),
                        ),
                        child: Row(
                          children: [
                            for (final d in c.days)
                              _DayHeader(date: d, width: dayColWidth),
                            Container(
                              width: totalColWidth,
                              height: headerHeight,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: DplChartTokens.totalBand,
                                border: const Border(
                                  left: BorderSide(color: _kSheetBorder),
                                ),
                              ),
                              child: const Text(
                                'Total',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 11,
                                  color: _kSheetInk,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          controller: _vCtrlRight,
                          itemCount: rowDefs.length,
                          itemExtent: rowHeight,
                          itemBuilder: (_, i) => _DataRowStrip(
                            def: rowDefs[i],
                            days: c.days,
                            dayColWidth: dayColWidth,
                            totalColWidth: totalColWidth,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _RowKind { plan, actual, downtime }

class _RowDef {
  final String machineName;
  final int machineIndex;
  final String shiftCode;
  final String shiftName;
  final _RowKind kind;
  final DplChartRow row;
  final bool isFirstInGroup;

  const _RowDef({
    required this.machineName,
    required this.machineIndex,
    required this.shiftCode,
    required this.shiftName,
    required this.kind,
    required this.row,
    required this.isFirstInGroup,
  });

  /// Background tint for the row — mirrors the Excel per-machine band.
  Color get bandColor =>
      DplChartTokens.machineBandColorAt(machineIndex);

  String get kindLabel {
    switch (kind) {
      case _RowKind.plan:
        return 'Plan';
      case _RowKind.actual:
        return 'Actual';
      case _RowKind.downtime:
        return 'DT (min)';
    }
  }

  Color get kindAccent {
    switch (kind) {
      case _RowKind.plan:
        return _kSheetPlan;
      case _RowKind.actual:
        return _kSheetActual;
      case _RowKind.downtime:
        return _kSheetDowntime;
    }
  }
}

class _LeftCell extends StatelessWidget {
  final _RowDef def;
  const _LeftCell({required this.def});

  @override
  Widget build(BuildContext context) {
    // Plan rows get an emphasis (dark navy) color so they stand out from
    // Actual without using red; Downtime uses the warn color.
    final labelColor = def.kind == _RowKind.plan
        ? DplChartTokens.emphasisLabel
        : (def.kind == _RowKind.downtime ? _kSheetDowntime : _kSheetInk);

    return Container(
      decoration: BoxDecoration(
        color: def.bandColor,
        border: const Border(
          right: BorderSide(color: _kSheetBorder),
          bottom: BorderSide(color: _kSheetBorder),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 18,
            color: def.kindAccent,
            margin: const EdgeInsets.only(right: 5),
          ),
          Expanded(
            // Two text lines (Shift A + Plan) inside a 30dp row at
            // default line heights total ~31dp and trip the renderer
            // with a 1–5px overflow. Tight line heights + clipped
            // overflow keep them inside the row without changing the
            // grid's synced item extent.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (def.isFirstInGroup)
                  Text(
                    'Shift ${def.shiftCode}',
                    style: const TextStyle(
                      fontSize: 10,
                      height: 1.0,
                      color: _kSheetMuted,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (def.isFirstInGroup) const SizedBox(height: 2),
                Text(
                  def.kindLabel,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.0,
                    fontWeight: FontWeight.w900,
                    color: labelColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  final DateTime date;
  final double width;
  const _DayHeader({required this.date, required this.width});

  @override
  Widget build(BuildContext context) {
    final isWeekend =
        date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
    // Match the Excel: date band is green; weekends get the pale-yellow tint
    // so they remain visually distinct against the green.
    return Container(
      width: width,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isWeekend
            ? DplChartTokens.weekendBand
            : DplChartTokens.dateBand,
        border: const Border(
          right: BorderSide(color: _kSheetBorder),
          bottom: BorderSide(color: _kSheetBorder),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            DateFormat('dd').format(date),
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 11,
              color: _kSheetInk,
            ),
          ),
          Text(
            DateFormat('EEE').format(date),
            style: const TextStyle(
              fontSize: 9,
              color: _kSheetMuted,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _DataRowStrip extends StatelessWidget {
  final _RowDef def;
  final List<DateTime> days;
  final double dayColWidth;
  final double totalColWidth;
  const _DataRowStrip({
    required this.def,
    required this.days,
    required this.dayColWidth,
    required this.totalColWidth,
  });

  int _valueFor(DplChartCell? cell) {
    if (cell == null) return 0;
    switch (def.kind) {
      case _RowKind.plan:
        return cell.planQty;
      case _RowKind.actual:
        return cell.actualQty;
      case _RowKind.downtime:
        return cell.downtimeMinutes;
    }
  }

  int _totalFor() {
    switch (def.kind) {
      case _RowKind.plan:
        return def.row.totals.planQty;
      case _RowKind.actual:
        return def.row.totals.actualQty;
      case _RowKind.downtime:
        return def.row.totals.downtimeMinutes;
    }
  }

  /// Cell background — Actual rows get a completion-% heat tint that
  /// overrides the machine band; everything else stays on the band so
  /// the row reads as a single colored strip (matching the Excel).
  Color _cellBg(DplChartCell? cell) {
    if (def.kind != _RowKind.actual) return def.bandColor;
    if (cell == null || cell.planQty == 0) return def.bandColor;
    final pct = cell.completionPct;
    if (pct >= 1.0) return const Color(0xFFDBEAFE);
    if (pct >= 0.9) return const Color(0xFFDCFCE7);
    if (pct >= 0.7) return const Color(0xFFFEF3C7);
    return const Color(0xFFFEE2E2);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final d in days) _cell(d),
        Container(
          width: totalColWidth,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: DplChartTokens.totalBand,
            border: const Border(
              left: BorderSide(color: _kSheetBorder),
              bottom: BorderSide(color: _kSheetBorder),
            ),
          ),
          child: Text(
            _totalFor() == 0 ? '—' : _totalFor().toString(),
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 11,
              color: def.kindAccent,
            ),
          ),
        ),
      ],
    );
  }

  Widget _cell(DateTime date) {
    final cell = def.row.daily.cast<DplChartCell?>().firstWhere(
          (c) =>
              c != null &&
              c.date.year == date.year &&
              c.date.month == date.month &&
              c.date.day == date.day,
          orElse: () => null,
        );
    final v = _valueFor(cell);
    final bg = _cellBg(cell);
    return Container(
      width: dayColWidth,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        border: const Border(
          right: BorderSide(color: _kSheetBorder),
          bottom: BorderSide(color: _kSheetBorder),
        ),
      ),
      child: Text(
        v == 0 ? '' : v.toString(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          fontFamily: 'monospace',
          color: v == 0 ? _kSheetMuted : _kSheetInk,
        ),
      ),
    );
  }
}

// =============================================================================
// Tab 3 — Machines (mobile = card list, wide = chart + table)
// =============================================================================

class _MachinesTab extends ConsumerWidget {
  const _MachinesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dplPlanVsActualReportProvider);
    final mobile = _isMobile(context);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(dplPlanVsActualReportProvider);
        await ref.read(dplPlanVsActualReportProvider.future);
      },
      child: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: SkeletonList(count: 4),
        ),
        error: (e, _) => DplErrorRetry(message: e.toString()),
        data: (res) {
          if (res.isError) {
            return DplErrorRetry(
              message: res.error ?? 'Failed to load report.',
              onRetry: () => ref.invalidate(dplPlanVsActualReportProvider),
            );
          }
          final report = res.data ?? DplPlanVsActualReport.empty();
          if (report.rows.isEmpty) {
            return const _EmptyScroll(
              icon: Icons.precision_manufacturing_outlined,
              title: 'No machine production yet',
              message: 'No plan vs actual data in this range.',
            );
          }

          // Roll up per machine
          final byMachine = <int, _MachineRollup>{};
          for (final r in report.rows) {
            final acc = byMachine.putIfAbsent(
              r.machineId,
              () => _MachineRollup(
                machineId: r.machineId,
                machineName: r.machineName,
              ),
            );
            acc.planQty += r.planQty;
            acc.actualQty += r.actualQty;
          }
          final rollups = byMachine.values.toList()
            ..sort((a, b) => b.actualQty.compareTo(a.actualQty));

          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              if (!mobile) ...[
                _SectionHeader(
                  icon: Icons.stacked_bar_chart_outlined,
                  title: 'Plan vs Actual',
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: DplColors.cardBg,
                    border: Border.all(color: _kBorder),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: SizedBox(
                    height: 220,
                    child: _PlanVsActualChart(rollups: rollups),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              _SectionHeader(
                icon: Icons.list_alt_outlined,
                title: 'Per machine',
              ),
              const SizedBox(height: 8),
              for (final r in rollups) ...[
                _MachineOverviewCard(rollup: r),
                const SizedBox(height: 8),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _PlanVsActualChart extends StatelessWidget {
  final List<_MachineRollup> rollups;
  const _PlanVsActualChart({required this.rollups});

  @override
  Widget build(BuildContext context) {
    final maxVal = rollups.fold<int>(
      0,
      (a, r) => math.max(a, math.max(r.planQty, r.actualQty)),
    );
    final scaledMax = maxVal < 10 ? 10.0 : maxVal * 1.2;

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: scaledMax.toDouble(),
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx < 0 || idx >= rollups.length) {
                  return const SizedBox.shrink();
                }
                final label = rollups[idx].machineName;
                return SideTitleWidget(
                  meta: meta,
                  space: 6,
                  child: Text(
                    label.length > 10 ? '${label.substring(0, 10)}…' : label,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              },
            ),
          ),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 36),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
        borderData: FlBorderData(show: false),
        barGroups: rollups.asMap().entries.map((e) {
          final i = e.key;
          final r = e.value;
          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: r.planQty.toDouble(),
                color: _kPrimary,
                width: 12,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(3)),
              ),
              BarChartRodData(
                toY: r.actualQty.toDouble(),
                color: _kGood,
                width: 12,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(3)),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

// =============================================================================
// Tab 4 — Downtime
// =============================================================================

class _DowntimeTab extends ConsumerWidget {
  const _DowntimeTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(dplDowntimeSubViewProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: SegmentedButton<DplDowntimeSubView>(
            segments: const [
              ButtonSegment(
                value: DplDowntimeSubView.summary,
                label: Text('Summary'),
                icon: Icon(Icons.donut_large_outlined),
              ),
              ButtonSegment(
                value: DplDowntimeSubView.reasonMatrix,
                label: Text('Reason Matrix'),
                icon: Icon(Icons.grid_on_outlined),
              ),
            ],
            selected: {view},
            showSelectedIcon: false,
            onSelectionChanged: (s) => ref
                .read(dplDowntimeSubViewProvider.notifier)
                .set(s.first),
          ),
        ),
        Expanded(
          child: view == DplDowntimeSubView.summary
              ? const _DowntimeSummaryView()
              : const _DowntimeReasonMatrixView(),
        ),
      ],
    );
  }
}

class _DowntimeSummaryView extends ConsumerWidget {
  const _DowntimeSummaryView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fmt = NumberFormat.decimalPattern();
    final async = ref.watch(dplDowntimeByDateReportProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(dplDowntimeByDateReportProvider);
        await ref.read(dplDowntimeByDateReportProvider.future);
      },
      child: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: SkeletonList(count: 4),
        ),
        error: (e, _) => DplErrorRetry(
          message: e.toString(),
          onRetry: () => ref.invalidate(dplDowntimeByDateReportProvider),
        ),
        data: (res) {
          if (res.isError) {
            return DplErrorRetry(
              message: res.error ?? 'Failed to load downtime report.',
              onRetry: () =>
                  ref.invalidate(dplDowntimeByDateReportProvider),
            );
          }
          final report = res.data ?? DplDowntimeReport.empty();
          final buckets = DplDowntimeAggregator.bucketByDate(report);
          if (buckets.isEmpty) {
            return const _EmptyScroll(
              icon: Icons.timer_off_outlined,
              title: 'No downtime',
              message:
                  "Either no downtime has been logged, or the server didn't return per-day buckets for this range.",
            );
          }

          final grandTotal =
              buckets.fold<int>(0, (a, b) => a + b.totalMinutes);
          final grandEvents =
              buckets.fold<int>(0, (a, b) => a + b.totalEvents);
          final peak = buckets.reduce(
            (a, b) => a.totalMinutes >= b.totalMinutes ? a : b,
          );
          final dateLabel = DateFormat('dd MMM');

          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: DplColors.cardBg,
                  border: Border.all(color: _kBorder),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Wrap(
                  spacing: 18,
                  runSpacing: 10,
                  children: [
                    _MiniKv(
                      label: 'Days',
                      value: fmt.format(buckets.length),
                    ),
                    _MiniKv(
                      label: 'Events',
                      value: fmt.format(grandEvents),
                    ),
                    _MiniKv(
                      label: 'Total Downtime',
                      value: _formatHrsMin(grandTotal),
                      color: _kBad,
                    ),
                    _MiniKv(
                      label: 'Peak Day',
                      value:
                          '${dateLabel.format(peak.date)} • ${_formatHrsMin(peak.totalMinutes)}',
                      color: _kWarn,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const _SectionHeader(
                icon: Icons.calendar_today_outlined,
                title: 'Daily breakdown with reasons',
              ),
              const SizedBox(height: 8),
              for (final bucket in buckets) ...[
                _DowntimeDayCard(
                  bucket: bucket,
                  grandTotal: grandTotal,
                  peakMinutes: peak.totalMinutes,
                  fmt: fmt,
                ),
                const SizedBox(height: 8),
              ],
            ],
          );
        },
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Reason Matrix view — pivot of (machine × reason) by date. Mirrors the
// reference "Down Time Reason" spreadsheet shape 1:1, with grand-total
// row, total-duration footer, and an in-view download menu (Excel/CSV).
// Built client-side from `/manager/reports/downtime/events`.
// -----------------------------------------------------------------------------

class _DowntimeReasonMatrixView extends ConsumerStatefulWidget {
  const _DowntimeReasonMatrixView();

  @override
  ConsumerState<_DowntimeReasonMatrixView> createState() =>
      _DowntimeReasonMatrixViewState();
}

class _DowntimeReasonMatrixViewState
    extends ConsumerState<_DowntimeReasonMatrixView> {
  bool _isDownloading = false;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(dplDowntimeEventsProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(dplDowntimeEventsProvider);
        await ref.read(dplDowntimeEventsProvider.future);
      },
      child: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: SkeletonList(count: 5),
        ),
        error: (e, _) => DplErrorRetry(
          message: e.toString(),
          onRetry: () => ref.invalidate(dplDowntimeEventsProvider),
        ),
        data: (res) {
          if (res.isError) {
            return DplErrorRetry(
              message: res.error ?? 'Failed to load downtime events.',
              onRetry: () => ref.invalidate(dplDowntimeEventsProvider),
            );
          }
          final events = res.data ?? const <DplDowntimeEventDetail>[];
          final matrix = DplDowntimeMatrix.fromEvents(events);
          if (matrix.isEmpty) {
            return const _EmptyScroll(
              icon: Icons.grid_off_outlined,
              title: 'No downtime events',
              message:
                  'No closed downtime events were logged for this date range.',
            );
          }
          return _DowntimeMatrixContent(
            matrix: matrix,
            isDownloading: _isDownloading,
            onDownload: (format) => _download(matrix, format),
          );
        },
      ),
    );
  }

  Future<void> _download(
    DplDowntimeMatrix matrix,
    String format,
  ) async {
    setState(() => _isDownloading = true);
    try {
      final range = ref.read(dplReportRangeProvider);
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final isCsv = format == 'csv';
      final bytes = isCsv
          ? DplDowntimeMatrixExporter.buildCsv(
              matrix,
              from: range.from,
              to: range.to,
            )
          : DplDowntimeMatrixExporter.buildExcel(
              matrix,
              from: range.from,
              to: range.to,
            );
      final ext = isCsv ? 'csv' : 'xlsx';
      final mime = isCsv
          ? 'text/csv'
          : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      final fileName = 'dpl_downtime_reason_matrix_$stamp.$ext';
      final path = await saveReportBytes(
        bytes: bytes,
        fileName: fileName,
        mimeType: mime,
      );
      if (!mounted) return;
      DplSnack.success(
        context,
        path == null ? 'Downloaded.' : 'Saved: $path',
      );
    } catch (e) {
      if (!mounted) return;
      DplSnack.error(context, 'Failed to export: $e');
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }
}

class _DowntimeMatrixContent extends StatelessWidget {
  final DplDowntimeMatrix matrix;
  final bool isDownloading;
  final void Function(String format) onDownload;

  const _DowntimeMatrixContent({
    required this.matrix,
    required this.isDownloading,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final reasonCount = matrix.rows.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: DplColors.cardBg,
            border: Border.all(color: _kBorder),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 18,
                  runSpacing: 10,
                  children: [
                    _MiniKv(
                      label: 'Days',
                      value: fmt.format(matrix.dates.length),
                    ),
                    _MiniKv(
                      label: 'Reasons',
                      value: fmt.format(reasonCount),
                    ),
                    _MiniKv(
                      label: 'Total Downtime',
                      value: _formatHrsMin(matrix.grandTotal),
                      color: _kBad,
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                enabled: !isDownloading,
                tooltip: 'Download reason matrix',
                icon: isDownloading
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _kPrimary,
                        ),
                      )
                    : Icon(
                        Icons.download_outlined,
                        color: _kPrimary,
                      ),
                onSelected: onDownload,
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'xlsx',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.table_view_outlined),
                      title: Text('Download Excel'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'csv',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.description_outlined),
                      title: Text('Download CSV'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _DowntimeMatrixTable(matrix: matrix),
      ],
    );
  }
}

class _DowntimeMatrixTable extends StatelessWidget {
  final DplDowntimeMatrix matrix;
  const _DowntimeMatrixTable({required this.matrix});

  static const double _machineColWidth = 110;
  static const double _reasonColWidth = 180;
  static const double _dateColWidth = 60;
  static const double _grandColWidth = 76;
  static const double _rowHeight = 34;
  static const double _headerHeight = 38;

  @override
  Widget build(BuildContext context) {
    final dateHeader = DateFormat('dd-MMM');

    // Precompute the display label for the Machine column so the first
    // row of each group shows the name and subsequent rows leave it
    // blank — matching the reference spreadsheet layout.
    final machineLabels = <String>[];
    String? lastMachine;
    for (final row in matrix.rows) {
      machineLabels.add(row.machineName == lastMachine ? '' : row.machineName);
      lastMachine = row.machineName;
    }

    final tableWidth = _machineColWidth +
        _reasonColWidth +
        matrix.dates.length * _dateColWidth +
        _grandColWidth;

    Widget headerCell(String text, {double? width, Color? bg}) => Container(
          width: width,
          height: _headerHeight,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg ?? _kSurfaceAlt,
            border: Border(
              right: BorderSide(color: _kBorder),
              bottom: BorderSide(color: _kBorder),
            ),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 11,
              color: _kNeutral,
            ),
          ),
        );

    Widget bodyCell(
      String text, {
      double? width,
      bool muted = false,
      bool bold = false,
      Color? bg,
      TextAlign align = TextAlign.right,
    }) =>
        Container(
          width: width,
          height: _rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: align == TextAlign.right
              ? Alignment.centerRight
              : (align == TextAlign.center
                  ? Alignment.center
                  : Alignment.centerLeft),
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              right: BorderSide(color: _kBorder),
              bottom: BorderSide(color: _kBorder),
            ),
          ),
          child: Text(
            text,
            textAlign: align,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              color: muted ? _kNeutral : DplColors.textPrimary,
              fontWeight: bold ? FontWeight.w900 : FontWeight.w600,
            ),
          ),
        );

    final headerRow = Row(
      children: [
        headerCell('Machine Name', width: _machineColWidth),
        headerCell('Down Time Reason', width: _reasonColWidth),
        for (final d in matrix.dates)
          headerCell(dateHeader.format(d), width: _dateColWidth),
        headerCell(
          'Grand Total',
          width: _grandColWidth,
          bg: VistarPalette.badBg,
        ),
      ],
    );

    final bodyRows = <Widget>[
      for (var i = 0; i < matrix.rows.length; i++)
        Row(
          children: [
            bodyCell(
              machineLabels[i],
              width: _machineColWidth,
              align: TextAlign.left,
              bold: machineLabels[i].isNotEmpty,
            ),
            bodyCell(
              matrix.rows[i].reasonName,
              width: _reasonColWidth,
              align: TextAlign.left,
            ),
            for (final v in matrix.rows[i].minutesByDate)
              bodyCell(
                v == 0 ? '' : v.toString(),
                width: _dateColWidth,
                muted: v == 0,
              ),
            bodyCell(
              matrix.rows[i].rowTotal.toString(),
              width: _grandColWidth,
              bold: true,
              bg: VistarPalette.badBg,
            ),
          ],
        ),
    ];

    final grandTotalRow = Row(
      children: [
        bodyCell('', width: _machineColWidth, bg: _kSurfaceAlt),
        bodyCell(
          'Grand Total',
          width: _reasonColWidth,
          align: TextAlign.left,
          bold: true,
          bg: _kSurfaceAlt,
        ),
        for (final v in matrix.dateTotals)
          bodyCell(
            v.toString(),
            width: _dateColWidth,
            bold: true,
            bg: _kSurfaceAlt,
          ),
        bodyCell(
          matrix.grandTotal.toString(),
          width: _grandColWidth,
          bold: true,
          bg: VistarPalette.badBg,
        ),
      ],
    );

    final durationRow = Row(
      children: [
        bodyCell('', width: _machineColWidth),
        bodyCell('', width: _reasonColWidth),
        for (final v in matrix.dateTotals)
          bodyCell(
            _formatHrsMin(v),
            width: _dateColWidth,
            muted: true,
          ),
        bodyCell('', width: _grandColWidth),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                headerRow,
                ...bodyRows,
                grandTotalRow,
                durationRow,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DowntimeDayCard extends StatelessWidget {
  final DplDowntimeDateBucket bucket;
  final int grandTotal;
  final int peakMinutes;
  final NumberFormat fmt;

  const _DowntimeDayCard({
    required this.bucket,
    required this.grandTotal,
    required this.peakMinutes,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    final totalMin = bucket.totalMinutes;
    final share = grandTotal <= 0 ? 0.0 : totalMin / grandTotal;
    final fraction = peakMinutes <= 0 ? 0.0 : totalMin / peakMinutes;
    final dateLabel = DateFormat('EEE, dd MMM yyyy').format(bucket.date);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  dateLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
              ),
              Text(
                _formatHrsMin(totalMin),
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: _kBad,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: fraction.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: VistarPalette.badBg,
              valueColor: AlwaysStoppedAnimation(_kBad),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              Text(
                '${fmt.format(bucket.totalEvents)} event${bucket.totalEvents == 1 ? "" : "s"}',
                style: TextStyle(color: _kNeutral, fontSize: 12),
              ),
              if (bucket.plannedMinutes > 0)
                Text(
                  'Planned: ${_formatHrsMin(bucket.plannedMinutes)}',
                  style: TextStyle(
                    color: _kPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              if (bucket.unplannedMinutes > 0)
                Text(
                  'Unplanned: ${_formatHrsMin(bucket.unplannedMinutes)}',
                  style: TextStyle(
                    color: _kWarn,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              Text(
                '${(share * 100).toStringAsFixed(1)}% of total',
                style: TextStyle(color: _kNeutral, fontSize: 12),
              ),
            ],
          ),
          if (bucket.reasons.isNotEmpty) ...[
            const SizedBox(height: 10),
            Divider(height: 1, color: _kBorder),
            const SizedBox(height: 8),
            for (final r in bucket.reasons) ...[
              _DowntimeReasonChip(
                row: r,
                dayMinutes: totalMin,
                fmt: fmt,
              ),
              const SizedBox(height: 6),
            ],
          ],
        ],
      ),
    );
  }
}

class _DowntimeReasonChip extends StatelessWidget {
  final DplDowntimeDateReasonRow row;
  final int dayMinutes;
  final NumberFormat fmt;

  const _DowntimeReasonChip({
    required this.row,
    required this.dayMinutes,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    final isPlanned = row.isPlanned;
    final color = isPlanned ? _kPrimary : _kWarn;
    final share = dayMinutes <= 0 ? 0.0 : row.totalMinutes / dayMinutes;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _kSurfaceAlt,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.reason,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 10,
                  runSpacing: 2,
                  children: [
                    Text(
                      isPlanned ? 'Planned' : 'Unplanned',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      '${fmt.format(row.events)} event${row.events == 1 ? "" : "s"}',
                      style: TextStyle(
                        color: _kNeutral,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      '${(share * 100).toStringAsFixed(1)}% of day',
                      style: TextStyle(
                        color: _kNeutral,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatHrsMin(row.totalMinutes),
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Tab 5 — Supervisors
// =============================================================================

class _SupervisorsTab extends ConsumerWidget {
  const _SupervisorsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dplSupervisorPerformanceReportProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(dplSupervisorPerformanceReportProvider);
        await ref.read(dplSupervisorPerformanceReportProvider.future);
      },
      child: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: SkeletonList(count: 3),
        ),
        error: (e, _) => DplErrorRetry(message: e.toString()),
        data: (res) {
          if (res.isError) {
            return DplErrorRetry(
              message: res.error ?? 'Failed to load report.',
              onRetry: () =>
                  ref.invalidate(dplSupervisorPerformanceReportProvider),
            );
          }
          final report = res.data ?? DplSupervisorPerformanceReport.empty();
          if (report.rows.isEmpty) {
            return const _EmptyScroll(
              icon: Icons.people_outline,
              title: 'No supervisor data',
              message: 'No supervisor performance data for this range.',
            );
          }
          final sorted = [...report.rows]
            ..sort((a, b) => b.completionPct.compareTo(a.completionPct));
          final fmt = NumberFormat.decimalPattern();

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            itemCount: sorted.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final row = sorted[i];
                  final pct = (row.completionPct * 100).round();
                  final color = _achievementColor(row.completionPct);
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: DplColors.cardBg,
                      border: Border.all(color: _kBorder),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        _RankBadge(rank: i + 1),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                row.supervisorName.isEmpty
                                    ? 'User #${row.supervisorUserId}'
                                    : row.supervisorName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Plan ${fmt.format(row.totalPlan)} • '
                                'Actual ${fmt.format(row.totalActual)} • '
                                '${row.plansHandled} plans',
                                style: TextStyle(
                                  color: _kNeutral,
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(999),
                                child: LinearProgressIndicator(
                                  value: row.completionPct,
                                  minHeight: 5,
                                  backgroundColor: VistarPalette.surface3,
                                  valueColor: AlwaysStoppedAnimation(color),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$pct%',
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                      ],
                    ),
                  );
                },
          );
        },
      ),
    );
  }
}

// =============================================================================
// Tab 6 — Parts (search + sort + card list)
// =============================================================================

class _PartsTab extends ConsumerStatefulWidget {
  const _PartsTab();

  @override
  ConsumerState<_PartsTab> createState() => _PartsTabState();
}

class _PartsTabState extends ConsumerState<_PartsTab> {
  String _query = '';
  String _sort = 'actual';

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(dplPartWiseReportProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(dplPartWiseReportProvider);
        await ref.read(dplPartWiseReportProvider.future);
      },
      child: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: SkeletonList(count: 3),
        ),
        error: (e, _) => DplErrorRetry(message: e.toString()),
        data: (res) {
          if (res.isError) {
            return DplErrorRetry(
              message: res.error ?? 'Failed to load report.',
              onRetry: () => ref.invalidate(dplPartWiseReportProvider),
            );
          }
          final report = res.data ?? DplPartWiseReport.empty();
          if (report.rows.isEmpty) {
            return const _EmptyScroll(
              icon: Icons.inventory_2_outlined,
              title: 'No part-level data',
              message: 'No part-wise production data for this range.',
            );
          }

          final filtered = report.rows.where((r) {
            if (_query.isEmpty) return true;
            final q = _query.toLowerCase();
            return r.partNumber.toLowerCase().contains(q) ||
                r.partDescription.toLowerCase().contains(q);
          }).toList();

          filtered.sort((a, b) {
            switch (_sort) {
              case 'plan':
                return b.totalPlan.compareTo(a.totalPlan);
              case 'pct':
                return b.completionPct.compareTo(a.completionPct);
              case 'actual':
              default:
                return b.totalActual.compareTo(a.totalActual);
            }
          });

          final fmt = NumberFormat.decimalPattern();

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search),
                              hintText: 'Search part / description',
                              isDense: true,
                            ),
                            onChanged: (v) =>
                                setState(() => _query = v.trim()),
                          ),
                        ),
                        const SizedBox(width: 8),
                        DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _sort,
                            items: const [
                              DropdownMenuItem(
                                value: 'actual',
                                child: Text('Actual ↓'),
                              ),
                              DropdownMenuItem(
                                value: 'plan',
                                child: Text('Plan ↓'),
                              ),
                              DropdownMenuItem(
                                value: 'pct',
                                child: Text('% ↓'),
                              ),
                            ],
                            onChanged: (v) {
                              if (v != null) setState(() => _sort = v);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: filtered.isEmpty
                        ? const _EmptyScroll(
                            icon: Icons.search_off_outlined,
                            title: 'No matches',
                            message:
                                'No parts match your search in this range.',
                          )
                        : ListView.separated(
                            padding:
                                const EdgeInsets.fromLTRB(12, 6, 12, 80),
                            itemCount: filtered.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, i) {
                              final r = filtered[i];
                              final pct =
                                  (r.completionPct * 100).round();
                              final color =
                                  _achievementColor(r.completionPct);
                              final variance =
                                  r.totalActual - r.totalPlan;
                              return Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: DplColors.cardBg,
                                  border: Border.all(color: _kBorder),
                                  borderRadius:
                                      BorderRadius.circular(14),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            r.partDescription.isEmpty
                                                ? (r.partNumber.isEmpty
                                                    ? 'Part #${r.partId}'
                                                    : r.partNumber)
                                                : r.partDescription,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 14,
                                            ),
                                          ),
                                          if (r.partNumber.isNotEmpty &&
                                              r.partDescription.isNotEmpty)
                                            Padding(
                                              padding:
                                                  const EdgeInsets.only(top: 2),
                                              child: Text(
                                                r.partNumber,
                                                style: TextStyle(
                                                  color: _kNeutral,
                                                  fontSize: 11,
                                                ),
                                                overflow:
                                                    TextOverflow.ellipsis,
                                              ),
                                            ),
                                          const SizedBox(height: 6),
                                          Wrap(
                                            spacing: 12,
                                            runSpacing: 2,
                                            children: [
                                              _MiniKv(
                                                label: 'Plan',
                                                value:
                                                    fmt.format(r.totalPlan),
                                              ),
                                              _MiniKv(
                                                label: 'Actual',
                                                value: fmt
                                                    .format(r.totalActual),
                                                color: _kGood,
                                              ),
                                              _MiniKv(
                                                label: 'Var',
                                                value: variance >= 0
                                                    ? '+$variance'
                                                    : '$variance',
                                                color: variance >= 0
                                                    ? _kGood
                                                    : _kBad,
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    _AchievementRing(
                                      pct: r.completionPct,
                                      label: '$pct%',
                                      color: color,
                                      size: 48,
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

// =============================================================================
// Tab 7 — Daily Log (plans + items + start/end + downtime + reason)
// =============================================================================

class _DailyLogTab extends ConsumerWidget {
  const _DailyLogTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dplDailyLogReportProvider);
    final intFmt = NumberFormat.decimalPattern();
    final dateFmt = DateFormat('EEE, dd MMM yyyy');
    final timeFmt = DateFormat('HH:mm');

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(dplDailyLogReportProvider);
        await ref.read(dplDailyLogReportProvider.future);
      },
      child: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: SkeletonList(count: 4),
        ),
        error: (e, _) => DplErrorRetry(
          message: e.toString(),
          onRetry: () => ref.invalidate(dplDailyLogReportProvider),
        ),
        data: (res) {
          if (res.isError) {
            return DplErrorRetry(
              message: res.error ?? 'Failed to load daily log.',
              onRetry: () => ref.invalidate(dplDailyLogReportProvider),
            );
          }
          final report = res.data;
          if (report == null || report.isEmpty) {
            return const _EmptyScroll(
              icon: Icons.event_note_outlined,
              title: 'No plans in this range',
              message:
                  'Pick a date range with at least one production plan to see the daily log.',
            );
          }

          final groups = _groupDailyLogByDate(report.rows);
          final totals = _DailyLogTotals.fromRows(report.rows);

          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              _DailyLogSummaryCard(totals: totals, intFmt: intFmt),
              const SizedBox(height: 14),
              for (final group in groups) ...[
                _DailyLogDateSection(
                  group: group,
                  intFmt: intFmt,
                  dateFmt: dateFmt,
                  timeFmt: timeFmt,
                ),
                const SizedBox(height: 12),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _DailyLogTotals {
  final int planQty;
  final int actualQty;
  final int runMinutes;
  final int downtimeMinutes;
  final int rows;

  const _DailyLogTotals({
    required this.planQty,
    required this.actualQty,
    required this.runMinutes,
    required this.downtimeMinutes,
    required this.rows,
  });

  factory _DailyLogTotals.fromRows(List<DplDailyLogRow> rows) {
    var plan = 0;
    var actual = 0;
    var run = 0;
    var down = 0;
    for (final r in rows) {
      plan += r.planQty;
      actual += r.actualQty;
      run += r.runMinutes ?? 0;
      down += r.downtimeMinutes;
    }
    return _DailyLogTotals(
      planQty: plan,
      actualQty: actual,
      runMinutes: run,
      downtimeMinutes: down,
      rows: rows.length,
    );
  }

  double get achievementPct => planQty <= 0 ? 0 : actualQty / planQty;
}

class _DailyLogGroup {
  final DateTime date;
  final List<DplDailyLogRow> rows = [];
  _DailyLogGroup({required this.date});

  _DailyLogTotals get totals => _DailyLogTotals.fromRows(rows);
}

List<_DailyLogGroup> _groupDailyLogByDate(List<DplDailyLogRow> rows) {
  final byKey = <String, _DailyLogGroup>{};
  for (final r in rows) {
    final d = r.planDate;
    final date = DateTime(d.year, d.month, d.day);
    final key = DateFormat('yyyy-MM-dd').format(date);
    final group = byKey.putIfAbsent(key, () => _DailyLogGroup(date: date));
    group.rows.add(r);
  }
  final list = byKey.values.toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  return list;
}

class _DailyLogSummaryCard extends StatelessWidget {
  final _DailyLogTotals totals;
  final NumberFormat intFmt;
  const _DailyLogSummaryCard({required this.totals, required this.intFmt});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Wrap(
        spacing: 18,
        runSpacing: 10,
        children: [
          _MiniKv(label: 'Rows', value: intFmt.format(totals.rows)),
          _MiniKv(label: 'Plan Qty', value: intFmt.format(totals.planQty)),
          _MiniKv(
            label: 'Actual Qty',
            value: intFmt.format(totals.actualQty),
            color: _kGood,
          ),
          _MiniKv(
            label: 'Achievement',
            value: '${(totals.achievementPct * 100).toStringAsFixed(1)}%',
            color: _achievementColor(totals.achievementPct),
          ),
          _MiniKv(
            label: 'Run Time',
            value: _formatHrsMin(totals.runMinutes),
            color: _kPrimary,
          ),
          _MiniKv(
            label: 'Downtime',
            value: _formatHrsMin(totals.downtimeMinutes),
            color: _kBad,
          ),
        ],
      ),
    );
  }
}

class _DailyLogDateSection extends StatelessWidget {
  final _DailyLogGroup group;
  final NumberFormat intFmt;
  final DateFormat dateFmt;
  final DateFormat timeFmt;

  const _DailyLogDateSection({
    required this.group,
    required this.intFmt,
    required this.dateFmt,
    required this.timeFmt,
  });

  @override
  Widget build(BuildContext context) {
    final totals = group.totals;
    return Container(
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 28,
                  decoration: BoxDecoration(
                    color: _kPrimary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    dateFmt.format(group.date),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  '${intFmt.format(totals.actualQty)} / ${intFmt.format(totals.planQty)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: _kNeutral,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _achievementColor(totals.achievementPct)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${(totals.achievementPct * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      color: _achievementColor(totals.achievementPct),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: _kBorder),
          for (var i = 0; i < group.rows.length; i++) ...[
            _DailyLogRowTile(
              row: group.rows[i],
              intFmt: intFmt,
              timeFmt: timeFmt,
            ),
            if (i != group.rows.length - 1)
              Divider(
                height: 1,
                color: _kBorder,
                indent: 12,
                endIndent: 12,
              ),
          ],
        ],
      ),
    );
  }
}

class _DailyLogRowTile extends StatelessWidget {
  final DplDailyLogRow row;
  final NumberFormat intFmt;
  final DateFormat timeFmt;

  const _DailyLogRowTile({
    required this.row,
    required this.intFmt,
    required this.timeFmt,
  });

  @override
  Widget build(BuildContext context) {
    final pct = row.completionPct;
    final achievementColor = _achievementColor(pct);
    final runMin = row.runMinutes;
    final downMin = row.downtimeMinutes;
    final startLabel =
        row.startTime == null ? '-' : timeFmt.format(row.startTime!);
    final endLabel =
        row.endTime == null ? '-' : timeFmt.format(row.endTime!);
    final planLabel =
        row.planNo == null ? '#${row.planId}' : '#${row.planNo}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.machineName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _kPrimary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Plan $planLabel',
                  style: TextStyle(
                    color: _kPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            row.partLabel,
            style: TextStyle(color: _kNeutral, fontSize: 12),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              _MiniKv(label: 'Plan Qty', value: intFmt.format(row.planQty)),
              _MiniKv(
                label: 'Actual Qty',
                value: intFmt.format(row.actualQty),
                color: _kGood,
              ),
              _MiniKv(
                label: 'Achievement',
                value: '${(pct * 100).toStringAsFixed(1)}%',
                color: achievementColor,
              ),
              _MiniKv(label: 'Start', value: startLabel),
              _MiniKv(label: 'End', value: endLabel),
              _MiniKv(
                label: 'Total Time',
                value: runMin == null ? '-' : _formatHrsMin(runMin),
                color: _kPrimary,
              ),
              if (downMin > 0)
                _MiniKv(
                  label: 'Downtime',
                  value: _formatHrsMin(downMin),
                  color: _kBad,
                ),
              _MiniKv(label: 'Shift', value: row.shiftLabel),
              _MiniKv(label: 'Status', value: _statusLabel(row.status)),
            ],
          ),
          if (row.reasonOrRemarks != '-') ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _kSurfaceAlt,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.notes_outlined, size: 16, color: _kNeutral),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      row.reasonOrRemarks,
                      style: TextStyle(
                        color: _kNeutral,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'in_progress':
        return 'In Progress';
      case 'completed':
        return 'Completed';
      case 'pending':
        return 'Pending';
      default:
        return status.isEmpty ? '-' : status;
    }
  }
}
