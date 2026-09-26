import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_snack.dart';
import '../providers/journey_session_state.dart';
import '../widgets/scanner_error_view.dart';

/// Security's home screen — full-screen scanner + confirm sheet.
///
/// The consolidated-slip QR on the printed trip sheet carries a signed
/// JWT-style token whose payload has (at minimum) `trip_id`,
/// `trip_number`, `plant`/`plant_code`, and `vehicle_no`. We decode the
/// **middle** segment locally so we can show the guard what they're
/// about to release — we DO NOT verify the signature client-side; the
/// backend re-checks it when the POST hits `/gate-out`.
///
/// Flow:
///   1. Camera opens full-screen.
///   2. On a QR detect we decode the payload, pause the camera, and
///      slide a bottom sheet up with the trip info + a big "Confirm
///      Gate Out" button.
///   3. On confirm we POST `/dispatch/trips/:trip_id/gate-out` with the
///      original `qr_token`; on 200 we snack and immediately restart the
///      scanner so the next truck can be waved through without leaving
///      the screen. On 409 `ALREADY_RECORDED` we surface a friendly
///      one-liner explaining the trip was already released.
///
/// A "Today" strip at the bottom lists this session's gate-outs so the
/// guard has visual confirmation of what they've released this shift.
/// A full server-backed "last 10" is deferred to v2 — no endpoint scoped
/// to `actor_user_id` exists yet on the backend.
class SecurityScannerScreen extends ConsumerStatefulWidget {
  const SecurityScannerScreen({super.key});

  @override
  ConsumerState<SecurityScannerScreen> createState() =>
      _SecurityScannerScreenState();
}

