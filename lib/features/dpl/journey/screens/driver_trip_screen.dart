import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_leci_scan.dart';
import '../../models/dpl_consolidated_slip.dart';
import '../../models/dpl_trip_journey_event.dart';
import '../../tracking/services/trip_location_tracker.dart';
import '../../tracking/widgets/driver_share_location_card.dart';
import '../widgets/scanner_error_view.dart';
import '../widgets/trip_journey_drawer.dart';

/// Driver's single-trip cockpit. Shows the QR (for Security / QRE to
/// scan) or the LECI-scan / TATA-Gate-Out button, depending on which
/// journey event is next.
///
/// State machine (locally derived from GET /:id/journey):
///   dispatched          → show Trip QR (Security scans → gate_out)
///   gate_out            → "Scan LECI" button (driver scans TATA paper)
///   tata_gate_in        → show Trip QR again (QRE scans → tata_dock_in)
///   tata_dock_in        → passive wait ("QRE is verifying trolleys…")
///   tata_dock_out       → "Mark TATA Gate Out" button
///   tata_gate_out       → green checkmark, "Trip complete"
///
/// Polls the journey every 15s so the driver's UI advances the moment
/// Security / QRE act on the other side.
class DriverTripScreen extends ConsumerStatefulWidget {
  final int tripId;
  const DriverTripScreen({super.key, required this.tripId});

  @override
  ConsumerState<DriverTripScreen> createState() => _DriverTripScreenState();
}

