import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../journey/widgets/scanner_error_view.dart';
import '../../models/dpl_logistics.dart';
import '../common/maxion_kit.dart';
import 'gate_pass_screen.dart';
import 'logistics_scan_page.dart';

/// Security's gate check (§8.3): scan the gate pass QR, see one unmistakable
/// answer, let the truck out or stop it.
class DplGatePassVerifyScreen extends ConsumerStatefulWidget {
  const DplGatePassVerifyScreen({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  ConsumerState<DplGatePassVerifyScreen> createState() => _DplGatePassVerifyScreenState();
}

class _DplGatePassVerifyScreenState extends ConsumerState<DplGatePassVerifyScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  final _manual = TextEditingController();
  final _manualFocus = FocusNode();

  bool _busy = false;
  DplGatePassCheck? _check;
  String? _error;

  bool get _showingResult => _check != null || _error != null;

  @override
  void dispose() {
    _controller.dispose();
    _manual.dispose();
    _manualFocus.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy || _showingResult) return;
    final code = capture.barcodes
        .map((b) => b.rawValue?.trim() ?? '')
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (code.isEmpty) return;
    await _controller.stop();
    await _verify(code);
  }

  Future<void> _verify(String token) async {
    final t = token.trim();
    if (t.isEmpty) return;
    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).verifyGatePass(t);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res.isError || res.data == null) {
        _check = null;
        _error = res.floorMessage.trim().isEmpty ? 'Could not check that gate pass.' : res.floorMessage;
      } else {
        _check = res.data;
        _error = null;
      }
    });
    final good = _error == null && (_check?.valid ?? false);
    if (good) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.heavyImpact();
    }
  }

  /// Back to the camera. The MobileScanner widget is re-mounted by this
  /// rebuild and starts the (autoStart) controller itself; starting it here as
  /// well would race that.
  void _scanNext() {
    setState(() {
      _check = null;
      _error = null;
      _manual.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final body = _showingResult ? _result() : _scanner();
    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Gate check',
        actions: [
          if (!_showingResult) ...[
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
          const DplLanguageMenuButton(),
        ],
      ),
      body: body,
    );
  }

  Widget _scanner() {
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: Colors.black,
                child: MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  errorBuilder: (_, err, _) => ScannerErrorView(error: err, onRetry: _controller.start),
                ),
              ),
              const IgnorePointer(child: LogisticsScanFrameOverlay()),
              if (_busy) const Center(child: CircularProgressIndicator(color: Colors.white)),
              const Positioned(
                top: 12,
                left: 0,
                right: 0,
                child: Center(
                  child: Text('Point at the QR on the gate pass',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manual,
                    focusNode: _manualFocus,
                    enabled: !_busy,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Or paste / scan the gate pass code',
                      prefixIcon: Icon(Icons.keyboard_alt_outlined),
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (v) async {
                      await _controller.stop();
                      await _verify(v);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          await _controller.stop();
                          await _verify(_manual.text);
                        },
                  child: const Text('Check'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _result() {
    final c = _check;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(DplSpacing.md),
            children: [
              GatePassResultPanel(check: c, error: _error),
              if (c != null) ...[
                const SizedBox(height: DplSpacing.md),
                if (c.shipment != null)
                  DplCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Trip #${c.shipment!.tripNumber} · ${c.tripStatus}',
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                        const SizedBox(height: 8),
                        GatePassShipmentFacts(shipment: c.shipment!),
                      ],
                    ),
                  ),
                const SizedBox(height: DplSpacing.md),
                DplCard(
                  padding: const EdgeInsets.symmetric(vertical: DplSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: DplSpacing.lg),
                        child: Text('Items on the truck', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      ),
                      GatePassLinesTable(lines: c.lines),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: DplSpacing.lg),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: DplCountChip(label: 'Total qty', count: c.totalQty),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton.icon(
                onPressed: _scanNext,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan next', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The one big answer a guard reads from across the cabin.
///
/// Order matters: a pass already used is reported as such (amber) even though
/// the server also marks it invalid, because "this truck already left" calls
/// for a different reaction from "this pass is incomplete".
class GatePassResultPanel extends StatelessWidget {
  const GatePassResultPanel({super.key, this.check, this.error});

  final DplGatePassCheck? check;

  /// A refusal from the server (forged token, another plant's pass, network).
  final String? error;

  static const _green = Color(0xFF15803D);
  static const _red = Color(0xFFB91C1C);
  static const _amber = Color(0xFFB45309);

  @override
  Widget build(BuildContext context) {
    final c = check;
    late final Color color;
    late final IconData icon;
    late final String headline;
    String? detail;

    if (c == null) {
      color = _red;
      icon = Icons.gpp_bad_outlined;
      headline = 'DO NOT LET OUT';
      detail = error ?? 'This gate pass could not be checked.';
    } else if (c.alreadyGatedOut) {
      color = _amber;
      icon = Icons.history_toggle_off;
      final at = c.gatedOutAt == null ? '' : DateFormat('d MMM, HH:mm').format(c.gatedOutAt!.toLocal());
      final by = (c.gatedOutBy == null || c.gatedOutBy!.isEmpty) ? '' : ' by ${c.gatedOutBy}';
      headline = 'ALREADY LET OUT at $at$by';
      detail = 'This pass has been used. Do not let a second truck out on it.';
    } else if (c.valid) {
      color = _green;
      icon = Icons.verified_outlined;
      headline = 'CLEAR TO GO';
    } else {
      color = _red;
      icon = Icons.gpp_bad_outlined;
      headline = 'DO NOT LET OUT';
      detail = (c.problem == null || c.problem!.isEmpty) ? 'This gate pass is not valid.' : c.problem;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(DplRadius.lg)),
      child: Column(
        children: [
          Icon(icon, color: Colors.white, size: 56),
          const SizedBox(height: 8),
          Text(
            headline,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900, height: 1.15),
          ),
          if (c != null && c.gatePassNo.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(c.gatePassNo,
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
          ],
          if (detail != null) ...[
            const SizedBox(height: 10),
            Text(detail,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }
}
