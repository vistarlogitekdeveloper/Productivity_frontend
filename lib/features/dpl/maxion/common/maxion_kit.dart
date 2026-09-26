import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../reports/report_download_stub.dart'
    if (dart.library.html) '../../../reports/report_download_web.dart'
    if (dart.library.io) '../../../reports/report_download_io.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_response.dart';
import '../../core/dpl_language_provider.dart';
import '../../core/widgets/dpl_snack.dart';

/// Shared pieces for the Maxion screens (backend phases 1–4 and offline).

/// Shows a refusal the way an operator on the floor needs it: the line in
/// their language (when they chose Marathi or Hindi and the server has one)
/// first, then the English with the serial or pallet number.
void showFloorError(BuildContext context, DplApiResponse<dynamic> res, {String fallback = 'That did not work.'}) {
  final text = res.floorMessage.trim().isEmpty ? fallback : res.floorMessage;
  DplSnacks.error(context, text);
}

/// App-bar action to choose the floor language (English / मराठी / हिन्दी).
class DplLanguageMenuButton extends ConsumerWidget {
  const DplLanguageMenuButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(dplLanguageProvider);
    return PopupMenuButton<String>(
      tooltip: 'Language',
      icon: const Icon(Icons.translate),
      initialValue: current ?? 'en',
      onSelected: (v) => ref.read(dplLanguageProvider.notifier).set(v == 'en' ? null : v),
      itemBuilder: (_) => DplLanguageController.choices.entries
          .map((e) => PopupMenuItem<String>(
                value: e.key ?? 'en',
                child: Row(children: [
                  Icon(e.key == current ? Icons.check : Icons.circle_outlined, size: 16),
                  const SizedBox(width: 8),
                  Text(e.value),
                ]),
              ))
          .toList(),
    );
  }
}

/// Saves bytes from the server (Excel, PDF) to Downloads on a device or as a
/// browser download on web, and says where.
Future<void> saveServerFile(BuildContext context, DplApiResponse<Uint8List> res,
    {required String fileName, required String mimeType}) async {
  if (res.isError || res.data == null) {
    showFloorError(context, res, fallback: 'Could not download $fileName.');
    return;
  }
  try {
    final path = await saveReportBytes(bytes: res.data!, fileName: fileName, mimeType: mimeType);
    if (!context.mounted) return;
    DplSnacks.success(context, path == null ? 'Downloaded.' : 'Saved: $path');
  } catch (e) {
    if (context.mounted) DplSnacks.error(context, 'Could not save $fileName: $e');
  }
}

const xlsxMime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
const pdfMime = 'application/pdf';

String ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

/// A from–to date picker row for the date-range reports (max 92 days server-side).
class DplDateRangeBar extends StatelessWidget {
  final DateTimeRange range;
  final ValueChanged<DateTimeRange> onChanged;

  const DplDateRangeBar({super.key, required this.range, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM yyyy');
    final label = range.start == range.end
        ? fmt.format(range.start)
        : '${fmt.format(range.start)} – ${fmt.format(range.end)}';
    return OutlinedButton.icon(
      icon: const Icon(Icons.date_range, size: 18),
      label: Text(label),
      onPressed: () async {
        final now = DateTime.now();
        final picked = await showDateRangePicker(
          context: context,
          firstDate: DateTime(now.year - 2),
          lastDate: now,
          initialDateRange: range,
        );
        if (picked != null) onChanged(picked);
      },
    );
  }
}

/// A small coloured count chip for status summaries.
class DplCountChip extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const DplCountChip({super.key, required this.label, required this.count, this.color = DplColors.primary});

  @override
  Widget build(BuildContext context) => Chip(
        visualDensity: VisualDensity.compact,
        backgroundColor: color.withValues(alpha: 0.1),
        side: BorderSide(color: color.withValues(alpha: 0.3)),
        label: Text('$label  $count', style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      );
}
