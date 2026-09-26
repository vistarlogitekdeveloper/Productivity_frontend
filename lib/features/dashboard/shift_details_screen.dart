import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme/vistar_palette.dart';
import '../../core/widgets/shimmer_skeleton.dart';
import '../../data/api_services/api_client.dart';
import '../../data/models/production_entry_model.dart';

class ShiftDetailsScreen extends ConsumerStatefulWidget {
  final bool embedded;

  const ShiftDetailsScreen({super.key, this.embedded = false});

  @override
  ConsumerState<ShiftDetailsScreen> createState() => ShiftDetailsScreenState();
}

class ShiftDetailsScreenState extends ConsumerState<ShiftDetailsScreen> {
  DateTime _selectedDate = DateTime.now();
  Future<List<ProductionEntryModel>>? _future;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
    );
    _future = _load(_selectedDate);
  }

  Future<List<ProductionEntryModel>> _load(DateTime date) async {
    final client = ref.read(apiClientProvider);
    final dateStr = DateFormat('yyyy-MM-dd').format(date);
    final response = await client.get(
      '/reports/detailed',
      queryParameters: {
        'fromDate': dateStr,
        'toDate': dateStr,
        'page': 1,
        'limit': 200,
      },
    );

    List<dynamic> dataList = [];
    if (response.data is Map) {
      final raw = response.data['data'];
      if (raw is List) dataList = raw;
    } else if (response.data is List) {
      dataList = response.data;
    }

    return dataList
        .whereType<Map>()
        .map((j) => ProductionEntryModel.fromJson(Map<String, dynamic>.from(j)))
        .toList();
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _load(_selectedDate);
    });
    await _future;
  }

  /// Public entry point so the parent dashboard's app-bar Refresh action can
  /// reload the currently selected date without having to know the internals
  /// of this screen.
  Future<void> refresh() => _refresh();

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) return;
    setState(() {
      _selectedDate = DateTime(picked.year, picked.month, picked.day);
      _future = _load(_selectedDate);
    });
  }

  void _shiftDay(int deltaDays) {
    final next = _selectedDate.add(Duration(days: deltaDays));
    setState(() {
      _selectedDate = DateTime(next.year, next.month, next.day);
      _future = _load(_selectedDate);
    });
  }

  String _formatError(Object error) {
    final raw = error.toString();
    const prefix = 'Exception:';
    if (raw.startsWith(prefix)) return raw.substring(prefix.length).trim();
    return raw;
  }

  Map<String, List<ProductionEntryModel>> _groupByShift(
    List<ProductionEntryModel> entries,
  ) {
    final grouped = <String, List<ProductionEntryModel>>{};
    for (final entry in entries) {
      final key = entry.shift.trim().isEmpty
          ? '—'
          : entry.shift.trim().toUpperCase();
      grouped.putIfAbsent(key, () => []).add(entry);
    }
    for (final list in grouped.values) {
      list.sort((a, b) {
        final aStart = DateTime.tryParse(a.startTime);
        final bStart = DateTime.tryParse(b.startTime);
        if (aStart == null && bStart == null) return 0;
        if (aStart == null) return 1;
        if (bStart == null) return -1;
        return aStart.compareTo(bStart);
      });
    }
    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    final dateLabel = DateFormat('EEE, dd MMM yyyy').format(_selectedDate);
    final isToday = DateUtils.isSameDay(_selectedDate, DateTime.now());

    final content = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [VistarPalette.bg, VistarPalette.bg2, VistarPalette.bg],
        ),
      ),
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 22),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (widget.embedded)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Shift Details',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
              ),
            _DateBar(
              dateLabel: dateLabel,
              isToday: isToday,
              onPrev: () => _shiftDay(-1),
              onNext: () => _shiftDay(1),
              onPickDate: _pickDate,
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<ProductionEntryModel>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const _ShiftDetailsLoading();
                }
                if (snapshot.hasError) {
                  return _ErrorCard(
                    message: _formatError(snapshot.error!),
                    onRetry: _refresh,
                  );
                }
                final entries = snapshot.data ?? const [];
                if (entries.isEmpty) {
                  return const _EmptyCard();
                }
                final grouped = _groupByShift(entries);
                final shiftKeys = grouped.keys.toList()..sort();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _DaySummary(entries: entries),
                    const SizedBox(height: 12),
                    for (final shift in shiftKeys) ...[
                      _ShiftSection(
                        shift: shift,
                        entries: grouped[shift] ?? const [],
                      ),
                      const SizedBox(height: 12),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );

    if (widget.embedded) return content;

    return Scaffold(
      appBar: AppBar(title: const Text('Shift Details')),
      body: content,
    );
  }
}

class _DateBar extends StatelessWidget {
  final String dateLabel;
  final bool isToday;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPickDate;

  const _DateBar({
    required this.dateLabel,
    required this.isToday,
    required this.onPrev,
    required this.onNext,
    required this.onPickDate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: VistarPalette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onPrev,
            icon: const Icon(Icons.chevron_left_rounded),
            tooltip: 'Previous day',
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onPickDate,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.calendar_today_outlined,
                          size: 16,
                          color: VistarPalette.info,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          dateLabel,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                    if (isToday)
                      Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text(
                          'Today',
                          style: TextStyle(
                            color: VistarPalette.ok,
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: 'Next day',
          ),
        ],
      ),
    );
  }
}

class _DaySummary extends StatelessWidget {
  final List<ProductionEntryModel> entries;

