import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../journey/widgets/scanner_error_view.dart';
import '../../models/dpl_part.dart';
import '../../models/dpl_part_sticker.dart';
import 'qa_sticker_print_screen.dart';

/// Scans the Grupo Antolin label on a produced part and resolves it to the
/// customer part reference(s) it maps to.
///
/// Two things differ from every other scanner in this app, both deliberate:
///
///   * FORMATS. The other scanners pass `formats: [BarcodeFormat.qrCode]`
///     and therefore physically cannot read this label — the raw-material
///     symbol is a 2D matrix code, almost certainly DataMatrix. DataMatrix is
///     enabled here alongside QR and Code 128. The list is kept narrow rather
///     than omitted entirely because on web every enabled format costs ZXing
///     decode time per frame.
///
///   * MANUAL ENTRY. SSR §5 requires that a damaged code can still be keyed
///     in from the text printed under it. A thermal label that has been
///     through a press shop is exactly the case where that matters, so the
///     substrate number can always be typed instead.
class QaScannerScreen extends ConsumerStatefulWidget {
  final int planId;
  final int planItemId;

  /// The part this plan item is producing. Labels may only ever be printed for
  /// it, so a scan that resolves to any other part is refused here rather than
  /// being offered in a picker. Zero means "unknown", in which case the picker
  /// is used and the server is left to enforce the rule.
  final int expectedPartId;

  /// Display-only, for the refusal message.
  final String expectedPartNumber;

  const QaScannerScreen({
    super.key,
    required this.planId,
    required this.planItemId,
    this.expectedPartId = 0,
    this.expectedPartNumber = '',
  });

  @override
  ConsumerState<QaScannerScreen> createState() => _QaScannerScreenState();
}

class _QaScannerScreenState extends ConsumerState<QaScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [
      BarcodeFormat.dataMatrix,
      BarcodeFormat.qrCode,
      BarcodeFormat.code128,
    ],
  );

  bool _busy = false;
  String? _pending;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    // Guard first, before touching the capture — DetectionSpeed.noDuplicates
    // still fires overlapping detections while a request is in flight.
    if (_busy || _pending != null) return;
    final code = capture.barcodes
        .map((b) => b.rawValue?.trim() ?? '')
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (code.isEmpty) return;

    setState(() {
      _pending = code;
      _busy = true;
    });
    await _controller.stop();
    await _resolve(rawPayload: code);
  }

  /// Sends whatever we have to the server and routes on the answer.
  Future<void> _resolve({String? rawPayload, String? substratePartNo}) async {
    final res = await ref.read(dplApiServiceProvider).resolveQaScan(
          rawPayload: rawPayload,
          substratePartNo: substratePartNo,
        );
    if (!mounted) return;

    if (res.isError || res.data == null) {
      if (res.code == 'SUBSTRATE_NOT_FOUND') {
        await _showUnknownSubstrate(rawPayload, res.error);
      } else {
        DplSnacks.error(context, res.error ?? 'Could not read that label.');
        await _restart();
      }
      return;
    }

    final resolution = res.data!;
    if (resolution.parts.isEmpty) {
      await _showUnknownSubstrate(rawPayload, null);
      return;
    }

    // The plan item already decided which part is being made, so the scan is a
    // VERIFICATION step, not a choice. Printing 102ZX labels while the item is
    // producing 119ZY would put the wrong identity on a physical part and spend
    // the wrong item's quantity allowance — so material for another part is
    // refused outright instead of being offered in a picker.
    //
    // This is also why a substrate serving several customer parts no longer
    // needs to ask: the plan item disambiguates it.
    DplPart? picked;
    if (widget.expectedPartId > 0) {
      final matches = resolution.parts
          .where((p) => p.id == widget.expectedPartId)
          .toList();
      if (matches.isEmpty) {
        await _showWrongPart(resolution, rawPayload);
        return;
      }
      picked = matches.first;
    } else {
      // No expected part on the route (deep link / older link). Fall back to
      // asking, and let the server reject a mismatch.
      picked = resolution.hasSingleMatch
          ? resolution.parts.first
          : await _pickPart(resolution);
    }

    if (!mounted) return;
    final chosen = picked;
    if (chosen == null) {
      await _restart();
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => QaStickerPrintScreen(
          planId: widget.planId,
          planItemId: widget.planItemId,
          part: chosen,
          substratePartNo: resolution.substratePartNo,
          rawPayload: rawPayload,
        ),
      ),
    );
    await _restart();
  }

  /// Picker shown when a substrate maps to several customer part references.
  Future<DplPart?> _pickPart(DplScanResolution resolution) {
    return showModalBottomSheet<DplPart>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Choose the customer part',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Substrate ${resolution.substratePartNo} is used by '
                    '${resolution.parts.length} customer parts. Pick the one '
                    'you are packing.',
                    style: const TextStyle(
                      color: Color(0xFF5D6A7A),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: resolution.parts.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final p = resolution.parts[i];
                  return ListTile(
                    title: Text(
                      p.partNumber.isEmpty ? p.description : p.partNumber,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      [
                        if (p.description.isNotEmpty) p.description,
                        if (p.machineName.isNotEmpty) p.machineName,
                      ].join(' · '),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(ctx).pop(p),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// The scan resolved, but to a part this plan item is not producing.
  ///
  /// Deliberately a blocking, high-contrast sheet with no way to continue: the
  /// operator is holding the wrong material, and every option other than
  /// "fetch the right material" ends with a wrong label on a real part.
  Future<void> _showWrongPart(
    DplScanResolution resolution,
    String? rawPayload,
  ) async {
    final scanned = resolution.parts
        .map((p) => p.partNumber.isEmpty ? p.description : p.partNumber)
        .where((s) => s.isNotEmpty)
        .join(', ');

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.block_rounded, color: Color(0xFFB91C1C)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Wrong material for this item',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _compare(
              label: 'This item is making',
              value: widget.expectedPartNumber.isEmpty
                  ? 'part #${widget.expectedPartId}'
                  : widget.expectedPartNumber,
              good: true,
            ),
            const SizedBox(height: 8),
            _compare(
              label: 'You scanned material for',
              value: scanned.isEmpty ? 'another part' : scanned,
              good: false,
            ),
            const SizedBox(height: 14),
            const Text(
              'Labels can only be printed for the part on the plan item. '
              'Fetch the correct raw material and scan again.',
              style: TextStyle(
                color: Color(0xFF5D6A7A),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (resolution.substratePartNo.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Scanned substrate: ${resolution.substratePartNo}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Color(0xFF334155),
                ),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Scan again'),
              ),
            ),
          ],
        ),
      ),
    );

    if (!mounted) return;
    await _restart();
  }

  Widget _compare({
    required String label,
    required String value,
    required bool good,
  }) {
    final color = good ? const Color(0xFF15803D) : const Color(0xFFB91C1C);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              color: Color(0xFF111827),
            ),
          ),
        ],
      ),
    );
  }

  /// Nothing in the master matched. Show what was actually read and offer
  /// manual entry — a dead end here would strand the operator mid-shift.
  Future<void> _showUnknownSubstrate(String? rawPayload, String? error) async {
    final typed = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _ManualEntrySheet(
        rawPayload: rawPayload,
        message: error,
      ),
    );

    if (!mounted) return;
    if (typed == null || typed.trim().isEmpty) {
      await _restart();
      return;
    }
    // Keyed by hand — resolve again, this time by the exact substrate.
    await _resolve(rawPayload: rawPayload, substratePartNo: typed.trim());
  }

  Future<void> _restart() async {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pending = null;
    });
    try {
      await _controller.start();
    } catch (_) {
      // start() throws if the camera is already running — safe to ignore.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: DplAppBar(
        title: 'QA · Scan Raw Material',
        actions: [
          IconButton(
            tooltip: 'Enter code by hand',
            icon: const Icon(Icons.keyboard_alt_outlined),
            onPressed: _busy
                ? null
                : () async {
                    await _controller.stop();
                    if (!mounted) return;
                    await _showUnknownSubstrate(null, null);
                  },
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
          const IgnorePointer(child: _ScannerFrameOverlay()),
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: Center(
              // Naming the expected part up front turns a refusal into
              // something the operator could have avoided.
              child: _HintPill(
                text: widget.expectedPartNumber.isEmpty
                    ? 'Scan the label on the raw material.'
                    : 'Scan raw material for ${widget.expectedPartNumber}.',
              ),
            ),
          ),
          if (_busy) const _BusyOverlay(),
        ],
      ),
    );
  }
}

