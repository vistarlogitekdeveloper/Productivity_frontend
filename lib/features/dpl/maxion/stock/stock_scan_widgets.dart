import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/design/dpl_theme.dart';
import '../../journey/widgets/scanner_error_view.dart';

/// What happened to one scanned code, shown as feedback.
class DplScanFeedback {
  final String message;
  final bool ok;
  const DplScanFeedback(this.message, {this.ok = true});
}

/// A camera that stays open and hands every code it reads to [onCode].
///
/// Deliberately does not judge the code: pallet labels, pallet numbers and
/// wheel labels are all valid somewhere, and the server is the authority on
/// every scan. The camera pauses while [onCode] runs, so one label is never
/// submitted twice, and resumes for the next.
class DplContinuousScanPage extends StatefulWidget {
  final String title;

  /// Shown under the viewfinder, e.g. the rack being counted.
  final String hint;

  final Future<DplScanFeedback> Function(String code) onCode;

  const DplContinuousScanPage({super.key, required this.title, required this.onCode, this.hint = ''});

  static Future<void> open(
    BuildContext context, {
    required String title,
    required Future<DplScanFeedback> Function(String code) onCode,
    String hint = '',
  }) {
    return Navigator.of(context).push<void>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => DplContinuousScanPage(title: title, hint: hint, onCode: onCode),
    ));
  }

  @override
  State<DplContinuousScanPage> createState() => _DplContinuousScanPageState();
}

class _DplContinuousScanPageState extends State<DplContinuousScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode, BarcodeFormat.dataMatrix, BarcodeFormat.code128],
  );

  bool _busy = false;
  DplScanFeedback? _last;
  int _count = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy) return;
    final code = capture.barcodes.map((b) => b.rawValue?.trim() ?? '').firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (code.isEmpty) return;
    setState(() => _busy = true);
    await _controller.stop();
    final fb = await widget.onCode(code);
    if (!mounted) return;
    if (fb.ok) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.heavyImpact();
    }
    setState(() {
      _busy = false;
      _last = fb;
      if (fb.ok) _count++;
    });
    try {
      await _controller.start();
    } catch (_) {
      // Already running.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(tooltip: 'Torch', icon: const Icon(Icons.flash_on), onPressed: _controller.toggleTorch),
          IconButton(tooltip: 'Switch camera', icon: const Icon(Icons.cameraswitch_outlined), onPressed: _controller.switchCamera),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (_, err, _) => ScannerErrorView(error: err, onRetry: _controller.start),
          ),
          if (_busy) const Center(child: CircularProgressIndicator()),
          if (_last != null)
            Positioned(
              top: 12,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: _last!.ok ? DplColors.success : DplColors.error,
                  borderRadius: BorderRadius.circular(DplRadius.md),
                ),
                child: Text(_last!.message, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: SafeArea(
                top: false,
                child: Row(children: [
                  Expanded(
                    child: Text(
                      widget.hint.isEmpty ? '$_count scanned' : '${widget.hint}  ·  $_count scanned',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Colour for a rack-count line result.
Color dplCountResultColor(String? result) {
  switch (result) {
    case 'matched':
      return DplColors.success;
    case 'misplaced':
      return DplColors.warning;
    case 'missing':
      return DplColors.error;
    case 'unexpected':
      return DplColors.info;
    default:
      return DplColors.neutral;
  }
}

/// A small coloured pill with a label.
class DplTagPill extends StatelessWidget {
  final String label;
  final Color color;
  const DplTagPill({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(DplRadius.pill),
        ),
        child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 11.5)),
      );
}

/// Asks for a note. Returns null when dismissed; enforces [minLength] when set.
Future<String?> askDplNote(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String hint = 'Note',
  int minLength = 0,
  String? message,
}) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final ok = ctrl.text.trim().length >= minLength;
        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message != null) ...[Text(message), const SizedBox(height: 12)],
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                maxLength: 255,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: hint,
                  helperText: minLength > 0 ? 'Required' : 'Optional',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: ok ? () => Navigator.pop(ctx, ctrl.text.trim()) : null, child: Text(confirmLabel)),
          ],
        );
      },
    ),
  );
}

/// A yes/no confirmation.
Future<bool> confirmDpl(BuildContext context, {required String title, required String message, required String confirmLabel}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(confirmLabel)),
      ],
    ),
  );
  return ok == true;
}
