import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../models/dpl_downtime_reason.dart';
import '../providers/downtime_provider.dart';

/// Result of [PauseEntrySheet]. Pop with `null` to cancel.
class PauseEntryResult {
  final int? reasonId;
  final String reasonText;
  final DateTime? expectedResumeAt;

  const PauseEntryResult({
    required this.reasonText,
    this.reasonId,
    this.expectedResumeAt,
  });
}

/// Bottom sheet for pausing a plan item. Mirrors [DowntimeEntrySheet]
/// visually so supervisors don't have to learn a new form.
class PauseEntrySheet extends ConsumerStatefulWidget {
  final String itemLabel;
  const PauseEntrySheet({super.key, required this.itemLabel});

  @override
  ConsumerState<PauseEntrySheet> createState() => _PauseEntrySheetState();
}

class _PauseEntrySheetState extends ConsumerState<PauseEntrySheet> {
  int? _reasonId;
  DateTime? _expected;
  final _notesCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickExpected() async {
    final now = DateTime.now();
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        _expected ?? now.add(const Duration(minutes: 30)),
      ),
    );
    if (time == null) return;
    final picked = DateTime(
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );
    // If the picked time has already passed today, bump to tomorrow so
    // the supervisor's intent stays in the future.
    setState(() => _expected =
        picked.isBefore(now) ? picked.add(const Duration(days: 1)) : picked);
  }

  void _submit() {
    final text = _notesCtrl.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Notes are required.');
      return;
    }
    Navigator.of(context).pop(PauseEntryResult(
      reasonId: _reasonId,
      reasonText: text,
      expectedResumeAt: _expected,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final reasonsAsync = ref.watch(supervisorDowntimeReasonsProvider);
    final reasons = reasonsAsync.asData?.value.data ?? const <DplDowntimeReason>[];
    final media = MediaQuery.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: 16 + media.viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: VistarPalette.line2,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Row(
            children: [
              Icon(Icons.pause_circle_outline, color: VistarPalette.warn),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Pause Item',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              widget.itemLabel,
              style: TextStyle(color: VistarPalette.txt2),
            ),
          ),
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: VistarPalette.badBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: VistarPalette.badLine),
              ),
              child: Text(
                _error!,
                style: TextStyle(
                  color: VistarPalette.badInk,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          DropdownButtonFormField<int?>(
            initialValue: _reasonId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Reason (optional)',
              prefixIcon: Icon(Icons.flag_outlined),
            ),
            items: [
              const DropdownMenuItem<int?>(
                value: null,
                child: Text('No master reason'),
              ),
              for (final r in reasons)
                DropdownMenuItem<int?>(
                  value: r.id,
                  child: Text(
                    '${r.name}  (${r.category})',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _reasonId = v),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _notesCtrl,
            maxLines: 3,
            maxLength: 1000,
            decoration: const InputDecoration(
              labelText: 'Notes (required)',
              prefixIcon: Icon(Icons.notes_outlined),
              hintText: 'What happened? Captured on the audit log.',
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pickExpected,
            icon: const Icon(Icons.schedule),
            label: Text(
              _expected == null
                  ? 'Expected resume time (optional)'
                  : 'Resume by ${DateFormat('d MMM, hh:mm a').format(_expected!)}',
            ),
          ),
          if (_expected != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => _expected = null),
                child: const Text('Clear'),
              ),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.pause_rounded),
                    label: const Text('Pause Item'),
                    onPressed: _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: VistarPalette.warnSolid,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