/// Manual entry of the substrate number printed under the symbol.
class _ManualEntrySheet extends StatefulWidget {
  final String? rawPayload;
  final String? message;

  const _ManualEntrySheet({this.rawPayload, this.message});

  @override
  State<_ManualEntrySheet> createState() => _ManualEntrySheetState();
}

class _ManualEntrySheetState extends State<_ManualEntrySheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final raw = widget.rawPayload?.trim() ?? '';

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
          Text(
            raw.isEmpty ? 'Enter substrate part number' : 'Label not recognised',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
          ),
          const SizedBox(height: 4),
          Text(
            widget.message ??
                'Type the substrate part number printed under the code, '
                    'for example 195245450-083.',
            style: const TextStyle(
              color: Color(0xFF5D6A7A),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (raw.isNotEmpty) ...[
            const SizedBox(height: 12),
            // Showing the raw payload is not decoration: it is how we find out
            // what this label actually encodes, and it lets the operator see
            // the scanner did read something.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Scanned',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    raw,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          TextField(
            controller: _ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Substrate part number',
              hintText: '195245450-083',
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
                  child: const Text('Look up'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Scanner chrome. Copy-pasted per the convention already set by the QRE,
// security and slip-verifier scanners, which each carry their own copy.
// -----------------------------------------------------------------------------

class _ScannerFrameOverlay extends StatelessWidget {
  const _ScannerFrameOverlay();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _ScannerFramePainter(), child: const SizedBox());
  }
}

class _ScannerFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final box = size.shortestSide * 0.72;
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: box,
      height: box,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(18));

    final scrim = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(scrim, Paint()..color = Colors.black.withValues(alpha: 0.55));

    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xFF8B5CF6),
    );

    const tick = 22.0;
    final corner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFF5A623);

    canvas
      ..drawLine(rect.topLeft, rect.topLeft + const Offset(tick, 0), corner)
      ..drawLine(rect.topLeft, rect.topLeft + const Offset(0, tick), corner)
      ..drawLine(rect.topRight, rect.topRight + const Offset(-tick, 0), corner)
      ..drawLine(rect.topRight, rect.topRight + const Offset(0, tick), corner)
      ..drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(tick, 0), corner)
      ..drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(0, -tick), corner)
      ..drawLine(
          rect.bottomRight, rect.bottomRight + const Offset(-tick, 0), corner)
      ..drawLine(
          rect.bottomRight, rect.bottomRight + const Offset(0, -tick), corner);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _HintPill extends StatelessWidget {
  final String text;

  const _HintPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _BusyOverlay extends StatelessWidget {
  const _BusyOverlay();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
            ),
            SizedBox(height: 14),
            Text(
              'Looking up the part…',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
