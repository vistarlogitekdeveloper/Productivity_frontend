import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../journey/widgets/scanner_error_view.dart';
import '../../manager/widgets/error_retry.dart';
import '../../models/dpl_dispatch_slip.dart';

/// In-app verifier for a printed dispatch slip's QR code.
///
/// Flow:
///   1. Camera opens with a square scan window over a viewfinder.
///   2. When a QR is detected, the token is sent to the backend's
///      public `/dispatch/slips/verify` endpoint.
///   3. The response is rendered in human-readable form (names, not
///      IDs) along with a "Verified" stamp + part details.
///
/// This is the day-to-day verifier for gate staff, QA, PDI, Dispatch,
/// and Manager — they all have the app. Random outside scanners (a
/// truck driver's phone, etc.) need the backend to embed names in the
/// signed JWT payload itself; that's a separate ask.
class DispatchSlipVerifierScreen extends ConsumerStatefulWidget {
  const DispatchSlipVerifierScreen({super.key});

  @override
  ConsumerState<DispatchSlipVerifierScreen> createState() =>
      _DispatchSlipVerifierScreenState();
}

class _DispatchSlipVerifierScreenState
    extends ConsumerState<DispatchSlipVerifierScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  bool _busy = false;
  String? _lastToken;
  DplDispatchSlipVerification? _result;
  String? _serverError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    // Guard against the same code firing multiple times while we wait
    // for the network round-trip.
    if (_busy) return;
    final code = capture.barcodes
        .map((b) => b.rawValue?.trim() ?? '')
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (code.isEmpty) return;
    if (code == _lastToken && _result != null) return;

    setState(() {
      _busy = true;
      _lastToken = code;
      _serverError = null;
    });

    // Pause the camera while the request is in flight so we don't keep
    // flooding /verify with the same payload as the user holds the QR
    // steady.
    await _controller.stop();
    final res =
        await ref.read(dplApiServiceProvider).verifyDispatchSlip(code);

    if (!mounted) return;

    if (res.isError) {
      setState(() {
        _busy = false;
        _serverError = res.error ?? 'Verification failed.';
      });
      return;
    }

    setState(() {
      _busy = false;
      _result = res.data;
    });
  }

  Future<void> _rescan() async {
    setState(() {
      _result = null;
      _serverError = null;
      _lastToken = null;
      _busy = false;
    });
    try {
      await _controller.start();
    } catch (_) {
      // start() can throw if the camera is already running — safe to
      // ignore; the user will just see the live preview again.
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_busy) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 14),
            Text(
              'Verifying slip…',
              style: TextStyle(
                color: DplColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    } else if (_serverError != null) {
      body = DplErrorRetry(
        message: _serverError!,
        onRetry: _rescan,
      );
    } else if (_result != null) {
      body = _VerifiedResultView(
        result: _result!,
        scannedToken: _lastToken,
        onRescan: _rescan,
      );
    } else {
      body = _ScannerView(controller: _controller, onDetect: _onDetect);
    }

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Verify Dispatch Slip',
        actions: [
          if (_result == null && _serverError == null && !_busy)
            IconButton(
              tooltip: 'Toggle torch',
              icon: const Icon(Icons.flash_on_outlined),
              onPressed: _controller.toggleTorch,
            ),
          if (_result != null || _serverError != null)
            IconButton(
              tooltip: 'Scan another',
              icon: const Icon(Icons.qr_code_scanner_rounded),
              onPressed: _rescan,
            ),
        ],
      ),
      body: body,
    );
  }
}

class _ScannerView extends StatelessWidget {
  final MobileScannerController controller;
  final void Function(BarcodeCapture) onDetect;

