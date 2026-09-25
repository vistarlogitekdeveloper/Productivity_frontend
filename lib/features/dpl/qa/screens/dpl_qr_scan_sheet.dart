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

  /// Also accept wheel stickers printed by the plant's OTHER system.
  ///
  /// Off by default, and driven by `labels.scan_external`. During the
  /// changeover an operator is holding two kinds of sticker; once the plant
  /// stops printing the old ones this goes back off and the camera refuses
  /// them again, which is how the transition actually ends.
  final bool allowExternal;

  const DplQrScanSheet({
    super.key,
    this.expecting = '',
    this.kind = DplScanKind.wheel,
    this.allowExternal = false,
  });

  static Future<String?> open(
    BuildContext context, {
    String expecting = '',
    DplScanKind kind = DplScanKind.wheel,
    bool allowExternal = false,
  }) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => DplQrScanSheet(
          expecting: expecting,
          kind: kind,
          allowExternal: allowExternal,
        ),
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

  /// One of the plant's OTHER system's wheel stickers, e.g.
  /// `19255/stdD1//48/24Sep26/11:37:04/A/48`.
  ///
  /// A NEGATIVE test, mirroring the server's: anything that is not
  /// recognisably one of ours, and carries enough slash-separated structure to
  /// be a label rather than a stray word, is theirs. Testing for their exact
  /// layout would quietly stop matching the day a product line prints it
  /// slightly differently — and the server is the authority regardless; this
  /// only decides whether the camera keeps the viewfinder open.
  /// MUST stay equivalent to `looksExternal` on the server — a camera that
  /// refuses what the server would accept, or accepts what it would reject, is
  /// what teaches an operator to distrust the app.
  bool _looksExternal(String code) {
    if (code.contains('|')) return false;
    if (RegExp(r'^GA\d{6,}$', caseSensitive: false).hasMatch(code)) return false;
    if (RegExp(r'^(PM|P|H|M|SP)\d{6,}$', caseSensitive: false).hasMatch(code)) {
      return false;
    }

    // A separator count alone is not enough: a URL, a PO number and even '////'
    // all clear four fields, and adoption MINTS a wheel. The camera reads QR
    // and DataMatrix — exactly what a URL poster or an asset tag carries.
    if (code.contains('://')) return false;
    if (RegExp(r'\s').hasMatch(code)) return false;
    final fields = code.split('/');
    if (fields.length < 4) return false;
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{2,23}$').hasMatch(fields.first)) {
      return false;
    }
    // Something that anchors it as a WHEEL label rather than a reference
    // number — a timestamp or a DDMonYY date, wherever it falls.
    final hasTime = RegExp(r'\d{2}:\d{2}:\d{2}').hasMatch(code);
    final hasDate = RegExp(r'\d{1,2}[A-Za-z]{3}\d{2}').hasMatch(code);
    return hasTime || hasDate;
  }

  String? _rejectAsWheel(String code) {
    // Accepted only where an administrator has switched it on, so the plant
    // can stop taking old labels by unticking a box rather than by shipping a
    // build.
    if (widget.allowExternal && _looksExternal(code)) return null;

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

    // Named precisely, WITH the remedy. During the changeover this is the
    // single most likely mis-scan, and it is not a fault at all — it is a
    // setting that has not been switched on. Saying only "not set up yet"
    // sends the operator to look for a broken scanner, or to the developer.
    if (_looksExternal(code)) {
      return 'That is one of the old labels. Ask an administrator to tick '
          '“Accept the plant’s old labels” for this organization under '
          'Administration → Access rules.';
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