class _DriverTripScreenState extends ConsumerState<DriverTripScreen> {
  DplConsolidatedSlip? _consolidated;
  List<DplTripJourneyEvent> _events = const [];
  bool _loading = true;
  String? _error;
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() { _loading = true; _error = null; });
    try {
      final api = ref.read(dplApiServiceProvider);
      final cf = api.getConsolidatedSlip(widget.tripId);
      final jf = api.listTripJourney(widget.tripId);
      final cRes = await cf;
      final jRes = await jf;
      if (cRes.isError) throw Exception(cRes.error ?? 'Failed to load trip');
      if (jRes.isError) throw Exception(jRes.error ?? 'Failed to load journey');
      if (!mounted) return;
      setState(() {
        _consolidated = cRes.data;
        _events = jRes.data ?? const [];
        _loading = false;
      });
      _syncTracking();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  String get _currentStage {
    if (_events.isEmpty) return 'dispatched';
    return _events.map((e) => e.event).last;
  }

  /// The trip has come back through our own gate — nothing left to track.
  bool get _tripClosed => _currentStage == 'gate_in';

  /// Sharing is offered from the moment the truck leaves our plant until
  /// it is scanned back in. Before gate-out it's still parked in the
  /// yard, so there is nothing worth tracking.
  bool get _inTrackingWindow => !_tripClosed && _currentStage != 'dispatched';

  /// Keeps the tracker in step with the journey, which the driver does
  /// not drive alone — Security and the QRE move the trip forward from
  /// their own devices, and this screen learns about it on the 15s poll.
  ///
  ///   * trip closed  → stop sharing, no matter who closed it.
  ///   * mid-journey  → re-arm after an app kill / phone reboot. Only
  ///     resumes a share the driver had already switched on (the tracker
  ///     checks its own persisted trip id), never starts one unasked.
  void _syncTracking() {
    final tracker = ref.read(tripLocationTrackerProvider.notifier);
    if (_tripClosed) {
      if (ref.read(tripLocationTrackerProvider).isTracking(widget.tripId)) {
        unawaited(tracker.stop());
      }
      return;
    }
    if (_inTrackingWindow) {
      unawaited(tracker.resumeIfInterrupted(widget.tripId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final trip = _consolidated?.trip;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: trip != null ? 'Trip #${trip.tripNumber}' : 'Trip',
        actions: [
          IconButton(
            tooltip: 'View journey',
            icon: const Icon(Icons.timeline_rounded),
            onPressed: _consolidated == null
                ? null
                : () => showTripJourneyDrawer(
                      context,
                      tripId: widget.tripId,
                      tripNumber: trip?.tripNumber,
                      plantName: trip?.plantName,
                      vehicleNo: trip?.vehicleNo,
                    ),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _busy ? null : () => _load(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView(_error!)
              : _buildBody(),
    );
  }

  Widget _errorView(String msg) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  color: DplColors.error, size: 40),
              const SizedBox(height: 12),
              Text(msg, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              TextButton(onPressed: () => _load(), child: const Text('Retry')),
            ],
          ),
        ),
      );

  Widget _buildBody() {
    final stage = _currentStage;
    final trip = _consolidated?.trip;
    final qrToken = _consolidated?.qrToken ?? '';
    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _header(trip, stage),
          if (_inTrackingWindow || _tripClosed) ...[
            const SizedBox(height: 12),
            DriverShareLocationCard(
              tripId: widget.tripId,
              tripClosed: _tripClosed,
            ),
          ],
          const SizedBox(height: 16),
          _stageBody(stage, qrToken),
        ],
      ),
    );
  }

  Widget _header(trip, String stage) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
        boxShadow: DplShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  trip != null ? 'Trip #${trip.tripNumber}' : 'Trip',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _stageChip(stage),
            ],
          ),
          if (trip != null) ...[
            const SizedBox(height: 4),
            Text(
              [
                if (trip.plantName.isNotEmpty) trip.plantName,
                if ((trip.vehicleNo ?? '').isNotEmpty) trip.vehicleNo!,
              ].join(' · '),
              style: const TextStyle(color: DplColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stageChip(String stage) {
    Color c;
    String label;
    switch (stage) {
      case 'dispatched':
        c = DplColors.primary;
        label = 'Awaiting Gate Out';
        break;
      case 'gate_out':
        c = DplColors.warning;
        label = 'Enroute — Scan LECI at TATA';
        break;
      case 'tata_gate_in':
        c = DplColors.primary;
        label = 'At TATA — Scan by QRE';
        break;
      case 'tata_dock_in':
        c = DplColors.warning;
        label = 'Dock — QRE verifying';
        break;
      case 'tata_dock_out':
        c = DplColors.primary;
        label = 'Ready for Gate Out';
        break;
      case 'tata_gate_out':
        c = DplColors.warning;
        label = 'Returning · Awaiting Origin re-scan';
        break;
      case 'gate_in':
        c = DplColors.success;
        label = 'Trip Complete';
        break;
      default:
        c = DplColors.textSecondary;
        label = stage;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        border: Border.all(color: c.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: c,
        ),
      ),
    );
  }

  Widget _stageBody(String stage, String qrToken) {
    switch (stage) {
      case 'dispatched':
        return _showQrPanel(
          qrToken,
          caption: 'Show this QR to Security at the Origin gate.',
        );
      case 'gate_out':
        return _leciScanPanel();
      case 'tata_gate_in':
        return _showQrPanel(
          qrToken,
          caption: 'Show this QR to QRE at the TATA dock.',
        );
      case 'tata_dock_in':
        return _passivePanel(
          icon: Icons.hourglass_bottom_rounded,
          title: 'QRE is verifying trolleys…',
          subtitle:
              'Wait for the QRE to record Dock Out. This screen will refresh automatically.',
        );
      case 'tata_dock_out':
        return _gateOutButton();
      case 'tata_gate_out':
        // Truck has left TATA. Driver's role is done actively — they
        // just drive back. The trip closes only after Security scans
        // the QR again at the origin gate ('gate_in').
        return _showQrPanel(
          qrToken,
          caption:
              'On arrival back at the Origin plant, show this same QR to Security for the final gate scan.',
        );
      case 'gate_in':
        return _passivePanel(
          icon: Icons.check_circle_rounded,
          color: DplColors.success,
          title: 'Trip complete',
          subtitle:
              'Return recorded at the Origin gate. All journey events done.',
        );
      default:
        return _passivePanel(
          icon: Icons.info_outline_rounded,
          title: 'Stage: $stage',
          subtitle: 'No driver action needed right now.',
        );
    }
  }

  Widget _showQrPanel(String qrToken, {required String caption}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
        boxShadow: DplShadows.card,
      ),
      child: Column(
        children: [
          if (qrToken.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.white,
              child: QrImageView(
                data: qrToken,
                version: QrVersions.auto,
                size: 260,
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('QR unavailable — refresh to retry.'),
            ),
          const SizedBox(height: 12),
          Text(
            caption,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              color: DplColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _leciScanPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
        boxShadow: DplShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'You have exited the origin gate. When you arrive at TATA, collect the LECI paper and scan the barcode on it.',
            style: TextStyle(color: DplColors.textSecondary),
          ),
          const SizedBox(height: 14),
          ElevatedButton.icon(
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('Scan LECI barcode'),
            onPressed: _busy ? null : _openLeciScanner,
          ),
          const SizedBox(height: 8),
          // Fallback for a smudged / unreadable barcode: photograph the
          // LECI paper and type the truck no. The gate-in is recorded with
          // the photo instead of a scanned barcode.
          OutlinedButton.icon(
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text("Can't scan? Upload LECI photo"),
            onPressed: _busy ? null : _openLeciPhotoUpload,
          ),
        ],
      ),
    );
  }

  Widget _gateOutButton() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
        boxShadow: DplShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'QRE has completed Dock Out. Confirm your final gate exit from TATA.',
            style: TextStyle(color: DplColors.textSecondary),
          ),
          const SizedBox(height: 14),
          ElevatedButton.icon(
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Mark TATA Gate Out'),
            onPressed: _busy ? null : _markGateOut,
          ),
        ],
      ),
    );
  }

  Widget _passivePanel({
    required IconData icon,
    required String title,
    required String subtitle,
    Color? color,
  }) {
    final c = color ?? DplColors.textSecondary;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
        boxShadow: DplShadows.card,
      ),
      child: Column(
        children: [
          Icon(icon, size: 48, color: c),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: c,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              color: DplColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openLeciScanner() async {
    final result = await Navigator.of(context).push<_LeciResult>(
      MaterialPageRoute(builder: (_) => const _LeciScannerScreen()),
    );
    if (!mounted || result == null) return;
    await _submitLeci(result);
  }

  Future<void> _submitLeci(_LeciResult r) async {
    if (r.truckNo.isEmpty) {
      DplSnacks.error(context, 'Could not read a truck number from the LECI barcode. Please rescan.');
      return;
    }
    setState(() => _busy = true);
    final api = ref.read(dplApiServiceProvider);
    final res = await api.tataGateInTrip(
      widget.tripId,
      leciBarcode: r.raw,
      leciTruckNo: r.truckNo,
      leciNo: r.leciNo,
      leciRfid: r.rfid,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.isError) {
      final err = res.error ?? 'TATA Gate In failed';
      final isMismatch = err.toLowerCase().contains('vehicle_mismatch') ||
          err.toLowerCase().contains('mismatch');
      DplSnacks.error(
        context,
        isMismatch
            ? 'Vehicle number on LECI does not match this trip. Please verify.'
            : err,
      );
      return;
    }
    DplSnacks.success(context, 'TATA Gate In recorded.');
    await _load();
  }

  /// Fallback path when the LECI barcode won't scan: driver photographs
  /// the paper + types the truck no, and the gate-in is recorded with the
  /// image instead of a scanned barcode.
  Future<void> _openLeciPhotoUpload() async {
    final result = await showModalBottomSheet<_LeciPhotoResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LeciPhotoSheet(tripId: widget.tripId),
    );
    if (!mounted || result == null) return;
    await _submitLeciPhoto(result);
  }

  Future<void> _submitLeciPhoto(_LeciPhotoResult r) async {
    setState(() => _busy = true);
    final api = ref.read(dplApiServiceProvider);
    final res = await api.tataGateInTrip(
      widget.tripId,
      // No scanned barcode on this path — the photo IS the evidence.
      leciBarcode: '',
      leciTruckNo: r.truckNo,
      leciNo: r.leciNo,
      leciPhotoBytes: r.bytes,
      leciPhotoFilename: r.filename,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.isError) {
      final err = res.error ?? 'TATA Gate In failed';
      final isMismatch = err.toLowerCase().contains('vehicle_mismatch') ||
          err.toLowerCase().contains('mismatch');
      DplSnacks.error(
        context,
        isMismatch
            ? 'Vehicle number does not match this trip. Please verify.'
            : err,
      );
      return;
    }
    DplSnacks.success(context, 'TATA Gate In recorded with LECI photo.');
    await _load();
  }

  Future<void> _markGateOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Mark TATA Gate Out'),
        content: const Text(
            'This finalises the trip. Confirm you have exited the TATA gate.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _busy = true);
    final api = ref.read(dplApiServiceProvider);
    final res = await api.tataGateOutTrip(widget.tripId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.isError) {
      DplSnacks.error(context, res.error ?? 'Gate Out failed');
      return;
    }
    DplSnacks.success(context, 'Trip complete.');
    await _load();
  }
}