class _SecurityScannerScreenState extends ConsumerState<SecurityScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  /// Set once a QR is captured, cleared once we've either recorded the
  /// gate-out or the guard cancelled out of the sheet. Guards against
  /// the same code firing repeatedly while the sheet is open.
  String? _pendingToken;

  /// In-session log of successful gate-outs. Newest first, capped at 10.
  /// Persisted only in memory — see class docstring for the v2 plan.
  final List<_RecentGateOut> _recent = [];

  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_pendingToken != null || _busy) return;
    final code = capture.barcodes
        .map((b) => b.rawValue?.trim() ?? '')
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (code.isEmpty) return;

    setState(() => _pendingToken = code);
    await _controller.stop();

    // Local-only decode. The backend re-verifies the signature.
    final payload = _decodeJwtPayload(code);

    if (!mounted) return;
    _openConfirmSheet(token: code, payload: payload);
  }

  Future<void> _openConfirmSheet({
    required String token,
    required Map<String, dynamic> payload,
  }) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: !_busy,
      enableDrag: !_busy,
      builder: (ctx) => _ConfirmGateOutSheet(
        payload: payload,
        tripId: _readInt(payload, const ['trip_id', 'tripId', 'id']),
        onConfirm: () async {
          final ok = await _submitGateOut(token: token, payload: payload);
          if (ctx.mounted) Navigator.of(ctx).pop(ok);
        },
      ),
    );

    // Whether the guard confirmed, cancelled, or the sheet was
    // dismissed — always resume the camera so the next scan works.
    if (!mounted) return;
    setState(() {
      _pendingToken = null;
      _busy = false;
    });
    try {
      await _controller.start();
    } catch (_) {
      // start() throws if the camera is already running — safe to ignore.
    }
    // `result` intentionally unused beyond the pop signal; the snack was
    // fired inside `_submitGateOut` where we still had context to name
    // the trip number.
    result;
  }

  Future<bool> _submitGateOut({
    required String token,
    required Map<String, dynamic> payload,
  }) async {
    final tripId = _readInt(payload, const [
      'trip_id',
      'tripId',
      'id',
    ]);
    if (tripId == null) {
      DplSnacks.error(
        context,
        'QR is missing a trip id. Reprint the sheet and try again.',
      );
      return false;
    }

    setState(() => _busy = true);

    // Smart-select outbound vs return based on the trip's journey. A
    // trip that has already recorded 'tata_gate_out' is on its way
    // back — this scan closes the loop (gate_in). Otherwise it's the
    // first scan (gate_out). One round trip up front is cheaper than
    // an optimistic gate-out-then-fallback dance and lets us render
    // the correct snack copy.
    final api = ref.read(dplApiServiceProvider);
    final journeyRes = await api.listTripJourney(tripId);
    if (!mounted) return false;
    if (journeyRes.isError) {
      DplSnacks.error(
        context,
        journeyRes.error ?? 'Could not read trip journey.',
      );
      setState(() => _busy = false);
      return false;
    }
    final events = journeyRes.data ?? const [];
    final eventNames = events.map((e) => e.event).toSet();
    final isReturn = eventNames.contains('tata_gate_out') &&
        !eventNames.contains('gate_in');
    final alreadyClosed = eventNames.contains('gate_in');
    final alreadyOutbound = eventNames.contains('gate_out') && !isReturn;

    if (alreadyClosed) {
      DplSnacks.warning(
        context,
        'This trip is already fully closed (Gate In recorded).',
      );
      setState(() => _busy = false);
      return false;
    }
    if (alreadyOutbound && !isReturn) {
      DplSnacks.warning(
        context,
        'This trip has already left the plant. Waiting for TATA Gate Out before return scan.',
      );
      setState(() => _busy = false);
      return false;
    }

    final res = isReturn
        ? await api.gateInTrip(tripId, qrToken: token)
        : await api.gateOutTrip(tripId, qrToken: token);
    if (!mounted) return false;

    if (res.isError) {
      // Only ALREADY_RECORDED means "you already did this scan" — treat
      // as a warning. Any OTHER 409 (QR_MISMATCH, INVALID_STATUS,
      // VEHICLE_MISMATCH, TOKEN_STALE …) is a real error and needs
      // the raw BE message so ops can act on it.
      if (res.code == 'ALREADY_RECORDED') {
        DplSnacks.warning(
          context,
          isReturn
              ? 'This trip is already marked as returned.'
              : 'This trip is already marked as Gate Out.',
        );
      } else {
        DplSnacks.error(
          context,
          res.error ??
              (isReturn ? 'Failed to record return scan.' : 'Failed to record Gate Out.'),
        );
      }
      setState(() => _busy = false);
      return false;
    }

    final tripNo = _readInt(payload, const ['trip_number', 'tripNumber']);
    final plant = _readString(payload, const [
      'plant',
      'plant_code',
      'plantCode',
      'plant_name',
      'plantName',
    ]);
    final vehicle = _readString(payload, const [
      'vehicle_no',
      'vehicleNo',
      'vehicle',
    ]);

    DplSnacks.success(
      context,
      tripNo != null
          ? (isReturn
              ? 'Trip #$tripNo: Return scan recorded · trip complete'
              : 'Trip #$tripNo: Gate Out recorded')
          : (isReturn ? 'Return scan recorded · trip complete' : 'Gate Out recorded.'),
    );

    final now = DateTime.now();
    setState(() {
      _recent.insert(
        0,
        _RecentGateOut(
          tripId: tripId,
          tripNumber: tripNo,
          plant: plant,
          vehicleNo: vehicle,
          at: now,
        ),
      );
      if (_recent.length > 10) {
        _recent.removeRange(10, _recent.length);
      }
      _busy = false;
    });
    // Session-scope: also push to the shared home-dashboard provider
    // so the Security home screen can render the running counter +
    // recent-activity list when the guard returns to it. Event name
    // matches which transition just fired.
    ref.read(securityRecentProvider.notifier).add(JourneyActivity(
          tripId: tripId,
          tripNumber: tripNo,
          plant: plant,
          vehicleNo: vehicle,
          event: isReturn ? 'gate_in' : 'gate_out',
          at: now,
        ));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: DplAppBar(
        title: 'Security · Scan Trip QR',
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
          const IgnorePointer(
            child: _ScannerFrameOverlay(),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 12,
            child: Center(
              child: _HintPill(
                text: 'Point the camera at the trip sheet QR.',
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _RecentGateOutsStrip(recent: _recent),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Confirm bottom sheet
// -----------------------------------------------------------------------------

class _ConfirmGateOutSheet extends ConsumerStatefulWidget {
  final Map<String, dynamic> payload;
  final int? tripId;
  final Future<void> Function() onConfirm;

  const _ConfirmGateOutSheet({
    required this.payload,
    required this.tripId,
    required this.onConfirm,
  });

  @override
  ConsumerState<_ConfirmGateOutSheet> createState() =>
      _ConfirmGateOutSheetState();
}

class _ConfirmGateOutSheetState extends ConsumerState<_ConfirmGateOutSheet> {
  bool _submitting = false;

  /// null = still fetching the trip's journey; true = "this scan is
  /// the RETURN (gate_in)"; false = outbound (gate_out).
  bool? _isReturn;
  /// true once tata_gate_out AND gate_in are both on record — the sheet
  /// still opens (guard already scanned before we could stop them) but
  /// disables the confirm button and shows a "trip already closed" hint.
  bool _alreadyClosed = false;
  String? _stageFetchError;

  @override
  void initState() {
    super.initState();
    _resolveStage();
  }

  Future<void> _resolveStage() async {
    final tid = widget.tripId;
    if (tid == null) return; // sheet already shows the "old sheet" warning
    final res = await ref.read(dplApiServiceProvider).listTripJourney(tid);
    if (!mounted) return;
    if (res.isError) {
      setState(() {
        _stageFetchError = res.error ?? 'Could not read trip stage';
        _isReturn = false; // default to outbound copy; parent's submit
                           // re-fetches so worst case the user sees a
                           // "gate out" label and gets the right action
      });
      return;
    }
    final events = res.data ?? const [];
    final names = events.map((e) => e.event).toSet();
    setState(() {
      _alreadyClosed = names.contains('gate_in');
      _isReturn =
          names.contains('tata_gate_out') && !names.contains('gate_in');
    });
  }

  @override
  Widget build(BuildContext context) {
    final tripNo = _readInt(widget.payload, const [
      'trip_number',
      'tripNumber',
    ]);
    final plant = _readString(widget.payload, const [
      'plant',
      'plant_code',
      'plantCode',
      'plant_name',
      'plantName',
    ]);
    final vehicle = _readString(widget.payload, const [
      'vehicle_no',
      'vehicleNo',
      'vehicle',
    ]);
    final missing = tripNo == null;
    final loading = _isReturn == null && !missing && _stageFetchError == null;
    final isReturn = _isReturn == true;
    final subtitle = missing
        ? 'Confirm to record Gate Out.'
        : loading
            ? 'Checking trip stage…'
            : _alreadyClosed
                ? 'This trip is already fully closed.'
                : isReturn
                    ? 'Confirm to record RETURN scan (Origin Gate In).'
                    : 'Confirm to record Gate Out.';
    final buttonLabel = _submitting
        ? 'Recording…'
        : loading
            ? 'Checking…'
            : isReturn
                ? 'Confirm Gate In (Return)'
                : 'Confirm Gate Out';
    final canSubmit =
        !_submitting && !missing && !loading && !_alreadyClosed;

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: DplColors.cardBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: DplShadows.sheet,
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 42,
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
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: DplColors.primaryTint,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.local_shipping_rounded,
                    color: DplColors.primaryDark,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tripNo != null ? 'Trip #$tripNo' : 'Trip QR',
                        style: DplText.h3(),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: DplText.bodySm().copyWith(
                          color: DplColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _KvRow(label: 'Trip number', value: tripNo?.toString() ?? '—'),
            _KvRow(label: 'Plant', value: plant?.isEmpty ?? true ? '—' : plant!),
            _KvRow(
              label: 'Vehicle',
              value: vehicle?.isEmpty ?? true ? '—' : vehicle!,
            ),
            if (missing) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: DplColors.warningBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: DplColors.warning),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: DplColors.warning,
                      size: 18,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "This QR doesn't carry a trip id. It may be an "
                        'old sheet — reprint and try again.',
                        style: TextStyle(
                          color: DplColors.warning,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
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
                    onPressed: !canSubmit
                        ? null
                        : () async {
                            setState(() => _submitting = true);
                            await widget.onConfirm();
                            // Parent pops the sheet — no local pop.
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: isReturn
                          ? DplColors.success
                          : DplColors.primary,
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
                        : Icon(
                            isReturn
                                ? Icons.flag_circle_rounded
                                : Icons.check_rounded,
                          ),
                    label: Text(buttonLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _KvRow extends StatelessWidget {
  final String label;
  final String value;
  const _KvRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                color: DplColors.textSecondary,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: DplColors.textPrimary,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Recent gate-outs strip
// -----------------------------------------------------------------------------

class _RecentGateOut {
  final int tripId;
  final int? tripNumber;
  final String? plant;
  final String? vehicleNo;
  final DateTime at;
  const _RecentGateOut({
    required this.tripId,
    required this.at,
    this.tripNumber,
    this.plant,
    this.vehicleNo,
  });
}

class _RecentGateOutsStrip extends StatelessWidget {
  final List<_RecentGateOut> recent;
  const _RecentGateOutsStrip({required this.recent});

  @override
  Widget build(BuildContext context) {
    if (recent.isEmpty) return const SizedBox.shrink();
    final fmt = DateFormat('HH:mm');
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  size: 16,
                  color: Colors.white70,
                ),
                const SizedBox(width: 6),
                Text(
                  'Last ${recent.length} gate-out${recent.length == 1 ? '' : 's'} this session',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 56,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: recent.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final r = recent[i];
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.tripNumber != null
                              ? 'Trip #${r.tripNumber}'
                              : 'Trip ${r.tripId}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            fmt.format(r.at.toLocal()),
                            if (r.vehicleNo != null && r.vehicleNo!.isNotEmpty)
                              r.vehicleNo!,
                            if (r.plant != null && r.plant!.isNotEmpty)
                              r.plant!,
                          ].join(' · '),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Viewfinder overlay + hint pill (kept in this file so the whole screen is
// self-contained — copied from the dispatch-slip verifier's pattern).
// -----------------------------------------------------------------------------

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
      ..drawLine(
          r.topLeft + const Offset(8, 8), r.topLeft + const Offset(8 + tick, 8), corner)
      ..drawLine(
          r.topLeft + const Offset(8, 8), r.topLeft + const Offset(8, 8 + tick), corner)
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
// JWT + payload helpers (local decode only, NEVER verified client-side)
// -----------------------------------------------------------------------------

/// Base64-URL decodes the middle segment of a JWT-style token. Returns
/// an empty map on any parse failure — the caller should surface a
/// friendly "unknown QR" message rather than crash.
Map<String, dynamic> _decodeJwtPayload(String token) {
  try {
    final parts = token.split('.');
    if (parts.length < 2) return const {};
    final seg = parts[1];
    // base64Url decoder requires padding to a multiple of 4.
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
    // Support nested `{ id: ... }` shapes (backend often nests entities
    // in signed payloads — see the dispatch-slip verifier for prior art).
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

String? _readString(Map<String, dynamic> src, List<String> keys) {
  for (final k in keys) {
    final v = src[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    if (v is num) return v.toString();
    if (v is Map) {
      // Prefer human-readable fields, fall back to code.
      for (final inner in const ['name', 'display_name', 'label', 'code']) {
        final iv = v[inner];
        if (iv is String && iv.trim().isNotEmpty) return iv.trim();
      }
    }
  }
  return null;
}
