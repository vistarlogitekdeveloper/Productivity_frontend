import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../journey/widgets/scanner_error_view.dart';
import '../../models/dpl_trip_label_scan.dart';

/// Scans the labels this system printed onto a trip, before it goes to the DEO.
///
/// Deliberately a CONTINUOUS scanner: the dispatcher works through a trolley of
/// sixteen pieces, and popping back to the trip card after each one would make
/// the flow unusable. The camera restarts itself after every scan and the live
/// tally sits at the bottom of the screen.
///
/// Every refusal is spoken in terms of the piece in the operator's hand —
/// "already on trip #4", "not on this trip", "one too many" — because "invalid"
/// tells someone holding a physical part nothing about what to do with it.
class TripLabelScanScreen extends ConsumerStatefulWidget {
  final int tripId;
  final int tripNumber;

  const TripLabelScanScreen({
    super.key,
    required this.tripId,
    required this.tripNumber,
  });

  @override
  ConsumerState<TripLabelScanScreen> createState() =>
      _TripLabelScanScreenState();
}

class _TripLabelScanScreenState extends ConsumerState<TripLabelScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    // Our own piece labels are QR. DataMatrix and Code 128 stay enabled so a
    // supplier label scanned here by mistake is REJECTED by name rather than
    // silently ignored, which would read as a broken scanner.
    formats: const [
      BarcodeFormat.qrCode,
      BarcodeFormat.dataMatrix,
      BarcodeFormat.code128,
    ],
  );

  bool _busy = false;
  DplTripScanProgress? _progress;
  String? _lastMessage;
  bool _lastWasError = false;

  @override
  void initState() {
    super.initState();
    _loadProgress();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadProgress() async {
    final res = await ref.read(dplApiServiceProvider).getTripLabelScans(widget.tripId);
    if (!mounted) return;
    if (res.isOk && res.data != null) {
      setState(() => _progress = res.data);
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy) return;
    final code = capture.barcodes
        .map((b) => b.rawValue?.trim() ?? '')
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (code.isEmpty) return;

    setState(() => _busy = true);
    await _controller.stop();
    await _submit(code);
  }

  Future<void> _submit(String code) async {
    final res = await ref.read(dplApiServiceProvider).scanLabelToTrip(
          tripId: widget.tripId,
          code: code,
        );
    if (!mounted) return;

    setState(() {
      _busy = false;
      if (res.isError) {
        _lastWasError = true;
        _lastMessage = res.error ?? 'That label could not be scanned.';
      } else {
        _lastWasError = false;
        _progress = res.data ?? _progress;
        _lastMessage = 'Scanned.';
      }
    });

    // Distinct feedback so the operator can work without watching the screen.
    if (res.isError) {
      HapticFeedback.heavyImpact();
    } else {
      HapticFeedback.lightImpact();
    }

    await _restart();
  }

  Future<void> _restart() async {
    if (!mounted) return;
    try {
      await _controller.start();
    } catch (_) {
      // start() throws when the camera is already running — safe to ignore.
    }
  }

  Future<void> _manualEntry() async {
    await _controller.stop();
    if (!mounted) return;
    final serial = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ManualSerialSheet(),
    );
    if (!mounted) return;
    if (serial == null || serial.trim().isEmpty) {
      await _restart();
      return;
    }
    setState(() => _busy = true);
    await _submit(serial.trim());
  }

  Future<void> _undo(String serial) async {
    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).undoTripLabelScan(
          tripId: widget.tripId,
          serial: serial,
        );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res.isError) {
        _lastWasError = true;
        _lastMessage = res.error ?? 'Could not undo that scan.';
      } else {
        _lastWasError = false;
        _progress = res.data ?? _progress;
        _lastMessage = 'Removed $serial.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final complete = progress?.isComplete ?? false;

    return PopScope(
      // Hand the latest progress back so the trip card re-evaluates its Send
      // gate without waiting for a provider refresh.
      canPop: true,
      onPopInvokedWithResult: (_, _) {},
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: DplAppBar(
          title: 'Scan labels · Trip #${widget.tripNumber}',
          actions: [
            IconButton(
              tooltip: 'Enter serial by hand',
              icon: const Icon(Icons.keyboard_alt_outlined),
              onPressed: _busy ? null : _manualEntry,
            ),
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
              errorBuilder: (_, err, _) => ScannerErrorView(
                error: err,
                onRetry: _controller.start,
              ),
            ),
            const IgnorePointer(child: _ScanFrameOverlay()),
            if (_lastMessage != null)
              Positioned(
                top: 12,
                left: 0,
                right: 0,
                child: Center(
                  child: _FeedbackPill(
                    text: _lastMessage!,
                    isError: _lastWasError,
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _ProgressPanel(
                progress: progress,
                complete: complete,
                busy: _busy,
                onUndo: _undo,
                onDone: () => Navigator.of(context).pop(progress),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Live tally per plan, plus the way out once everything is accounted for.
class _ProgressPanel extends StatelessWidget {
  final DplTripScanProgress? progress;
  final bool complete;
  final bool busy;
  final ValueChanged<String> onUndo;
  final VoidCallback onDone;

  const _ProgressPanel({
    required this.progress,
    required this.complete,
    required this.busy,
    required this.onUndo,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final p = progress;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (p == null)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(),
                ),
              )
            else ...[
              for (final plan in p.plans)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _PlanProgressRow(plan: plan, onUndo: onUndo),
                ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: busy ? null : onDone,
                  icon: Icon(
                    complete ? Icons.check_rounded : Icons.close_rounded,
                    size: 18,
                  ),
                  label: Text(
                    complete
                        ? 'All pieces scanned — done'
                        : 'Stop scanning',
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: complete ? const Color(0xFF15803D) : null,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlanProgressRow extends StatelessWidget {
  final DplTripPlanScan plan;
  final ValueChanged<String> onUndo;

  const _PlanProgressRow({required this.plan, required this.onUndo});

  @override
  Widget build(BuildContext context) {
    final ratio = plan.plannedQty <= 0
        ? 0.0
        : (plan.scannedQty / plan.plannedQty).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                plan.label,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '${plan.scannedQty} / ${plan.plannedQty}',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                color: plan.isComplete
                    ? const Color(0xFF15803D)
                    : const Color(0xFF334155),
              ),
            ),
            if (plan.serials.isNotEmpty)
              IconButton(
                tooltip: 'Undo last scan (${plan.serials.last.serialNo})',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.undo_rounded, size: 18),
                onPressed: () => onUndo(plan.serials.last.serialNo),
              ),
          ],
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 6,
            backgroundColor: const Color(0xFFEEF1F5),
            valueColor: AlwaysStoppedAnimation(
              plan.isComplete ? const Color(0xFF15803D) : const Color(0xFF6366F1),
            ),
          ),
        ),
      ],
    );
  }
}

class _ManualSerialSheet extends StatefulWidget {
  const _ManualSerialSheet();

  @override
  State<_ManualSerialSheet> createState() => _ManualSerialSheetState();
}

class _ManualSerialSheetState extends State<_ManualSerialSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        18,
        4,
        18,
        MediaQuery.of(context).viewInsets.bottom + 18,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enter the serial by hand',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
          ),
          const SizedBox(height: 4),
          const Text(
            'Type the serial printed under the code, for example GA2600000147.',
            style: TextStyle(
              color: Color(0xFF5D6A7A),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Serial',
              hintText: 'GA2600000147',
              prefixIcon: Icon(Icons.numbers_rounded),
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_ctrl.text),
                  child: const Text('Add'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Scanner chrome (copy-pasted per the convention the other scanners set) ──

class _ScanFrameOverlay extends StatelessWidget {
  const _ScanFrameOverlay();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _ScanFramePainter(), child: const SizedBox());
  }
}

class _ScanFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final box = size.shortestSide * 0.62;
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.36),
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

class _FeedbackPill extends StatelessWidget {
  final String text;
  final bool isError;

  const _FeedbackPill({required this.text, required this.isError});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isError
            ? const Color(0xFFB91C1C).withValues(alpha: 0.94)
            : const Color(0xFF15803D).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            color: Colors.white,
            size: 18,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
