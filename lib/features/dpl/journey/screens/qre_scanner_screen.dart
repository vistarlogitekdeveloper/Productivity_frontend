import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_snack.dart';
import '../providers/journey_session_state.dart';
import '../widgets/scanner_error_view.dart';

/// QRE's home screen at TATA — full-screen scanner that walks the QRE
/// through the two-step receive:
///
///   1. Camera opens. On a QR detect we decode the payload locally so
///      the user can see which trip they're accepting, then POST to
///      `/tata-dock-in` with the raw `qr_token`.
///   2. On 200 we push the Dock Out form — empty-trolley count + optional
///      remarks — and, on that form's success, pop back here so the next
///      truck can be received without leaving the screen.
///
/// Backend contract:
///   * `INVALID_STATUS` (409) fires when the trip hasn't yet been marked
///     `tata_gate_in` by the driver. We surface a specific "Trip not at
///     gate-in yet" error so the QRE tells the driver to close the
///     step at security first, rather than a generic conflict string.
///   * The signature on the QR is re-checked server-side; the local
///     decode here is purely so the user sees `trip_number` while the
///     dock-in request is in flight.
class QreScannerScreen extends ConsumerStatefulWidget {
  const QreScannerScreen({super.key});

  @override
  ConsumerState<QreScannerScreen> createState() => _QreScannerScreenState();
}

class _QreScannerScreenState extends ConsumerState<QreScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  bool _busy = false;
  String? _pendingToken;

  /// Set for the duration of the dock-in call so we can paint a
  /// full-screen "Docking-in Trip #N…" overlay instead of leaving the
  /// user staring at a live camera preview during the network round-trip.
  int? _dockingInTripNo;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy || _pendingToken != null) return;
    final code = capture.barcodes
        .map((b) => b.rawValue?.trim() ?? '')
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (code.isEmpty) return;

    setState(() {
      _pendingToken = code;
      _busy = true;
    });
    await _controller.stop();

    final payload = _decodeJwtPayload(code);
    final tripId = _readInt(payload, const ['trip_id', 'tripId', 'id']);
    final tripNo = _readInt(payload, const ['trip_number', 'tripNumber']);
    setState(() => _dockingInTripNo = tripNo);

    if (tripId == null) {
      if (!mounted) return;
      DplSnacks.error(
        context,
        'QR is missing a trip id. Reprint the sheet and try again.',
      );
      await _restartScanner();
      return;
    }

    final res =
        await ref.read(dplApiServiceProvider).tataDockInTrip(tripId, qrToken: code);
    if (!mounted) return;

    if (res.isError) {
      // 409 INVALID_STATUS means the trip hasn't reached tata_gate_in
      // yet — the driver still owes a barcode entry at the plant gate.
      if (res.code == 'INVALID_STATUS' || res.statusCode == 409) {
        DplSnacks.warning(
          context,
          "This trip isn't at Tata Gate-In yet. Ask the driver to complete "
          'the gate-in step first.',
        );
      } else {
        DplSnacks.error(
          context,
          res.error ?? 'Failed to record Tata Dock-In.',
        );
      }
      await _restartScanner();
      return;
    }

    // Dock-in recorded — push the Dock Out form. When the user completes
    // it (or backs out), we come back here and resume the camera so the
    // next truck can be received.
    if (tripNo != null) {
      DplSnacks.success(context, 'Trip #$tripNo docked in.');
    } else {
      DplSnacks.success(context, 'Dock-in recorded.');
    }

    // Session-scope: record dock-in on the QRE home dashboard.
    ref.read(qreRecentProvider.notifier).add(JourneyActivity(
          tripId: tripId,
          tripNumber: tripNo,
          event: 'tata_dock_in',
          at: DateTime.now(),
        ));

    final completed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _QreDockOutFormScreen(
          tripId: tripId,
          tripNumber: tripNo,
        ),
      ),
    );

    if (!mounted) return;
    if (completed == true) {
      DplSnacks.success(
        context,
        tripNo != null
            ? 'Trip #$tripNo: Dock-Out recorded'
            : 'Dock-Out recorded.',
      );
      // Session-scope: also record the dock-out on the home dashboard.
      ref.read(qreRecentProvider.notifier).add(JourneyActivity(
            tripId: tripId,
            tripNumber: tripNo,
            event: 'tata_dock_out',
            at: DateTime.now(),
          ));
    }
    await _restartScanner();
  }

  Future<void> _restartScanner() async {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pendingToken = null;
      _dockingInTripNo = null;
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
        title: 'QRE · TATA · Scan Trip QR',
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
              child: _HintPill(
                text: 'Scan the trip sheet QR to receive the truck.',
              ),
            ),
          ),
          if (_busy) _BusyOverlay(tripNo: _dockingInTripNo),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Dock-Out form
// -----------------------------------------------------------------------------

class _QreDockOutFormScreen extends ConsumerStatefulWidget {
  final int tripId;
  final int? tripNumber;
  const _QreDockOutFormScreen({
    required this.tripId,
    this.tripNumber,
  });

  @override
  ConsumerState<_QreDockOutFormScreen> createState() =>
      _QreDockOutFormScreenState();
}