// ─────────────────────────────────────────────────────────────────────
// LECI scanner (full-screen) — parses TATA gate paper barcode text
// ─────────────────────────────────────────────────────────────────────

class _LeciResult {
  final String raw;
  final String leciNo;
  final String truckNo;
  final String rfid;
  const _LeciResult({
    required this.raw,
    required this.leciNo,
    required this.truckNo,
    required this.rfid,
  });
}

/// LECI paper is line-oriented text of the form:
///   RFID No: 33124163324
///   Check-in: 20.07.2026 / 12:47:06
///   Check Point: AHD01
///   Truck Number: KA-51-AK-3966
///   Driver Name: ...
///   ...
///   LECI No: 2668193S
///
/// Some scanners emit newlines, some emit spaces. We extract by regex
/// so either variant works.
_LeciResult _parseLeci(String raw) {
  final normalized = raw.replaceAll('\r', '\n');
  String pick(RegExp re) {
    final m = re.firstMatch(normalized);
    return (m?.group(1) ?? '').trim();
  }
  return _LeciResult(
    raw: raw,
    leciNo: pick(RegExp(r'LECI\s*No[:\s]+([A-Za-z0-9\-]+)', caseSensitive: false)),
    truckNo: pick(RegExp(r'Truck\s*Number[:\s]+([A-Za-z0-9\-\s]+?)(?=\s{2,}|\n|$)', caseSensitive: false)),
    rfid:   pick(RegExp(r'RFID\s*No[:\s]+([A-Za-z0-9\-]+)', caseSensitive: false)),
  );
}

