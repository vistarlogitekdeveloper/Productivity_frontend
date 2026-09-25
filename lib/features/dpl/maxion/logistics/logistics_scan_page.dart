import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../journey/widgets/scanner_error_view.dart';

/// What a scan handler tells the scanner page to show.
typedef LogisticsScanOutcome = ({bool ok, String message});

/// A continuous camera scanner for the logistics screens.
///
/// Same rhythm as the trip label scanner: detect → stop the camera → call the
/// server → haptic → show the outcome → start again, so an operator works
/// through a crate of returned wheels without tapping between them.
class LogisticsContinuousScanPage extends StatefulWidget {
  const LogisticsContinuousScanPage({
    super.key,
    required this.title,
    required this.onCode,
    this.formats = const [
      BarcodeFormat.qrCode,
      BarcodeFormat.dataMatrix,
      BarcodeFormat.code128,
    ],
  });

  final String title;
  final Future<LogisticsScanOutcome> Function(String code) onCode;
  final List<BarcodeFormat> formats;

  @override
  State<LogisticsContinuousScanPage> createState() => _LogisticsContinuousScanPageState();
}

class _LogisticsContinuousScanPageState extends State<LogisticsContinuousScanPage> {
  late final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: widget.formats,
  );

  bool _busy = false;
  String? _message;
  bool _lastWasError = false;
  int _okCount = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy) return;
    final code = capture.barcodes
        .map((b) => b.rawValue?.trim() ?? '')
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (code.isEmpty) return;
    setState(() => _busy = true);
    await _controller.stop();
    final out = await widget.onCode(code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lastWasError = !out.ok;
      _message = out.message;
      if (out.ok) _okCount++;
    });
    if (out.ok) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.heavyImpact();
    }
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
          IconButton(
            tooltip: 'Toggle torch',
            icon: const Icon(Icons.flash_on_outlined),
            onPressed: _controller.toggleTorch,
          ),
          IconButton(
            tooltip: 'Flip camera',
            icon: const Icon(Icons.cameraswitch_outlined),
            onPressed: _controller.switchCamera,
          ),
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
          const IgnorePointer(child: LogisticsScanFrameOverlay()),
          if (_message != null)
            Positioned(
              top: 12,
              left: 0,
              right: 0,
              child: Center(child: LogisticsFeedbackPill(text: _message!, isError: _lastWasError)),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
              ),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _busy ? 'Checking…' : '$_okCount received this session',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _busy ? null : () => Navigator.of(context).pop(_okCount),
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Done'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Scanner chrome (copied per the convention the other scanners set) ──

class LogisticsScanFrameOverlay extends StatelessWidget {
  const LogisticsScanFrameOverlay({super.key});

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _ScanFramePainter(), child: const SizedBox());
}

class _ScanFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final box = size.shortestSide * 0.62;
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.4),
      width: box,
      height: box,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(18));
    final scrim = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(scrim, Paint()..color = Colors.black.withValues(alpha: 0.5));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xFF8B5CF6),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class LogisticsFeedbackPill extends StatelessWidget {
  const LogisticsFeedbackPill({super.key, required this.text, required this.isError});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: (isError ? const Color(0xFFB91C1C) : const Color(0xFF15803D)).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isError ? Icons.error_outline : Icons.check_circle_outline, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
