import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../reports/report_download_stub.dart'
    if (dart.library.html) '../../../reports/report_download_web.dart'
    if (dart.library.io) '../../../reports/report_download_io.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_plant.dart';
import '../providers/plants_provider.dart';
import '../services/dpl_buffer_plan_exporter.dart';

const String _xlsxMime =
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

/// Bottom sheet that lets a Dispatch user pick a month and download the
/// monthly **Buffer Creation Plan** as an Excel workbook covering **all
/// plants** — one worksheet per plant.
///
/// The heavy lifting (per-(plant, day) `dispatch-plan/inputs` +
/// dispatched-slip aggregation, then the matrix layout) lives in
/// [DplBufferPlanWorkbook.fetchAll] and [DplBufferPlanExporter]; this
/// widget is just the month picker + progress shell.
class BufferPlanDownloadSheet extends ConsumerStatefulWidget {
  const BufferPlanDownloadSheet({super.key});

  /// Opens the sheet as a modal.
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const BufferPlanDownloadSheet(),
    );
  }

  @override
  ConsumerState<BufferPlanDownloadSheet> createState() =>
      _BufferPlanDownloadSheetState();
}

class _BufferPlanDownloadSheetState
    extends ConsumerState<BufferPlanDownloadSheet> {
  late DateTime _month; // first-of-month anchor (day = 1)
  bool _busy = false;
  int _progress = 0;
  int _total = 1;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
  }

  bool get _atCurrentMonth {
    final now = DateTime.now();
    return _month.year == now.year && _month.month == now.month;
  }

  void _stepMonth(int delta) {
    if (_busy) return;
    final next = DateTime(_month.year, _month.month + delta);
    final now = DateTime(DateTime.now().year, DateTime.now().month);
    // No future months — they carry no snapshot/production/dispatch data.
    if (next.isAfter(now)) return;
    setState(() => _month = next);
  }

  Future<void> _generate(List<DplPlant> plants) async {
    setState(() {
      _busy = true;
      _progress = 0;
      _total = 1;
    });

    final api = ref.read(dplApiServiceProvider);
    try {
      final wb = await DplBufferPlanWorkbook.fetchAll(
        api: api,
        plants: plants,
        year: _month.year,
        month: _month.month,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _progress = done;
            _total = total;
          });
        },
      );

      if (!mounted) return;
      if (wb.isEmpty) {
        setState(() => _busy = false);
        DplSnacks.warning(
          context,
          'No parts found for any plant in '
          '${DateFormat('MMMM yyyy').format(_month)}.',
        );
        return;
      }

      final bytes = DplBufferPlanExporter.build(wb);
      final fileName =
          'Buffer_Plan_All_Plants_${DateFormat('yyyy_MM').format(_month)}.xlsx';
      final path = await saveReportBytes(
        bytes: bytes,
        fileName: fileName,
        mimeType: _xlsxMime,
      );
      if (!mounted) return;
      // Snack BEFORE popping: the snackbar is owned by the app-level
      // ScaffoldMessenger (an ancestor of this sheet), so it survives the
      // pop — but resolving it needs a still-mounted context, which the
      // sheet's context no longer is once popped.
      if (wb.failedInputCount > 0) {
        DplSnacks.warning(
          context,
          'Saved${path == null ? '' : ': $path'} — but '
          '${wb.failedInputCount} day(s) could not be loaded and are blank.',
        );
      } else {
        DplSnacks.success(
          context,
          path == null ? 'Buffer plan downloaded.' : 'Saved: $path',
        );
      }
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      DplSnacks.error(context, 'Could not generate buffer plan: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final plantsAsync = ref.watch(dplPlantsProvider);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: DplColors.cardBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: DplColors.divider,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: DplColors.primaryTint,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(Icons.table_view_outlined,
                      size: 18, color: DplColors.primaryDark),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Buffer Creation Plan', style: DplText.h3()),
                      const SizedBox(height: 1),
                      Text(
                        'All plants · one sheet each · Excel',
                        style: TextStyle(
                          color: DplColors.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            plantsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Could not load plants: $e',
                  style: TextStyle(color: DplColors.error),
                ),
              ),
              data: (res) {
                final plants =
                    (res.data ?? const <DplPlant>[]).cast<DplPlant>();
                if (plants.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('No plants configured.'),
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _label('Month'),
                    const SizedBox(height: 6),
                    _MonthStepper(
                      label: DateFormat('MMMM yyyy').format(_month),
                      onPrev: () => _stepMonth(-1),
                      onNext: _atCurrentMonth ? null : () => _stepMonth(1),
                      enabled: !_busy,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(Icons.factory_outlined,
                            size: 14, color: DplColors.textSecondary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Covers all ${plants.length} plants: '
                            '${plants.map((p) => p.name.isEmpty ? p.code : p.name).join(", ")}',
                            style: TextStyle(
                              color: DplColors.textSecondary,
                              fontWeight: FontWeight.w600,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    if (_busy) ...[
                      LinearProgressIndicator(
                        value: _total == 0 ? null : _progress / _total,
                        minHeight: 6,
                        backgroundColor: DplColors.primaryTint,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Building report… ($_progress/$_total)',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: DplColors.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    SizedBox(
                      height: 50,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : () => _generate(plants),
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.download_outlined),
                        label: Text(_busy ? 'Working…' : 'Download Excel'),
                        style: FilledButton.styleFrom(
                          backgroundColor: DplColors.primary,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Text(
        text.toUpperCase(),
        style: TextStyle(
          color: DplColors.textSecondary,
          fontWeight: FontWeight.w800,
          fontSize: 11,
          letterSpacing: 0.6,
        ),
      );
}

class _MonthStepper extends StatelessWidget {
  final String label;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final bool enabled;
  const _MonthStepper({
    required this.label,
    required this.onPrev,
    required this.onNext,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: DplColors.pageBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DplColors.divider),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: enabled ? onPrev : null,
            icon: const Icon(Icons.chevron_left_rounded),
            tooltip: 'Previous month',
          ),
          Expanded(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ),
          IconButton(
            onPressed: enabled ? onNext : null,
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: 'Next month',
          ),
        ],
      ),
    );
  }
}