class _QreDockOutFormScreenState extends ConsumerState<_QreDockOutFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _countCtrl = TextEditingController();
  final TextEditingController _remarksCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _countCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final count = int.parse(_countCtrl.text.trim());
    setState(() => _submitting = true);
    final res = await ref.read(dplApiServiceProvider).tataDockOutTrip(
          widget.tripId,
          emptyTrolleyCount: count,
          remarks: _remarksCtrl.text.trim().isEmpty
              ? null
              : _remarksCtrl.text.trim(),
        );
    if (!mounted) return;
    if (res.isError) {
      setState(() => _submitting = false);
      DplSnacks.error(context, res.error ?? 'Failed to record Dock-Out.');
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final tripLabel = widget.tripNumber != null
        ? 'Trip #${widget.tripNumber}'
        : 'Trip ${widget.tripId}';
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(title: 'Dock Out · $tripLabel'),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  decoration: BoxDecoration(
                    color: DplColors.successBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: DplColors.success),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        color: DplColors.success,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '$tripLabel is docked in. Complete the empty '
                          'trolley count to close the dock leg.',
                          style: DplText.bodySm().copyWith(
                            color: DplColors.success,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Text('Empty trolley count', style: DplText.h3()),
                const SizedBox(height: 6),
                Text(
                  'How many empty trolleys are being returned with this truck?',
                  style: DplText.bodySm().copyWith(
                    color: DplColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _countCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4),
                  ],
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Count',
                    hintText: '0 – 9999',
                    prefixIcon: Icon(Icons.inventory_2_outlined),
                    border: OutlineInputBorder(),
                  ),
                  validator: (raw) {
                    final v = (raw ?? '').trim();
                    if (v.isEmpty) return 'Enter a count.';
                    final parsed = int.tryParse(v);
                    if (parsed == null) return 'Digits only.';
                    if (parsed < 0 || parsed > 9999) {
                      return 'Must be between 0 and 9999.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 18),
                Text('Remarks (optional)', style: DplText.h3()),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _remarksCtrl,
                  minLines: 3,
                  maxLines: 5,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    hintText: 'Any note for the dispatch team…',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _submitting
                            ? null
                            : () => Navigator.of(context).pop(false),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: _submitting ? null : _submit,
                        style: FilledButton.styleFrom(
                          backgroundColor: DplColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: _submitting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.local_shipping_rounded),
                        label: Text(
                          _submitting ? 'Recording…' : 'Confirm Dock Out',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Overlays / viewfinder — kept in-file so the screen is self-contained.
// -----------------------------------------------------------------------------

class _BusyOverlay extends StatelessWidget {
  final int? tripNo;
  const _BusyOverlay({this.tripNo});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.65),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 14),
            Text(
              tripNo != null
                  ? 'Docking in Trip #$tripNo…'
                  : 'Recording dock-in…',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScannerFrameOverlay extends StatelessWidget {
  const _ScannerFrameOverlay();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _ScannerFramePainter());
  }
}

class _ScannerFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final shorter = size.shortestSide;
    final box = shorter * 0.72;
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: box,
      height: box,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(22));

    final scrim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(rrect);
    canvas.drawPath(
      scrim,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    canvas.drawRRect(
      rrect,
      Paint()
        ..color = DplColors.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    final corner = Paint()
      ..color = DplColors.primaryLight
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 5;
    const tick = 22.0;
    final r = rrect.outerRect;
    canvas
      ..drawLine(r.topLeft + const Offset(8, 8),
          r.topLeft + const Offset(8 + tick, 8), corner)
      ..drawLine(r.topLeft + const Offset(8, 8),
          r.topLeft + const Offset(8, 8 + tick), corner)
      ..drawLine(r.topRight + const Offset(-8, 8),
          r.topRight + const Offset(-8 - tick, 8), corner)
      ..drawLine(r.topRight + const Offset(-8, 8),
          r.topRight + const Offset(-8, 8 + tick), corner)
      ..drawLine(r.bottomLeft + const Offset(8, -8),
          r.bottomLeft + const Offset(8 + tick, -8), corner)
      ..drawLine(r.bottomLeft + const Offset(8, -8),
          r.bottomLeft + const Offset(8, -8 - tick), corner)
      ..drawLine(r.bottomRight + const Offset(-8, -8),
          r.bottomRight + const Offset(-8 - tick, -8), corner)
      ..drawLine(r.bottomRight + const Offset(-8, -8),
          r.bottomRight + const Offset(-8, -8 - tick), corner);
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
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.qr_code_scanner_rounded,
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
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// JWT payload helpers — local decode only (backend re-verifies signature).
// -----------------------------------------------------------------------------

Map<String, dynamic> _decodeJwtPayload(String token) {
  try {
    final parts = token.split('.');
    if (parts.length < 2) return const {};
    final seg = parts[1];
    final padded = seg.padRight(seg.length + (4 - seg.length % 4) % 4, '=');
    final bytes = base64Url.decode(padded);
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return const {};
  } catch (_) {
    return const {};
  }
}

int? _readInt(Map<String, dynamic> src, List<String> keys) {
  for (final k in keys) {
    final v = src[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) {
      final parsed = int.tryParse(v.trim());
      if (parsed != null) return parsed;
    }
    if (v is Map && v['id'] != null) {
      final inner = v['id'];
      if (inner is int) return inner;
      if (inner is num) return inner.toInt();
      if (inner is String) {
        final parsed = int.tryParse(inner.trim());
        if (parsed != null) return parsed;
      }
    }
  }
  return null;
}