  const _ScannerView({required this.controller, required this.onDetect});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: controller,
          onDetect: onDetect,
          errorBuilder: (_, err, _) =>
              ScannerErrorView(error: err, onRetry: controller.start),
        ),
        // Soft scrim + framed scan window so the user knows where to
        // hold the QR.
        IgnorePointer(
          child: CustomPaint(painter: _ScannerOverlayPainter()),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 32,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.qr_code_scanner_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Hold the slip steady inside the frame.',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Draws a soft dimmer everywhere except the centred square scan window,
/// with a bright purple border so the user knows where to aim. Pure
/// painter so it doesn't burn a build cycle per frame.
class _ScannerOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final shorter = size.shortestSide;
    final box = shorter * 0.68;
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: box,
      height: box,
    );
    final rrect =
        RRect.fromRectAndRadius(rect, const Radius.circular(20));

    final scrimPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(rrect);

    canvas.drawPath(
      scrimPath,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    // Bright purple frame.
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = DplColors.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    // Four corner ticks so the frame reads as "scanner viewfinder".
    final corner = Paint()
      ..color = DplColors.primaryLight
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 5;
    const tickLen = 22.0;
    final r = rrect.outerRect;
    canvas
      ..drawLine(r.topLeft + const Offset(8, 8),
          r.topLeft + const Offset(8 + tickLen, 8), corner)
      ..drawLine(r.topLeft + const Offset(8, 8),
          r.topLeft + const Offset(8, 8 + tickLen), corner)
      ..drawLine(r.topRight + const Offset(-8, 8),
          r.topRight + const Offset(-8 - tickLen, 8), corner)
      ..drawLine(r.topRight + const Offset(-8, 8),
          r.topRight + const Offset(-8, 8 + tickLen), corner)
      ..drawLine(r.bottomLeft + const Offset(8, -8),
          r.bottomLeft + const Offset(8 + tickLen, -8), corner)
      ..drawLine(r.bottomLeft + const Offset(8, -8),
          r.bottomLeft + const Offset(8, -8 - tickLen), corner)
      ..drawLine(r.bottomRight + const Offset(-8, -8),
          r.bottomRight + const Offset(-8 - tickLen, -8), corner)
      ..drawLine(r.bottomRight + const Offset(-8, -8),
          r.bottomRight + const Offset(-8, -8 - tickLen), corner);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Verified slip view — the "what does this slip really say" panel that
/// shows after a successful verify call. Renders every field in
/// human-readable form (machine NAME, part NAME, QA NAME, PDI NAME),
/// plus the full part details (substrate P/N, material code,
/// description) the user asked for. Top-of-screen "Verified" stamp
/// reflects the backend's signature check.
class _VerifiedResultView extends StatelessWidget {
  final DplDispatchSlipVerification result;
  final String? scannedToken;
  final VoidCallback onRescan;

  const _VerifiedResultView({
    required this.result,
    required this.scannedToken,
    required this.onRescan,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final dateFmt = DateFormat('dd MMM yyyy, HH:mm');
    final slip = result.slip;
    final verified = result.verified && slip != null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        _VerifiedBadge(verified: verified, slipNo: slip?.slipNo),
        const SizedBox(height: 14),
        if (slip == null)
          DplErrorRetry(
            message: 'The scanned code did not match a known slip. '
                'It may have been tampered with or the slip was deleted.',
            onRetry: onRescan,
          )
        else ...[
          _SectionCard(
            title: 'Slip',
            children: [
              _Kv(label: 'Slip number', value: slip.slipNo),
              _Kv(
                label: 'Status',
                value: _statusLabel(slip.status),
                valueColor: _statusColor(slip.status),
              ),
              if (slip.plant.name.isNotEmpty)
                _Kv(label: 'Plant', value: slip.plant.name),
              if (slip.vehicleNo.isNotEmpty)
                _Kv(label: 'Vehicle no', value: slip.vehicleNo),
              if (slip.isSingleItem)
                _Kv(label: 'Quantity', value: '${fmt.format(slip.qty)} NOS')
              else ...[
                _Kv(label: 'Items', value: '${slip.items.length}'),
                _Kv(
                  label: 'Total qty',
                  value: '${fmt.format(slip.totalQty)} NOS',
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          if (slip.isSingleItem) ...[
            _SectionCard(
              title: 'Machine',
              children: [
                _Kv(
                  label: 'Name',
                  value:
                      slip.machineName.isEmpty ? '-' : slip.machineName,
                ),
                if (slip.machineCode.isNotEmpty)
                  _Kv(label: 'Code', value: slip.machineCode),
              ],
            ),
            const SizedBox(height: 12),
            _SectionCard(
              title: 'Part details',
              children: [
                _Kv(
                  label: 'Name',
                  value: slip.partName.isEmpty ? '-' : slip.partName,
                ),
                if (slip.customerPartNo.isNotEmpty)
                  _Kv(label: 'Customer P/N', value: slip.customerPartNo),
                if (slip.substratePartNo.isNotEmpty)
                  _Kv(
                    label: 'Substrate P/N',
                    value: slip.substratePartNo,
                  ),
                if (slip.materialCode.isNotEmpty)
                  _Kv(label: 'Material code', value: slip.materialCode),
                if (slip.description.isNotEmpty &&
                    slip.description != slip.partName)
                  _Kv(label: 'Description', value: slip.description),
              ],
            ),
          ] else
            _ItemsCard(slip: slip, fmt: fmt),
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Approval',
            children: [
              if (slip.requestedBy != null)
                _Kv(
                  label: 'Requested by',
                  value: slip.requestedBy!.name.isEmpty
                      ? '-'
                      : slip.requestedBy!.name,
                  sub: slip.requestedAt == null
                      ? null
                      : dateFmt.format(slip.requestedAt!.toLocal()),
                ),
              if (slip.qaApproval != null)
                _Kv(
                  label: 'QA approved by',
                  value: slip.qaApproval!.name.isEmpty
                      ? '-'
                      : slip.qaApproval!.name,
                  sub: slip.qaApproval!.at == null
                      ? null
                      : dateFmt.format(slip.qaApproval!.at!.toLocal()),
                  valueColor: DplColors.success,
                ),
              if (slip.pdiApproval != null)
                _Kv(
                  label: 'PDI approved by',
                  value: slip.pdiApproval!.name.isEmpty
                      ? '-'
                      : slip.pdiApproval!.name,
                  sub: slip.pdiApproval!.at == null
                      ? null
                      : dateFmt.format(slip.pdiApproval!.at!.toLocal()),
                  valueColor: DplColors.success,
                ),
              if (slip.dispatchedAt != null)
                _Kv(
                  label: 'Dispatched by',
                  value: slip.dispatchedBy?.name.isEmpty ?? true
                      ? '-'
                      : slip.dispatchedBy!.name,
                  sub: dateFmt.format(slip.dispatchedAt!.toLocal()),
                  valueColor: DplColors.primaryDark,
                ),
              if (slip.rejection != null)
                _Kv(
                  label: '${slip.rejection!.role.toUpperCase()} rejected by',
                  value: slip.rejection!.name.isEmpty
                      ? '-'
                      : slip.rejection!.name,
                  sub: slip.rejection!.at == null
                      ? slip.rejection!.reason
                      : '${dateFmt.format(slip.rejection!.at!.toLocal())}'
                          ' — "${slip.rejection!.reason}"',
                  valueColor: DplColors.error,
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (result.signedPayload != null)
            _SignedPayloadCard(payload: result.signedPayload!),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRescan,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('Scan another slip'),
          ),
        ],
      ],
    );
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'pending_qa':
        return 'Pending QA';
      case 'pending_pdi':
        return 'Pending PDI';
      case 'approved':
        return 'Approved';
      case 'dispatched':
        return 'Dispatched';
      case 'rejected':
        return 'Rejected';
      default:
        return s;
    }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'pending_qa':
      case 'pending_pdi':
        return DplColors.warning;
      case 'approved':
        return DplColors.info;
      case 'dispatched':
        return DplColors.success;
      case 'rejected':
        return DplColors.error;
      default:
        return DplColors.textPrimary;
    }
  }
}

class _VerifiedBadge extends StatelessWidget {
  final bool verified;
  final String? slipNo;
  const _VerifiedBadge({required this.verified, this.slipNo});

  @override
  Widget build(BuildContext context) {
    final fg = verified ? DplColors.success : DplColors.error;
    final bg = verified ? DplColors.successBg : DplColors.errorBg;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: fg),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fg,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Icon(
              verified ? Icons.verified_rounded : Icons.gpp_bad_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  verified
                      ? 'Verified by Vistar Pulse'
                      : 'Verification failed',
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                Text(
                  verified
                      ? '${slipNo ?? "Slip"} signature is valid.'
                      : 'Tampered or unknown slip.',
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SectionCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w800,
              fontSize: 10.5,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }
}

class _Kv extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final Color? valueColor;
  const _Kv({
    required this.label,
    required this.value,
    this.sub,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: DplColors.textSecondary,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    color: valueColor ?? DplColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
                if (sub != null && sub!.trim().isNotEmpty)
                  Text(
                    sub!,
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
    );
  }
}

/// Renders the full items list for a multi-item dispatch slip. Each row
/// shows the machine/part name, optional customer P/N + description, and
/// the per-item qty. A footer row totals the qty so the verifier can
/// reconcile against the printed slip at a glance.
class _ItemsCard extends StatelessWidget {
  final DplDispatchSlip slip;
  final NumberFormat fmt;
  const _ItemsCard({required this.slip, required this.fmt});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'ITEMS (${slip.items.length})',
            style: TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w800,
              fontSize: 10.5,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < slip.items.length; i++) ...[
            if (i > 0)
              Divider(height: 14, color: DplColors.divider),
            _ItemRow(item: slip.items[i], fmt: fmt, index: i + 1),
          ],
          const SizedBox(height: 8),
          Divider(height: 1, color: DplColors.divider),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Total qty',
                style: TextStyle(
                  color: DplColors.textSecondary,
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                ),
              ),
              Text(
                '${fmt.format(slip.totalQty)} NOS',
                style: TextStyle(
                  color: DplColors.textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 13.5,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  final DplDispatchSlipItem item;
  final NumberFormat fmt;
  final int index;
  const _ItemRow({
    required this.item,
    required this.fmt,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 22,
          child: Text(
            '$index.',
            style: TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.machineName.isEmpty ? '-' : item.machineName,
                style: TextStyle(
                  color: DplColors.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 11.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                item.partName.isEmpty ? '-' : item.partName,
                style: TextStyle(
                  color: DplColors.textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
              if (item.customerPartNo.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Customer P/N: ${item.customerPartNo}',
                    style: TextStyle(
                      color: DplColors.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 11.5,
                    ),
                  ),
                ),
              if (item.description.isNotEmpty &&
                  item.description != item.partName)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    item.description,
                    style: TextStyle(
                      color: DplColors.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 11.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${fmt.format(item.qty)} NOS',
          style: TextStyle(
            color: DplColors.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}

/// Diagnostic card showing exactly what the signed JWT payload carried.
///
/// As of the 2026-06-11 backend update the payload is **nested** — each
/// top-level entity (`organization`, `machine`, `part`, `qa`, `pdi`)
/// arrives as a `Map` carrying both the id AND human-readable fields.
/// We flatten those into labelled sub-sections so the panel reads as a
/// proper transparency dump rather than a wall of `{id: 1, name: …}`
/// strings.
///
/// Known timestamp fields (`iat`, `approved_at`, anything ending in
/// `_at`) get formatted as `dd MMM yyyy, HH:mm` — `iat` keeps the raw
/// seconds in parens so backend debugging is still possible.
class _SignedPayloadCard extends StatelessWidget {
  final Map<String, dynamic> payload;
  const _SignedPayloadCard({required this.payload});

  @override
  Widget build(BuildContext context) {
    final scalars = <MapEntry<String, dynamic>>[];
    final nested = <MapEntry<String, Map<String, dynamic>>>[];
    for (final e in payload.entries) {
      if (e.value is Map) {
        nested.add(MapEntry(e.key, Map<String, dynamic>.from(e.value as Map)));
      } else {
        scalars.add(e);
      }
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: DplColors.pageBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.qr_code_2_rounded,
                size: 16,
                color: DplColors.textSecondary,
              ),
              SizedBox(width: 6),
              Text(
                'WHAT THE QR ENCODED',
                style: TextStyle(
                  color: DplColors.textSecondary,
                  fontWeight: FontWeight.w800,
                  fontSize: 10.5,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Top-level scalars (slip_no, qty, approved_at, iat).
          for (final e in scalars)
            _Kv(label: e.key, value: _formatValue(e.key, e.value)),
          // Nested entities (organization, machine, part, qa, pdi).
          for (final group in nested) ...[
            const SizedBox(height: 8),
            _NestedGroup(name: group.key, entries: group.value),
          ],
        ],
      ),
    );
  }

  /// Pretty-prints known time fields. Anything else falls back to
  /// `.toString()` so the panel never crashes on a payload shape it
  /// hasn't seen before.
  static String _formatValue(String key, dynamic value) {
    final fmt = DateFormat('dd MMM yyyy, HH:mm');
    if (value == null) return '-';

    // ISO-8601 strings — typically `approved_at` and similar `*_at`
    // fields. Detect by trying to parse and falling back to the raw
    // string if it isn't a date.
    if (value is String && (key == 'approved_at' || key.endsWith('_at'))) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return fmt.format(parsed.toLocal());
      return value;
    }

    // Unix seconds — `iat` is the canonical JWT issued-at claim.
    // Show as a readable date AND keep the raw seconds in parens so
    // anyone debugging against backend logs can cross-reference.
    if (key == 'iat' && value is num) {
      final dt =
          DateTime.fromMillisecondsSinceEpoch((value * 1000).round());
      return '${fmt.format(dt.toLocal())} ($value)';
    }

    return value.toString();
  }
}

/// One nested entity from the payload — e.g. `organization`, `machine`,
/// `part`, `qa`, `pdi`. Rendered as a small uppercase sub-header
/// followed by the entity's own key/value rows, indented under it so
/// the visual hierarchy reads as "this group belongs together".
class _NestedGroup extends StatelessWidget {
  final String name;
  final Map<String, dynamic> entries;
  const _NestedGroup({required this.name, required this.entries});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DplColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            name.toUpperCase(),
            style: TextStyle(
              color: DplColors.primaryDark,
              fontWeight: FontWeight.w800,
              fontSize: 10.5,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 4),
          for (final e in entries.entries)
            _Kv(
              label: e.key,
              value: _SignedPayloadCard._formatValue(e.key, e.value),
            ),
        ],
      ),
    );
  }
}