class _LeciScannerScreen extends StatefulWidget {
  const _LeciScannerScreen();

  @override
  State<_LeciScannerScreen> createState() => _LeciScannerScreenState();
}

class _LeciScannerScreenState extends State<_LeciScannerScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan LECI barcode')),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          if (_handled) return;
          final code = capture.barcodes.firstOrNull;
          final raw = code?.rawValue ?? '';
          if (raw.isEmpty) return;
          _handled = true;
          final parsed = _parseLeci(raw);
          Navigator.of(context).pop(parsed);
        },
        errorBuilder: (_, err, _) =>
            ScannerErrorView(error: err, onRetry: _controller.start),
      ),
    );
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// Result of the LECI photo-fallback sheet: the captured image + the
/// manually-entered truck no (required) and optional LECI no.
class _LeciPhotoResult {
  final Uint8List bytes;
  final String filename;
  final String truckNo;
  final String leciNo;
  const _LeciPhotoResult({
    required this.bytes,
    required this.filename,
    required this.truckNo,
    required this.leciNo,
  });
}

/// Bottom sheet for the "barcode won't scan" fallback: photograph the LECI
/// paper + type the truck no. Pops a [_LeciPhotoResult] on confirm. Mirrors
/// the trolley-photo capture UX (rear camera, retrieve-lost-data recovery
/// for when Android kills the app behind the camera intent).
class _LeciPhotoSheet extends ConsumerStatefulWidget {
  const _LeciPhotoSheet({required this.tripId});