  const _DaySummary({required this.entries});

  @override
  Widget build(BuildContext context) {
    int totalActual = 0;
    int totalRejection = 0;
    double totalRunningHours = 0;
    double totalWeightKg = 0;
    for (final e in entries) {
      totalActual += e.actualQuantity;
      totalRejection += e.rejectionQuantity;
      totalRunningHours += e.runningHours;
      totalWeightKg += e.weightInKGs;
    }

    final count = NumberFormat.decimalPattern();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: VistarPalette.heroGradient,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${entries.length} shift${entries.length == 1 ? '' : 's'} logged',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _SummaryBadge(label: 'Total Qty', value: count.format(totalActual)),
              _SummaryBadge(
                label: 'Rejection',
                value: count.format(totalRejection),
              ),
              _SummaryBadge(
                label: 'Running Hrs',
                value: totalRunningHours.toStringAsFixed(2),
              ),
              _SummaryBadge(
                label: 'Weight (kg)',
                value: totalWeightKg.toStringAsFixed(2),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryBadge extends StatelessWidget {
  final String label;
  final String value;

  const _SummaryBadge({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

class _ShiftSection extends StatelessWidget {
  final String shift;
  final List<ProductionEntryModel> entries;

  const _ShiftSection({required this.shift, required this.entries});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VistarPalette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: VistarPalette.info.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'Shift $shift',
                  style: TextStyle(
                    color: VistarPalette.infoInk,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${entries.length} entr${entries.length == 1 ? 'y' : 'ies'}',
                style: TextStyle(
                  color: VistarPalette.txt2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (int i = 0; i < entries.length; i++) ...[
            _ShiftEntryCard(entry: entries[i]),
            if (i < entries.length - 1)
              Divider(height: 18, color: VistarPalette.line),
          ],
        ],
      ),
    );
  }
}

class _ShiftEntryCard extends StatelessWidget {
  final ProductionEntryModel entry;

  const _ShiftEntryCard({required this.entry});

  String _safe(String? value) {
    final t = (value ?? '').trim();
    return t.isEmpty ? '-' : t;
  }

  String _formatTime(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '-';
    final parsed = DateTime.tryParse(text);
    if (parsed != null) return DateFormat('HH:mm').format(parsed.toLocal());
    final hhmm = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)').firstMatch(text);
    if (hhmm != null) return '${hhmm.group(1)}:${hhmm.group(2)}';
    return text;
  }

  String _operatorLabel() {
    if (entry.operatorNames.isNotEmpty) return entry.operatorNames.join(', ');
    final name = (entry.operatorName ?? '').trim();
    if (name.isNotEmpty) return name;
    return _safe(entry.operatorId);
  }

  @override
  Widget build(BuildContext context) {
    final machine = _safe(entry.machineName ?? entry.machineId);
    final item = _safe(entry.itemDescription ?? entry.itemId);
    final start = _formatTime(entry.startTime);
    final end = _formatTime(entry.endTime);
    final approval = _safe(entry.approvalStatus ?? 'Pending');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                '$machine  |  $item',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _StatusPill(status: approval),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Operator: ${_operatorLabel()}',
          style: TextStyle(color: VistarPalette.txt2),
        ),
        const SizedBox(height: 2),
        Text(
          'Time: $start → $end  |  Running Hrs: ${entry.runningHours.toStringAsFixed(2)}',
          style: TextStyle(color: VistarPalette.txt2),
        ),
        const SizedBox(height: 2),
        Text(
          'Actual: ${entry.actualQuantity}  |  Rejection: ${entry.rejectionQuantity}  |  Parts/Hr: ${entry.partsPerHour.toStringAsFixed(1)}',
          style: TextStyle(color: VistarPalette.txt2),
        ),
        if ((entry.rcNumber ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            'RC: ${entry.rcNumber}',
            style: TextStyle(color: VistarPalette.txt2),
          ),
        ],
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String status;

  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final normalized = status.toUpperCase();
    Color bg;
    Color fg;
    if (normalized == 'APPROVED') {
      bg = VistarPalette.okBg;
      fg = VistarPalette.ok;
    } else if (normalized == 'REJECTED') {
      bg = VistarPalette.badBg;
      fg = VistarPalette.bad;
    } else {
      bg = VistarPalette.warnBg;
      fg = VistarPalette.warn;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _ShiftDetailsLoading extends StatelessWidget {
  const _ShiftDetailsLoading();

  @override
  Widget build(BuildContext context) {
    return AppShimmer(
      child: Column(
        children: List.generate(
          3,
          (_) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: VistarPalette.surface,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(height: 14, width: 110),
                  SizedBox(height: 10),
                  SkeletonBox(height: 12, width: 240),
                  SizedBox(height: 8),
                  SkeletonBox(height: 12, width: 220),
                  SizedBox(height: 8),
                  SkeletonBox(height: 12, width: 200),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: VistarPalette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Column(
        children: [
          Icon(
            Icons.event_busy_outlined,
            size: 36,
            color: VistarPalette.txt2,
          ),
          SizedBox(height: 8),
          Text(
            'No shifts logged',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          SizedBox(height: 4),
          Text(
            'No production entries found for the selected date.',
            textAlign: TextAlign.center,
            style: TextStyle(color: VistarPalette.txt2),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VistarPalette.badBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.badLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Could not load shift details',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: VistarPalette.bad,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(message, style: TextStyle(color: VistarPalette.badInk)),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
