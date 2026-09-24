import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/design/dpl_theme.dart';
import '../../journey/widgets/scanner_error_view.dart';

/// Opens the camera, reads one code, and pops it back as a raw string.
///
/// Deliberately dumb. It does NOT decide whether the code is valid — the
/// server does that on every scan, and duplicating the rule here would give
/// two places to disagree. What it DOES do is refuse codes that are obviously
/// not a wheel label before the round trip, because at the pack point the
/// difference between "refused in 40 ms" and "refused in 400 ms" is whether
/// the operator has already reached for the next wheel.
///
/// Returns the raw payload, or null when the operator backs out.
/// Which label this camera session is meant to read.
///
/// The same viewfinder serves the pack point (wheels onto a pallet) and the
/// warehouse (a pallet onto a rack), and the two must refuse each other's
/// labels BY NAME. An operator who scans a wheel at the rack has made a real
/// mistake, and "that does not look like a pallet label" sends them looking at
/// what is in their hand, where "nothing found" sends them to IT.
enum DplScanKind { wheel, pallet }

class DplQrScanSheet extends StatefulWidget {
  /// Shown under the viewfinder so the operator knows what they are pointing
  /// at — e.g. the pallet's part number.
  final String expecting;

  /// What counts as a valid read. Defaults to a wheel label, which is what
  /// every caller before the warehouse flow wanted.
  final DplScanKind kind;

  const DplQrScanSheet({
    super.key,
    this.expecting = '',
    this.kind = DplScanKind.wheel,
  });

  static Future<String?> open(
    BuildContext context, {
    String expecting = '',
    DplScanKind kind = DplScanKind.wheel,
  }) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => DplQrScanSheet(expecting: expecting, kind: kind),
      ),
    );
  }

  @override
  State<DplQrScanSheet> createState() => _DplQrScanSheetState();
}

class _DplQrScanSheetState extends State<DplQrScanSheet> {
  final MobileScannerController _controller = MobileScannerController(
    // noDuplicates stops one wheel being read forty times while the operator
    // lines up the next.
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode, BarcodeFormat.dataMatrix],
  );

  bool _handled = false;
  String? _rejected;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Is this plausibly one of OUR wheel labels?
  ///
  /// A wheel label is either the full pipe payload `GA|plant|part|serial|…` or
  /// a bare `GA` + year + 8 digits serial. Anything else — a pallet master
  /// (`GAP|`), a trip master (`GAM|`), a carton barcode, a rack label — is
  /// refused here by name so the operator is told WHAT they scanned rather
  /// than "not a label this system printed".
  String? _rejectReason(String raw) {
    final code = raw.trim();
    if (code.isEmpty) return 'Nothing was read.';
    return widget.kind == DplScanKind.pallet
        ? _rejectAsPallet(code)
        : _rejectAsWheel(code);
  }

  String? _rejectAsWheel(String code) {
    if (code.contains('|')) {
      final kind = code.split('|').first.toUpperCase();
      if (kind == 'GAM') {
        return 'That is a trip master sticker, not a wheel label.';
      }
      // MWP is what the pallet label actually carries (SSR §5). GAP was an
      // earlier guess at the prefix and never printed on anything.
      if (kind == 'MWP' || kind == 'GAP') {
        return 'That is a pallet label, not a wheel label.';
      }
      if (kind != 'GA') {
        return 'That is not a wheel label from this system.';
      }
      return null;
    }

    // A bare serial keyed or scanned off the human-readable row.
    if (RegExp(r'^GA\d{6,}$', caseSensitive: false).hasMatch(code)) return null;

    // A pallet number is self-identifying by prefix, so name it precisely.
    if (RegExp(r'^(PM|P|H|M)\d{6,}$').hasMatch(code)) {
      return 'That is a pallet number, not a wheel label.';
    }

    return 'That does not look like a wheel label.';
  }

  /// The mirror image, for the warehouse. SSR §5: the pallet QR is
  /// `MWP|PM26000012`, and the number is printed underneath so a damaged code
  /// can be keyed in — so both forms are accepted.
  String? _rejectAsPallet(String code) {
    if (code.contains('|')) {
      final kind = code.split('|').first.toUpperCase();
      if (kind == 'MWP') return null;
      if (kind == 'GA') {
        return 'That is a wheel label. Scan the sticker on the pallet itself.';
      }
      if (kind == 'GAM') {
        return 'That is a trip master sticker, not a pallet label.';
      }
      return 'That is not a pallet label from this system.';
    }

    if (RegExp(r'^(PM|P|H|M)\d{6,}$', caseSensitive: false).hasMatch(code)) {
      return null;
    }
    if (RegExp(r'^GA\d{6,}$', caseSensitive: false).hasMatch(code)) {
      return 'That is a wheel serial. Scan the sticker on the pallet itself.';
    }
    return 'That does not look like a pallet label.';
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue ?? '')
        .firstWhere((v) => v.trim().isNotEmpty, orElse: () => '');
    if (raw.trim().isEmpty) return;

    final reason = _rejectReason(raw);
    if (reason != null) {
      // Stay open. The operator is holding a wheel and should be able to try
      // the next one without reopening the camera.
      setState(() => _rejected = reason);
      return;
    }

    _handled = true;
    Navigator.of(context).pop(raw.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan a wheel label'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Torch',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (_, err, _) => ScannerErrorView(
                error: err,
                onRetry: _controller.start,
              ),
            ),
          ),
          Container(
            width: double.infinity,
            color: Colors.black,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.expecting.isNotEmpty)
                  Text(
                    'Packing ${widget.expecting}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                const SizedBox(height: 6),
                if (_rejected != null)
                  Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: DplColors.error,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _rejected!,
                          style: const TextStyle(
                            color: DplColors.error,
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  const Text(
                    'Hold the wheel label inside the frame. The part is '
                    'checked again on the server before it is accepted.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