  /// Needed so the slip can be read against THIS trip's vehicle — the scan
  /// reports whether what it read will pass gate-in's plate cross-check.
  final int tripId;

  @override
  ConsumerState<_LeciPhotoSheet> createState() => _LeciPhotoSheetState();
}

class _LeciPhotoSheetState extends ConsumerState<_LeciPhotoSheet> {
  final _picker = ImagePicker();
  final _truckCtrl = TextEditingController();
  final _leciCtrl = TextEditingController();
  Uint8List? _bytes;
  String _filename = 'leci.jpg';
  bool _capturing = false;
  String? _error;
  bool _scanning = false;
  DplLeciScan? _scan;
  /// Set when the slip could not be read — advisory only, never blocking.
  String? _scanNote;

  @override
  void initState() {
    super.initState();
    _tryRecoverLostShot();
  }

  @override
  void dispose() {
    _truckCtrl.dispose();
    _leciCtrl.dispose();
    super.dispose();
  }

  Future<void> _tryRecoverLostShot() async {
    try {
      final lost = await _picker.retrieveLostData();
      if (lost.isEmpty ||
          lost.file == null ||
          lost.type != RetrieveType.image) {
        return;
      }
      await _useXFile(lost.file!);
    } catch (_) {
      // Platform doesn't support retrieveLostData — safe to ignore.
    }
  }

  Future<void> _useXFile(XFile picked) async {
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _filename = picked.name.isEmpty ? 'leci.jpg' : picked.name;
      _capturing = false;
      _error = null;
      // A new photo invalidates the previous reading.
      _scan = null;
    });
    // Read the slip straight away. The driver is at a gate with a queue
    // behind them, so making them press a second button to do the obvious
    // next thing would waste the only advantage this has over typing.
    await _readSlip();
  }

  /// Ask the backend to read the captured slip, and prefill what it found.
  ///
  /// Best-effort by design: if the scan fails, times out or reads nothing,
  /// the sheet is exactly as usable as it was before this feature existed —
  /// the driver types the truck number and submits. Nothing here can block a
  /// gate-in.
  Future<void> _readSlip() async {
    final bytes = _bytes;
    if (bytes == null || _scanning) return;
    setState(() => _scanning = true);

    final res = await ref.read(dplApiServiceProvider).leciScanTrip(
          widget.tripId,
          photoBytes: bytes,
          filename: _filename,
        );
    if (!mounted) return;

    if (res.isError || res.data == null) {
      setState(() {
        _scanning = false;
        // Deliberately not surfaced as an error: reading the slip is a
        // convenience, and the driver still has a working form.
        _scanNote = 'Could not read the slip automatically — type the truck number.';
      });
      return;
    }

    final scan = res.data!;
    setState(() {
      _scanning = false;
      _scan = scan;
      // Never overwrite what the driver already typed — they are holding the
      // paper and we are not.
      if (scan.hasTruckNo && _truckCtrl.text.trim().isEmpty) {
        _truckCtrl.text = scan.leciTruckNo!;
      }
      final leciNo = scan.leciNo;
      if (leciNo != null && leciNo.isNotEmpty && _leciCtrl.text.trim().isEmpty) {
        _leciCtrl.text = leciNo;
      }
      _scanNote = null;
    });
  }

  Future<void> _pick(ImageSource source) async {
    setState(() {
      _capturing = true;
      _error = null;
    });
    try {
      final picked = await _picker.pickImage(
        source: source,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 80,
        maxWidth: 1600,
      );
      if (picked == null) {
        if (!mounted) return;
        setState(() => _capturing = false);
        return;
      }
      await _useXFile(picked);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _capturing = false;
        _error = 'Could not capture the photo: $e';
      });
    }
  }

  /// What the slip reading found, and whether it agrees with this trip.
  ///
  /// The plate comparison is the useful part: gate-in rejects a truck number
  /// that does not match the trip vehicle, so showing the answer HERE turns a
  /// post-submit 409 into something the driver can sort out while still
  /// standing at the gate.
  Widget _scanPanel() {
    if (_scanning) {
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text(
              'Reading the slip…',
              style: TextStyle(color: DplColors.textSecondary, fontSize: 12.5),
            ),
          ],
        ),
      );
    }

    if (_scanNote != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          _scanNote!,
          style: const TextStyle(
            color: DplColors.textSecondary,
            fontSize: 12.5,
          ),
        ),
      );
    }

    final scan = _scan;
    if (scan == null) return const SizedBox.shrink();

    if (!scan.hasTruckNo) {
      // Read nothing usable. Point at the truck, not the paper: the plate on
      // the vehicle is the thing that has to be right.
      final photo = scan.warnings.where((w) => w.isPhotoQuality).toList();
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              photo.isNotEmpty
                  ? photo.first.message
                  : 'No truck number could be read — type it from the plate on the truck.',
              style: const TextStyle(
                color: DplColors.warning,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    final ok = scan.plateConfirmedByTrip;
    final attention = scan.plateNeedsAttention;
    final color = ok
        ? DplColors.success
        : attention
            ? DplColors.warning
            : DplColors.textSecondary;

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                ok
                    ? Icons.verified_outlined
                    : attention
                        ? Icons.warning_amber_rounded
                        : Icons.document_scanner_outlined,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  ok
                      ? 'Truck ${scan.leciTruckNo} — matches this trip'
                      : 'Read truck ${scan.leciTruckNo}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          // Only when there is something to act on. On an exact match the
          // headline above already says everything.
          if (!ok && scan.plateNote != null) ...[
            const SizedBox(height: 4),
            Text(
              scan.plateNote!,
              style: const TextStyle(
                fontSize: 12,
                height: 1.3,
                color: DplColors.textPrimary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Truck number softened to optional (2026-07-25). Photo is still the
  // load-bearing evidence — submit is enabled the moment a photo is captured.
  bool get _canSubmit => _bytes != null && !_capturing;

  void _submit() {
    if (!_canSubmit) return;
    Navigator.of(context).pop(
      _LeciPhotoResult(
        bytes: _bytes!,
        filename: _filename,
        truckNo: _truckCtrl.text.trim(),
        leciNo: _leciCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: DplColors.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Upload LECI photo',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                const Text(
                  "Barcode won't scan? Snap a clear photo of the LECI paper — "
                  'the truck number is read from it automatically. Check it '
                  'against the plate before submitting.',
                  style: TextStyle(
                    color: DplColors.textSecondary,
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 14),
                AspectRatio(
                  aspectRatio: 16 / 10,
                  child: Container(
                    decoration: BoxDecoration(
                      color: DplColors.neutralBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: DplColors.divider),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _bytes != null
                        ? Image.memory(_bytes!, fit: BoxFit.cover)
                        : Center(
                            child: _capturing
                                ? const CircularProgressIndicator()
                                : const Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.image_outlined,
                                          size: 40,
                                          color: DplColors.textTertiary),
                                      SizedBox(height: 6),
                                      Text('No photo yet',
                                          style: TextStyle(
                                              color: DplColors.textSecondary)),
                                    ],
                                  ),
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _capturing
                            ? null
                            : () => _pick(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_outlined, size: 18),
                        label: Text(_bytes == null ? 'Take photo' : 'Retake'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _capturing
                            ? null
                            : () => _pick(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library_outlined, size: 18),
                        label: const Text('Gallery'),
                      ),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: DplColors.error,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                _scanPanel(),
                const SizedBox(height: 14),
                TextField(
                  controller: _truckCtrl,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'Truck number (optional)',
                    prefixIcon:
                        const Icon(Icons.local_shipping_outlined, size: 18),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _leciCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'LECI no (optional)',
                    prefixIcon: const Icon(Icons.tag_rounded, size: 18),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _canSubmit ? _submit : null,
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Submit gate-in'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
