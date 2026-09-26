import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../maxion/logistics/reversal_widgets.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../auth/auth_provider.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_constants.dart';
import '../../core/dpl_organization_provider.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../manager/widgets/error_retry.dart';
import '../../models/dpl_dispatch_slip.dart';
import '../../journey/widgets/scanner_error_view.dart';
import '../providers/dispatch_slips_provider.dart';
import '../services/dispatch_slip_pdf.dart';
import '../widgets/dispatch_slip_actions.dart';
import '../widgets/dispatch_slip_status_badge.dart';

/// Printable detail view of a single dispatch slip.
///
/// Layout mirrors the `vistar_pulse_dispatch_slip.html` reference design
/// — a single rounded paper with a gradient purple header band, a 5-cell
/// identity strip (Vehicle / Plant / Machine / Part description / Dispatched),
/// a parts table with a Total row, QA + PDI sign-off checkpoints, and a
/// verification panel carrying the QR code + a key/value contents grid.
///
/// Below the printable area we render role-aware action buttons:
///   * `dpl_qa` on a `pending_qa` slip → Approve / Reject
///   * `dpl_pdi` on a `pending_pdi` slip → Approve / Reject
///   * `dpl_dispatch` on an `approved` slip → Mark dispatched
///
/// **Scan-to-act gate (QA + PDI)**: pure `dpl_qa` and `dpl_pdi` users
/// must physically scan the printed slip's QR before Approve/Reject
/// becomes available. The QR + approval buttons are hidden until the
/// scanned token matches `slip.qrPayload`. Managers bypass this gate.
class DispatchSlipDetailScreen extends ConsumerStatefulWidget {
  final int slipId;
  const DispatchSlipDetailScreen({super.key, required this.slipId});

  @override
  ConsumerState<DispatchSlipDetailScreen> createState() =>
      _DispatchSlipDetailScreenState();
}

class _DispatchSlipDetailScreenState
    extends ConsumerState<DispatchSlipDetailScreen> {
  /// Whether the current user has scanned the printed slip's QR and the
  /// scanned token matched `slip.qrPayload`. Resets across navigations
  /// because the state lives on the screen instance.
  bool _scanVerified = false;

  /// Guards the AppBar Email button so back-to-back taps can't fire
  /// two uploads. Render bytes once, POST once, snack the result.
  bool _emailing = false;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(dplDispatchSlipDetailProvider(widget.slipId));
    final role = ref.watch(authControllerProvider).asData?.value?.role ?? '';

    final slipForActions = async.asData?.value.data;

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Dispatch Slip',
        actions: [
          IconButton(
            tooltip: _emailing ? 'Emailing slip…' : 'Email PDF to Dispatch',
            icon: _emailing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.mail_outline_rounded),
            onPressed: (slipForActions == null || _emailing)
                ? null
                : () => _emailSlip(context, ref, slipForActions),
          ),
          IconButton(
            tooltip: 'Print / Save PDF',
            icon: const Icon(Icons.print_outlined),
            onPressed: slipForActions == null
                ? null
                : () => _printSlip(context, ref, slipForActions),
          ),
          // Shipment reversal (backend migration 160): only a dispatched slip,
          // and only somebody holding slips.reverse. A manager approves it.
          if (slipForActions != null &&
              slipForActions.status == 'dispatched' &&
              ref.watch(dplPermissionsProvider).can(DplPermission.slipsReverse))
            IconButton(
              tooltip: 'Request a shipment reversal',
              icon: const Icon(Icons.undo_outlined),
              onPressed: () async {
                await showRequestReversalSheet(context, ref,
                    slipId: slipForActions.id, slipNo: slipForActions.slipNo);
                ref.invalidate(dplDispatchSlipDetailProvider(widget.slipId));
              },
            ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => DplErrorRetry(
          message: e.toString(),
          onRetry: () =>
              ref.invalidate(dplDispatchSlipDetailProvider(widget.slipId)),
        ),
        data: (res) {
          if (res.isError || res.data == null) {
            return DplErrorRetry(
              message: res.error ?? 'Failed to load slip.',
              onRetry: () =>
                  ref.invalidate(dplDispatchSlipDetailProvider(widget.slipId)),
            );
          }
          final slip = res.data!;
          final requiresScan = _requiresScanFor(role: role, slip: slip);

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _HeaderSummary(slip: slip),
                const SizedBox(height: 14),
                _PrintableSlip(
                  slip: slip,
                  // Pure QA/PDI users see the QR only after scanning the
                  // physical paper. Until then we render a locked
                  // placeholder so they can't act on a slip they don't
                  // physically have in front of them.
                  hideQr: requiresScan && !_scanVerified,
                  onScan: requiresScan && !_scanVerified
                      ? () => _openScanner(slip)
                      : null,
                ),
                const SizedBox(height: 14),
                _Timeline(slip: slip),
                const SizedBox(height: 14),
                _RoleActions(
                  slip: slip,
                  role: role,
                  requiresScan: requiresScan,
                  scanVerified: _scanVerified,
                  onScan: () => _openScanner(slip),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// True when the user is a pure `dpl_pdi` and the slip is in the
  /// state they're expected to act on. Managers bypass the gate
  /// because they're trusted to override at any point. Dispatch has its
  /// own scanner flow at the gate, so we don't apply it here.
  ///
  /// QA role is intentionally NOT gated here — the QA approval step
  /// was removed from the workflow; slips go straight to PDI. The
  /// `isQa`/`isQaActing` branches are kept commented for easy
  /// re-enable if QA ever comes back into the flow.
  bool _requiresScanFor({required String role, required DplDispatchSlip slip}) {
    final isManager = AppConstants.isDplManagerRole(role);
    if (isManager) return false;
    // final isQa = AppConstants.isDplQaRole(role);
    final isPdi = AppConstants.isDplPdiRole(role);
    // final isQaActing =
    //     isQa && slip.status == DplDispatchSlipStatus.pendingQa;
    final isPdiActing =
        isPdi && slip.status == DplDispatchSlipStatus.pendingPdi;
    return isPdiActing;
  }

  /// Opens the camera scanner. Compares the scanned token against the
  /// slip's `qrPayload` — local match is sufficient since the slip
  /// payload itself came from a trusted authenticated API call. Anyone
  /// holding the printed paper will scan the same signed token.
  Future<void> _openScanner(DplDispatchSlip slip) async {
    final expected = (slip.qrPayload ?? '').trim();
    if (expected.isEmpty) {
      DplSnacks.error(
        context,
        'This slip does not yet have a QR — ask Dispatch to (re)issue it.',
      );
      return;
    }

    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _SlipScanGateScreen(slipNo: slip.slipNo),
        fullscreenDialog: true,
      ),
    );
    if (!mounted) return;
    if (scanned == null) return;

    if (scanned.trim() == expected) {
      setState(() => _scanVerified = true);
      DplSnacks.success(context, 'Slip verified. Approval actions unlocked.');
    } else {
      DplSnacks.error(
        context,
        'Scanned QR does not match this slip. Make sure you are scanning '
        '${slip.slipNo}.',
      );
    }
  }

  /// Hands the slip's PDF to the OS print sheet via the `printing`
  /// package. Works on Android (system print dialog), iOS (AirPrint
  /// sheet), and web (browser print preview). The PDF mirrors the
  /// on-screen printable layout exactly, with the same QA / PDI state
  /// labels and the QR code embedded as a vector barcode (so it stays
  /// crisp regardless of print DPI).
  Future<void> _printSlip(
    BuildContext context,
    WidgetRef ref,
    DplDispatchSlip slip,
  ) async {
    try {
      final orgLabel = ref.read(dplActiveOrganizationProvider)?.displayLabel;
      await Printing.layoutPdf(
        name: 'Dispatch-${slip.slipNo}',
        onLayout: (_) =>
            DispatchSlipPdfBuilder.build(slip, organizationLabel: orgLabel),
      );
    } on MissingPluginException {
      // Almost always means the running app binary predates the
      // `printing` plugin being added to pubspec — the Dart side calls
      // through but no native handler is registered. Hot restart can't
      // fix this; the user has to fully stop + rebuild.
      if (context.mounted) {
        DplSnacks.error(
          context,
          'Print not available in this build. Please fully restart the '
          'app (stop + run again) so the print plugin is registered.',
        );
      }
    } catch (e) {
      if (context.mounted) {
        DplSnacks.error(context, 'Failed to open print sheet: $e');
      }
    }
  }

  /// Renders the same PDF the print sheet would produce and uploads it
  /// to `POST /api/v1/dpl/dispatch/slips/:id/email` as `multipart/form-data`.
  /// Default TO/CC are server-side; nothing is sent from the FE unless
  /// the user explicitly adds extras (no current UI for that — the
  /// detail-screen button uses backend defaults).
  ///
  /// The button itself is disabled while [_emailing] is true so a
  /// double-tap can't fire two uploads.
  Future<void> _emailSlip(
    BuildContext context,
    WidgetRef ref,
    DplDispatchSlip slip,
  ) async {
    setState(() => _emailing = true);

    final orgLabel = ref.read(dplActiveOrganizationProvider)?.displayLabel;
    final api = ref.read(dplApiServiceProvider);

    Uint8List pdfBytes;
    try {
      pdfBytes = await DispatchSlipPdfBuilder.build(
        slip,
        organizationLabel: orgLabel,
      );
    } catch (e) {
      if (!context.mounted) return;
      setState(() => _emailing = false);
      DplSnacks.error(context, 'Could not render slip PDF: $e');
      return;
    }

    final res = await api.sendDispatchSlipEmail(
      slip.id,
      pdfBytes: pdfBytes,
      filename: '${slip.slipNo}.pdf',
    );

    if (!context.mounted) return;
    setState(() => _emailing = false);

    if (res.isError) {
      DplSnacks.error(context, 'Email failed: ${res.error ?? "unknown error"}');
      return;
    }

    final data = res.data;
    if (data == null) {
      DplSnacks.error(context, 'Email response was empty.');
      return;
    }
    if (data.sent) {
      final toLabel = data.to.isNotEmpty ? data.to.first : 'Dispatch';
      DplSnacks.success(
        context,
        data.to.length > 1
            ? 'Slip emailed to $toLabel +${data.to.length - 1} more.'
            : 'Slip emailed to $toLabel.',
      );
    } else if (data.skipped) {
      DplSnacks.warning(
        context,
        'Slip not emailed — SMTP is not configured on this deploy.',
      );
    } else {
      DplSnacks.error(
        context,
        'Email not sent: ${data.reason ?? "unknown reason"}',
      );
    }
  }
}

/// Compact slip-number + status block above the printable area. Gives
/// the user immediate context before they scroll. Not part of the
/// printable surface — sits as ambient screen chrome.
class _HeaderSummary extends StatelessWidget {
  final DplDispatchSlip slip;
  const _HeaderSummary({required this.slip});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
        boxShadow: DplShadows.card,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        slip.slipNo,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    if (slip.tripNumber != null) ...[
                      const SizedBox(width: 8),
                      _FromTripBadge(tripNumber: slip.tripNumber!),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${slip.machineLabel} • Qty ${slip.qty}',
                  style: TextStyle(
                    color: DplColors.textSecondary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          DispatchSlipStatusBadge(status: slip.status),
        ],
      ),
    );
  }
}

/// Compact "From Trip #N" badge surfaced next to the slip number on
/// the detail header. Visible only when the slip was cut from a
/// manager-submitted trip (migration 048). Legacy slips created via
/// the manual machine-picker form hide the badge entirely.
class _FromTripBadge extends StatelessWidget {
  final int tripNumber;
  const _FromTripBadge({required this.tripNumber});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: DplColors.primaryTint,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: DplColors.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.local_shipping_rounded,
            size: 11,
            color: DplColors.primaryDark,
          ),
          const SizedBox(width: 4),
          Text(
            'Trip #$tripNumber',
            style: TextStyle(
              color: DplColors.primaryDark,
              fontWeight: FontWeight.w800,
              fontSize: 10.5,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Vistar Pulse dispatch slip — HTML-mirror layout
// ─────────────────────────────────────────────────────────────────────

/// Palette tokens lifted verbatim from `vistar_pulse_dispatch_slip.html`
/// so the on-screen and printed slips match the reference design 1:1
/// without dragging the whole product palette over to the slip surface.
class _SlipPalette {
  static const brand = Color(0xFFA3238E);
  static const brandDeep = Color(0xFF6B1F8C);
  static const brandHilite = Color(0xFFB83AA3);
  static const ink = Color(0xFF1A161D);
  static const muted = Color(0xFF78727F);
  static const faint = Color(0xFFA39DAB);
  static const line = Color(0xFFE9E6EC);
  static const lineSoft = Color(0xFFF1EFF3);
  static const surface = Color(0xFFFAF9FB);
  static const paper = Color(0xFFFFFFFF);

  static const amberInk = Color(0xFF9A5B00);
  static const amberBg = Color(0xFFFEF4E0);
  static const amberLine = Color(0xFFF2D49A);

  static const emeraldInk = Color(0xFF0A7A52);
  static const emeraldBg = Color(0xFFE6F6EE);
  static const emeraldLine = Color(0xFFAEE3CA);

  static const rejectedInk = Color(0xFFB91C1C);
  static const rejectedBg = Color(0xFFFEF2F2);
  static const rejectedLine = Color(0xFFFECACA);
}

/// Display font — Saira Condensed via google_fonts. Used for the
/// vehicle plate, total qty, doc title, totals — anywhere the HTML
/// reference uses `var(--font-display)`.
TextStyle _displayStyle({
  required double size,
  FontWeight weight = FontWeight.w700,
  Color color = _SlipPalette.ink,
  double? height,
  double? letterSpacing,
}) => GoogleFonts.sairaCondensed(
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: height,
  letterSpacing: letterSpacing,
);

/// UI font — Inter via google_fonts. Used for body text, labels,
/// chips, descriptions.
TextStyle _uiStyle({
  required double size,
  FontWeight weight = FontWeight.w500,
  Color color = _SlipPalette.ink,
  double? height,
  double? letterSpacing,
}) => GoogleFonts.inter(
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: height,
  letterSpacing: letterSpacing,
);

/// Mono font — JetBrains Mono via google_fonts. Used for the slip
/// number, part numbers, sub-codes, anything that should read as data.
TextStyle _monoStyle({
  required double size,
  FontWeight weight = FontWeight.w500,
  Color color = _SlipPalette.ink,
  double? height,
  double? letterSpacing,
}) => GoogleFonts.jetBrainsMono(
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: height,
  letterSpacing: letterSpacing,
);

/// The printable Vistar Pulse dispatch slip — a single rounded paper
/// composed of a gradient header band, identity strip, parts table,
/// QA/PDI sign-off, verification panel, and footer. Layout mirrors the
/// HTML reference design at every level.
///
/// **Scan-to-act gate**: when [hideQr] is true the QR image is replaced
/// by [_ScanGatePlaceholder] (lock + Scan QR CTA). Other slip details
/// stay visible — the user can still read the contents to decide; they
/// just can't act without holding the printed paper.
class _PrintableSlip extends StatelessWidget {
  final DplDispatchSlip slip;
  final bool hideQr;
  final VoidCallback? onScan;

  const _PrintableSlip({required this.slip, this.hideQr = false, this.onScan});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        decoration: BoxDecoration(
          color: _SlipPalette.paper,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _SlipPalette.line),
          boxShadow: const [
            BoxShadow(
              color: Color(0x59281437),
              blurRadius: 60,
              spreadRadius: -28,
              offset: Offset(0, 24),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _SlipBand(slip: slip),
              _IdentityStrip(slip: slip),
              _PartsTable(slip: slip),
              _SignoffStrip(slip: slip),
              _VerifySection(slip: slip, hideQr: hideQr, onScan: onScan),
              _SlipFoot(slip: slip),
            ],
          ),
        ),
      ),
    );
  }
}

/// Gradient purple header band — brand mark + wordmark on the left,
/// document title + slip number chip on the right. Mirrors the HTML
/// `.band` block including its dashed white underline.
class _SlipBand extends StatelessWidget {
  final DplDispatchSlip slip;
  const _SlipBand({required this.slip});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _SlipPalette.brandDeep,
            _SlipPalette.brand,
            _SlipPalette.brandHilite,
          ],
          stops: [0.0, 0.62, 1.0],
          begin: Alignment(-1.0, -0.3),
          end: Alignment(1.0, 0.3),
        ),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 22, 30, 20),
            child: LayoutBuilder(
              builder: (context, c) {
                final compact = c.maxWidth < 520;
                final brand = _brand();
                final doc = _doc(
                  align: compact
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.end,
                );
                if (compact) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [brand, const SizedBox(height: 14), doc],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: brand),
                    const SizedBox(width: 24),
                    doc,
                  ],
                );
              },
            ),
          ),
          // Dashed white underline at the bottom of the band — matches
          // the HTML `.band::after` decorative bar.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SizedBox(
              height: 3,
              child: CustomPaint(painter: _DashedUnderlinePainter()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _brand() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: Colors.white.withValues(alpha: 0.32)),
          ),
          child: Text(
            'GA',
            style: _displayStyle(
              size: 23,
              weight: FontWeight.w700,
              color: Colors.white,
              height: 1,
              letterSpacing: 0.5,
            ),
          ),
        ),
        const SizedBox(width: 13),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Grupo Antolin India Private Limited',
              style: _displayStyle(
                size: 25,
                weight: FontWeight.w700,
                color: Colors.white,
                height: 1,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 5),
            // Text(
            //   'PRODUCTION · DISPATCH',
            //   style: _uiStyle(
            //     size: 11,
            //     weight: FontWeight.w600,
            //     color: Colors.white.withValues(alpha: 0.82),
            //     letterSpacing: 2.86,
            //   ),
            // ),
          ],
        ),
      ],
    );
  }

  Widget _doc({required CrossAxisAlignment align}) {
    return Column(
      crossAxisAlignment: align,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'DISPATCH SLIP',
          style: _displayStyle(
            size: 21,
            weight: FontWeight.w600,
            color: Colors.white,
            height: 1,
            letterSpacing: 3.36,
          ),
        ),
        const SizedBox(height: 9),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
          ),
          child: Text(
            slip.slipNo,
            style: _monoStyle(
              size: 12.5,
              weight: FontWeight.w500,
              color: Colors.white,
              letterSpacing: 0.13,
            ),
          ),
        ),
        // Invoice chip — same shape as the slip-no badge but a softer
        // fill + a small "INVOICE" caption so it reads as an attribute
        // of the slip, not a second identifier. Mounts only once the
        // DEO has stamped the trip's invoice.
        if (slip.invoiceNo.trim().isNotEmpty) ...[
          const SizedBox(height: 7),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'INVOICE',
                  style: _uiStyle(
                    size: 8.5,
                    weight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.72),
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  slip.invoiceNo.trim(),
                  style: _monoStyle(
                    size: 11.5,
                    weight: FontWeight.w600,
                    color: Colors.white,
                    letterSpacing: 0.13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Paints the dashed white underline at the bottom of the header band.
class _DashedUnderlinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.5 * 0.85)
      ..strokeWidth = size.height
      ..style = PaintingStyle.stroke;
    const dash = 14.0;
    const gap = 12.0;
    double x = 0;
    final y = size.height / 2;
    while (x < size.width) {
      final end = (x + dash).clamp(0, size.width).toDouble();
      canvas.drawLine(Offset(x, y), Offset(end, y), paint);
      x = end + gap;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 5-cell identity strip — Vehicle (big plate), Plant, Machine, Line
/// items, Dispatched datetime. Layout switches to a 2-column grid on
/// narrow screens (Vehicle cell spans the row, rest wrap below).
class _IdentityStrip extends StatelessWidget {
  final DplDispatchSlip slip;
  const _IdentityStrip({required this.slip});

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd MMM yyyy');
    final timeFmt = DateFormat('HH:mm');
    final referenceTime =
        slip.pdiApproval?.at ?? slip.qaApproval?.at ?? slip.requestedAt;

    final machineLabel = _machineLabel(slip);
    // Headline part description — short `description` code only
    // (e.g. "114ZZ"), so the identity strip mirrors the printed PDF.
    // For multi-item slips we still show the first item's code with
    // a "+ N more" sub-line so the gate knows the slip carries other
    // parts; the per-row breakdown lives in the parts table below.
    final firstItem = slip.firstItem;
    final partDescription = firstItem == null
        ? '-'
        : (firstItem.description.trim().isNotEmpty
              ? firstItem.description.trim()
              : '-');
    final partSub = firstItem == null
        ? null
        : (slip.items.length > 1 ? '+ ${slip.items.length - 1} more' : null);
    final dateStr = referenceTime == null
        ? '-'
        : dateFmt.format(referenceTime.toLocal());
    final timeStr = referenceTime == null
        ? null
        : '${timeFmt.format(referenceTime.toLocal())} IST';

    final cells = <Widget>[
      _IdCell(
        background: _SlipPalette.surface,
        leftBorder: false,
        child: _PlateCell(slip: slip),
      ),
      _IdCell(
        child: _LabelValue(label: 'Plant', value: slip.plant.name),
      ),
      _IdCell(
        child: _LabelValue(label: 'Machine', value: machineLabel),
      ),
      _IdCell(
        child: _LabelValue(
          label: 'Part description',
          value: partDescription,
          subValue: partSub,
        ),
      ),
      _IdCell(
        child: _LabelValue(
          label: 'Dispatched',
          value: dateStr,
          subValue: timeStr,
        ),
      ),
    ];

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _SlipPalette.line)),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 900;
          if (wide) {
            return IntrinsicHeight(
              child: Row(
                children: [
                  Expanded(flex: 14, child: cells[0]),
                  Expanded(flex: 10, child: cells[1]),
                  Expanded(flex: 10, child: cells[2]),
                  Expanded(flex: 10, child: cells[3]),
                  Expanded(flex: 10, child: cells[4]),
                ],
              ),
            );
          }
          // Narrow — vehicle cell spans the full row, rest stack in 2 cols.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              cells[0],
              IntrinsicHeight(
                child: Row(
                  children: [
                    Expanded(child: cells[1]),
                    Expanded(child: cells[2]),
                  ],
                ),
              ),
              IntrinsicHeight(
                child: Row(
                  children: [
                    Expanded(child: cells[3]),
                    Expanded(child: cells[4]),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Surface a single machine name when the slip's items all share one;
  /// otherwise expose the count so the identity strip stays honest about
  /// what's on board.
  static String _machineLabel(DplDispatchSlip slip) {
    if (slip.items.isEmpty) return slip.machineLabel;
    final names = slip.items
        .map((it) => it.machineLabel.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    if (names.length <= 1) {
      return names.isEmpty ? slip.machineLabel : names.first;
    }
    return '${names.length} machines';
  }
}

class _IdCell extends StatelessWidget {
  final Widget child;
  final Color background;
  final bool leftBorder;
  const _IdCell({
    required this.child,
    this.background = Colors.transparent,
    this.leftBorder = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
      decoration: BoxDecoration(
        color: background,
        border: Border(
          left: leftBorder
              ? const BorderSide(color: _SlipPalette.lineSoft)
              : BorderSide.none,
        ),
      ),
      child: child,
    );
  }
}

class _LabelValue extends StatelessWidget {
  final String label;
  final String value;
  final String? subValue;
  final bool mono;
  const _LabelValue({
    required this.label,
    required this.value,
    this.subValue,
  }) : mono = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: _uiStyle(
            size: 10,
            weight: FontWeight.w700,
            color: _SlipPalette.faint,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          value,
          style: mono
              ? _monoStyle(size: 13.5, weight: FontWeight.w500)
              : _uiStyle(size: 15, weight: FontWeight.w600),
        ),
        if (subValue != null) ...[
          const SizedBox(height: 2),
          Text(
            subValue!,
            style: _monoStyle(
              size: 12,
              weight: FontWeight.w500,
              color: _SlipPalette.muted,
            ),
          ),
        ],
      ],
    );
  }
}

/// The big vehicle plate cell (Saira Condensed 42pt) + a small "Dispatch
/// note" line underneath. When [DplDispatchSlip.notes] is set we render
/// it here so the operator sees it inline with the plate.
class _PlateCell extends StatelessWidget {
  final DplDispatchSlip slip;
  const _PlateCell({required this.slip});

  @override
  Widget build(BuildContext context) {
    final plate = slip.vehicleNo.isEmpty ? '-' : slip.vehicleNo;
    final notes = slip.notes.trim();

    // Step the font size down for longer plates — keeps the
    // gate-scannable look while ensuring the full plate fits in the
    // cell. FittedBox below handles any remaining edge cases.
    final n = plate.length;
    final double plateSize;
    final double plateSpacing;
    if (n <= 8) {
      plateSize = 42;
      plateSpacing = 1.7;
    } else if (n <= 10) {
      plateSize = 36;
      plateSpacing = 1.1;
    } else if (n <= 12) {
      plateSize = 30;
      plateSpacing = 0.8;
    } else {
      plateSize = 26;
      plateSpacing = 0.5;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'VEHICLE',
          style: _uiStyle(
            size: 10,
            weight: FontWeight.w700,
            color: _SlipPalette.faint,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 6),
        // FittedBox safety-net so the plate always fits regardless of
        // length — the step-down sizing above handles the common
        // cases without distortion, and FittedBox catches very long
        // edge cases (15+ chars) without any text being clipped.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            plate,
            style: _displayStyle(
              size: plateSize,
              weight: FontWeight.w700,
              color: _SlipPalette.ink,
              height: 0.95,
              letterSpacing: plateSpacing,
            ),
            maxLines: 1,
            softWrap: false,
          ),
        ),
        const SizedBox(height: 8),
        if (notes.isNotEmpty)
          RichText(
            text: TextSpan(
              style: _uiStyle(
                size: 12,
                weight: FontWeight.w500,
                color: _SlipPalette.muted,
              ),
              children: [
                const TextSpan(text: 'Dispatch note · '),
                TextSpan(
                  text: notes,
                  style: _uiStyle(
                    size: 12,
                    weight: FontWeight.w600,
                    color: _SlipPalette.ink,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Parts table — header strip (# / Part description / Customer P/N /
/// Quantity), one row per item, then a Total row with thick top border.
class _PartsTable extends StatelessWidget {
  final DplDispatchSlip slip;
  const _PartsTable({required this.slip});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PartsHeader(),
        for (var i = 0; i < slip.items.length; i++)
          _PartRow(
            index: i + 1,
            item: slip.items[i],
            fmt: fmt,
            isLast: i == slip.items.length - 1,
          ),
        _TotalRow(slip: slip, fmt: fmt),
      ],
    );
  }
}

class _PartsHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final headerStyle = _uiStyle(
      size: 10,
      weight: FontWeight.w700,
      color: _SlipPalette.faint,
      letterSpacing: 1.6,
    );
    return Container(
      decoration: const BoxDecoration(
        color: _SlipPalette.surface,
        border: Border(bottom: BorderSide(color: _SlipPalette.line)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 13, 24, 13),
      child: Row(
        children: [
          SizedBox(
            width: 46,
            child: Text('#', textAlign: TextAlign.center, style: headerStyle),
          ),
          Expanded(
            flex: 11,
            child: Text('PART DESCRIPTION', style: headerStyle),
          ),
          Expanded(flex: 6, child: Text('CUSTOMER P/N', style: headerStyle)),
          SizedBox(
            width: 130,
            child: Text(
              'QUANTITY',
              textAlign: TextAlign.right,
              style: headerStyle,
            ),
          ),
        ],
      ),
    );
  }
}

class _PartRow extends StatelessWidget {
  final int index;
  final DplDispatchSlipItem item;
  final NumberFormat fmt;
  final bool isLast;
  const _PartRow({
    required this.index,
    required this.item,
    required this.fmt,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final idxStr = index.toString().padLeft(2, '0');
    final partName = item.partName.trim().isNotEmpty
        ? item.partName
        : (item.description.trim().isNotEmpty
              ? item.description
              : item.partLabel);
    final hasSub =
        item.description.trim().isNotEmpty &&
        item.description.trim() != partName.trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 15, 24, 15),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isLast ? _SlipPalette.line : _SlipPalette.lineSoft,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 46,
            child: Text(
              idxStr,
              textAlign: TextAlign.center,
              style: _monoStyle(
                size: 12,
                weight: FontWeight.w500,
                color: _SlipPalette.faint,
              ),
            ),
          ),
          Expanded(
            flex: 11,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  partName,
                  style: _uiStyle(
                    size: 14.5,
                    weight: FontWeight.w600,
                    height: 1.25,
                    letterSpacing: 0.07,
                  ),
                ),
                if (hasSub) ...[
                  const SizedBox(height: 4),
                  Text(
                    item.description.trim(),
                    style: _monoStyle(
                      size: 11,
                      weight: FontWeight.w500,
                      color: _SlipPalette.brand,
                      letterSpacing: 0.22,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            flex: 6,
            child: Text(
              item.customerPartNo.isEmpty ? '-' : item.customerPartNo,
              style: _monoStyle(
                size: 13,
                weight: FontWeight.w500,
                color: const Color(0xFF3A3440),
              ),
            ),
          ),
          SizedBox(
            width: 130,
            child: RichText(
              textAlign: TextAlign.right,
              text: TextSpan(
                style: _displayStyle(
                  size: 21,
                  weight: FontWeight.w600,
                  color: _SlipPalette.ink,
                ),
                children: [
                  TextSpan(text: fmt.format(item.qty)),
                  TextSpan(
                    text: '  NOS',
                    style: _uiStyle(
                      size: 11,
                      weight: FontWeight.w600,
                      color: _SlipPalette.muted,
                      letterSpacing: 0.44,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  final DplDispatchSlip slip;
  final NumberFormat fmt;
  const _TotalRow({required this.slip, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final count = slip.items.length;
    return Container(
      decoration: const BoxDecoration(
        color: _SlipPalette.surface,
        border: Border(top: BorderSide(color: _SlipPalette.ink, width: 2)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: 46),
          Expanded(
            flex: 11,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'TOTAL DISPATCHED',
                  style: _displayStyle(
                    size: 18,
                    weight: FontWeight.w700,
                    letterSpacing: 2.52,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  count == 1
                      ? '1 line item · quantity verified at loading'
                      : '$count line items · all quantities verified at loading',
                  style: _uiStyle(
                    size: 11.5,
                    weight: FontWeight.w500,
                    color: _SlipPalette.muted,
                    letterSpacing: 0.23,
                  ),
                ),
              ],
            ),
          ),
          const Expanded(flex: 6, child: SizedBox()),
          SizedBox(
            width: 130,
            child: RichText(
              textAlign: TextAlign.right,
              text: TextSpan(
                style: _displayStyle(
                  size: 30,
                  weight: FontWeight.w700,
                  color: _SlipPalette.brand,
                ),
                children: [
                  TextSpan(text: fmt.format(slip.totalQty)),
                  TextSpan(
                    text: '  NOS',
                    style: _uiStyle(
                      size: 12,
                      weight: FontWeight.w600,
                      color: _SlipPalette.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// PDI sign-off strip — single checkpoint card spanning the full slip
/// width. The QA card was removed when the QA approval step was taken
/// out of the workflow; the `qa` widget construction stays commented
/// for easy re-enable.
class _SignoffStrip extends StatelessWidget {
  final DplDispatchSlip slip;
  const _SignoffStrip({required this.slip});

  @override
  Widget build(BuildContext context) {
    // QA checkpoint intentionally disabled — see file/header comment.
    // final qa = _Checkpoint(
    //   title: 'Quality Assurance · QA',
    //   description: 'Confirm part conformity and quantity before release.',
    //   state: slip.qaState,
    //   approver: slip.qaApproval,
    //   rejection: slip.rejection?.isQa == true ? slip.rejection : null,
    // );
    final pdi = _Checkpoint(
      title: 'Pre-Dispatch Inspection · PDI',
      description: 'Final loading check against this manifest.',
      state: slip.pdiState,
      approver: slip.pdiApproval,
      rejection: slip.rejection?.isPdi == true ? slip.rejection : null,
    );

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _SlipPalette.line)),
      ),
      child: pdi,
    );
  }
}

/// One QA/PDI checkpoint card. Pure presentation — the colour mapping
/// (amber/emerald/red) flows from [state] + [rejection].
class _Checkpoint extends StatelessWidget {
  final String title;
  final String description;
  final DispatchStationState state;
  final DplDispatchSlipActor? approver;
  final DplDispatchSlipRejection? rejection;
  const _Checkpoint({
    required this.title,
    required this.description,
    required this.state,
    required this.approver,
    required this.rejection,
  });

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd MMM · HH:mm');
    final palette = _paletteFor(state);
    return Container(
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: _SlipPalette.lineSoft)),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 4,
            child: Container(color: palette.bar),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TickBadge(palette: palette),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: _uiStyle(
                          size: 13,
                          weight: FontWeight.w700,
                          letterSpacing: 0.26,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: _uiStyle(
                          size: 11.5,
                          weight: FontWeight.w500,
                          color: _SlipPalette.muted,
                        ),
                      ),
                      const SizedBox(height: 11),
                      // Wrap (not LayoutBuilder) so this widget is
                      // safely measurable by the parent IntrinsicHeight
                      // in the wide signoff strip — LayoutBuilder
                      // doesn't support intrinsic sizing and blows up
                      // with "Cannot get intrinsic height" otherwise.
                      Wrap(
                        spacing: 14,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _Chip(label: _chipLabel(state), palette: palette),
                          _SignBlock(
                            state: state,
                            approver: approver,
                            rejection: rejection,
                            dateFmt: dateFmt,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _chipLabel(DispatchStationState s) {
    switch (s) {
      case DispatchStationState.approved:
        return 'Passed';
      case DispatchStationState.pending:
        return 'Pending';
      case DispatchStationState.rejected:
        return 'Rejected';
    }
  }

  static _CheckpointPalette _paletteFor(DispatchStationState s) {
    switch (s) {
      case DispatchStationState.approved:
        return const _CheckpointPalette(
          bar: _SlipPalette.emeraldLine,
          bg: _SlipPalette.emeraldBg,
          ink: _SlipPalette.emeraldInk,
          line: _SlipPalette.emeraldLine,
        );
      case DispatchStationState.rejected:
        return const _CheckpointPalette(
          bar: _SlipPalette.rejectedLine,
          bg: _SlipPalette.rejectedBg,
          ink: _SlipPalette.rejectedInk,
          line: _SlipPalette.rejectedLine,
        );
      case DispatchStationState.pending:
        return const _CheckpointPalette(
          bar: _SlipPalette.amberLine,
          bg: _SlipPalette.amberBg,
          ink: _SlipPalette.amberInk,
          line: _SlipPalette.amberLine,
        );
    }
  }
}

class _CheckpointPalette {
  final Color bar;
  final Color bg;
  final Color ink;
  final Color line;
  const _CheckpointPalette({
    required this.bar,
    required this.bg,
    required this.ink,
    required this.line,
  });
}

class _TickBadge extends StatelessWidget {
  final _CheckpointPalette palette;
  const _TickBadge({required this.palette});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.line),
      ),
      child: Icon(Icons.task_alt_outlined, size: 20, color: palette.ink),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final _CheckpointPalette palette;
  const _Chip({required this.label, required this.palette});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.line),
      ),
      child: Text(
        label.toUpperCase(),
        style: _uiStyle(
          size: 10.5,
          weight: FontWeight.w700,
          color: palette.ink,
          letterSpacing: 1.26,
        ),
      ),
    );
  }
}

/// Right side of the checkpoint row — either a signed name+time block
/// (approved/rejected) or a blank signature line (pending). Mirrors the
/// HTML `.signed` and `.signline` blocks.
class _SignBlock extends StatelessWidget {
  final DispatchStationState state;
  final DplDispatchSlipActor? approver;
  final DplDispatchSlipRejection? rejection;
  final DateFormat dateFmt;
  const _SignBlock({
    required this.state,
    required this.approver,
    required this.rejection,
    required this.dateFmt,
  });

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case DispatchStationState.approved:
        return _signed(
          name: (approver?.name.trim().isEmpty ?? true)
              ? '—'
              : approver!.name.trim(),
          at: approver?.at,
        );
      case DispatchStationState.rejected:
        return _signed(
          name: (rejection?.name.trim().isEmpty ?? true)
              ? '—'
              : rejection!.name.trim(),
          at: rejection?.at,
          reason: rejection?.reason,
        );
      case DispatchStationState.pending:
        // Bounded width — the pending signature line lives inside a
        // Wrap (parent _Checkpoint), so Column.stretch would receive
        // an unbounded width constraint and blow up layout. 220px is
        // wide enough to read as a real signature line on a tablet.
        return SizedBox(
          width: 220,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 18,
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: _SlipPalette.line)),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                'INSPECTOR SIGNATURE & TIME',
                style: _uiStyle(
                  size: 9.5,
                  weight: FontWeight.w700,
                  color: _SlipPalette.faint,
                  letterSpacing: 1.14,
                ),
              ),
            ],
          ),
        );
    }
  }

  Widget _signed({required String name, DateTime? at, String? reason}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(name, style: _uiStyle(size: 13, weight: FontWeight.w600)),
        if (at != null) ...[
          const SizedBox(height: 2),
          Text(
            '${dateFmt.format(at.toLocal())} IST',
            style: _uiStyle(
              size: 11,
              weight: FontWeight.w500,
              color: _SlipPalette.muted,
            ),
          ),
        ],
        if (reason != null && reason.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '"${reason.trim()}"',
            style: _uiStyle(
              size: 11,
              weight: FontWeight.w500,
              color: _SlipPalette.rejectedInk,
            ),
          ),
        ],
      ],
    );
  }
}

/// Verification panel — QR (or scan-gate placeholder) on the left,
/// "Slip contents · verification" label + 3-column kv grid + trust
/// banner on the right.
class _VerifySection extends StatelessWidget {
  final DplDispatchSlip slip;
  final bool hideQr;
  final VoidCallback? onScan;
  const _VerifySection({
    required this.slip,
    required this.hideQr,
    required this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _SlipPalette.surface,
        border: Border(top: BorderSide(color: _SlipPalette.line)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
      child: LayoutBuilder(
        builder: (context, c) {
          final compact = c.maxWidth < 560;
          final qr = _qrPanel();
          final meta = _meta(c.maxWidth);
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [qr, const SizedBox(height: 18), meta],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              qr,
              const SizedBox(width: 24),
              Expanded(child: meta),
            ],
          );
        },
      ),
    );
  }

  Widget _qrPanel() {
    final payload = slip.qrPayload;
    final hasQr = payload != null && payload.isNotEmpty;
    return Container(
      width: 128,
      height: 128,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _SlipPalette.line),
      ),
      child: hideQr
          ? _ScanGatePlaceholder(onScan: onScan)
          : hasQr
          ? QrImageView(
              data: payload,
              version: QrVersions.auto,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              gapless: true,
            )
          : Center(
              child: Text(
                'QR appears after PDI approval',
                textAlign: TextAlign.center,
                style: _uiStyle(
                  size: 10.5,
                  weight: FontWeight.w600,
                  color: _SlipPalette.muted,
                  height: 1.3,
                ),
              ),
            ),
    );
  }

  Widget _meta(double maxWidth) {
    final fmt = NumberFormat.decimalPattern();
    final cells = <_KvCell>[
      _KvCell('Slip no', slip.slipNo, mono: true),
      if (slip.invoiceNo.trim().isNotEmpty)
        _KvCell('Invoice no', slip.invoiceNo.trim(), mono: true),
      _KvCell('Plant', slip.plant.name.isEmpty ? '-' : slip.plant.name),
      _KvCell('Machine', _IdentityStrip._machineLabel(slip)),
      _KvCell('Vehicle', slip.vehicleNo.isEmpty ? '-' : slip.vehicleNo),
      _KvCell('Items', '${slip.items.length}'),
      _KvCell('Total qty', '${fmt.format(slip.totalQty)} NOS'),
      if (slip.notes.trim().isNotEmpty) _KvCell('Notes', slip.notes.trim()),
    ];

    final gridCols = maxWidth < 320 ? 1 : (maxWidth < 560 ? 2 : 3);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'SLIP CONTENTS · VERIFICATION',
          style: _uiStyle(
            size: 10,
            weight: FontWeight.w700,
            color: _SlipPalette.faint,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 10),
        _KvGrid(cells: cells, columns: gridCols),
        const SizedBox(height: 12),
        const _TrustBanner(),
      ],
    );
  }
}

class _KvCell {
  final String label;
  final String value;
  final bool mono;
  const _KvCell(this.label, this.value, {this.mono = false});
}

class _KvGrid extends StatelessWidget {
  final List<_KvCell> cells;
  final int columns;
  const _KvGrid({required this.cells, required this.columns});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += columns) {
      final row = <Widget>[];
      for (var j = 0; j < columns; j++) {
        final idx = i + j;
        if (idx < cells.length) {
          row.add(Expanded(child: _kv(cells[idx])));
        } else {
          row.add(const Expanded(child: SizedBox()));
        }
        if (j < columns - 1) row.add(const SizedBox(width: 28));
      }
      rows.add(
        Padding(
          padding: EdgeInsets.only(bottom: i + columns >= cells.length ? 0 : 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: row,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }

  Widget _kv(_KvCell c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          c.label.toUpperCase(),
          style: _uiStyle(
            size: 10.5,
            weight: FontWeight.w600,
            color: _SlipPalette.faint,
            letterSpacing: 0.53,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          c.value,
          style: c.mono
              ? _monoStyle(size: 12, weight: FontWeight.w500)
              : _uiStyle(size: 13, weight: FontWeight.w600),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _TrustBanner extends StatelessWidget {
  const _TrustBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      decoration: BoxDecoration(
        color: _SlipPalette.emeraldBg,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: _SlipPalette.emeraldLine),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(
            Icons.verified_user_outlined,
            size: 15,
            color: _SlipPalette.emeraldInk,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Scan to verify against the Vistar Pulse server. The code '
              'is HMAC-signed — tampered slips fail verification.',
              style: _uiStyle(
                size: 11.5,
                weight: FontWeight.w500,
                color: const Color(0xFF4F7A64),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Locked QR placeholder shown to QA/PDI before they've scanned the
/// printed slip. Replaces the QR image with a lock icon + a CTA so the
/// user can't read the QR off the screen and act on a slip they don't
/// physically have in front of them.
class _ScanGatePlaceholder extends StatelessWidget {
  final VoidCallback? onScan;
  const _ScanGatePlaceholder({this.onScan});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 24, color: _SlipPalette.muted),
          const SizedBox(height: 4),
          Text(
            'Scan to view',
            textAlign: TextAlign.center,
            style: _uiStyle(
              size: 10.5,
              weight: FontWeight.w700,
              color: _SlipPalette.muted,
              height: 1.2,
            ),
          ),
          if (onScan != null) ...[
            const SizedBox(height: 6),
            FilledButton(
              onPressed: onScan,
              style: FilledButton.styleFrom(
                backgroundColor: _SlipPalette.brand,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(
                'Scan QR',
                style: _uiStyle(
                  size: 11,
                  weight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Foot strip — slip ID on the left (mono) and a "Generated by Vistar
/// Pulse · Page 1 of 1" on the right.
class _SlipFoot extends StatelessWidget {
  final DplDispatchSlip slip;
  const _SlipFoot({required this.slip});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _SlipPalette.line)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 13, 24, 13),
      child: LayoutBuilder(
        builder: (context, c) {
          final id = Text(
            slip.slipNo,
            style: _monoStyle(
              size: 11,
              weight: FontWeight.w500,
              color: const Color(0xFF4F4A57),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
          final gen = Text(
            'Generated by Vistar Pulse · Page 1 of 1',
            style: _uiStyle(
              size: 11,
              weight: FontWeight.w500,
              color: _SlipPalette.muted,
              letterSpacing: 0.44,
            ),
          );
          if (c.maxWidth < 460) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [id, const SizedBox(height: 4), gen],
            );
          }
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(child: id),
              const SizedBox(width: 16),
              gen,
            ],
          );
        },
      ),
    );
  }
}

/// Compact timeline of who did what (created → QA → PDI → dispatched).
/// Helps QA/PDI confirm they're acting on the right slip before tapping
/// approve, and gives Dispatch a one-glance audit trail.
class _Timeline extends StatelessWidget {
  final DplDispatchSlip slip;
  const _Timeline({required this.slip});

  @override
  Widget build(BuildContext context) {
    final entries = <_TimelineEntry>[
      if (slip.requestedBy != null || slip.requestedAt != null)
        _TimelineEntry(
          icon: Icons.send_outlined,
          label: 'Requested by ${slip.requestedBy?.name ?? "-"}',
          at: slip.requestedAt,
        ),
      // QA timeline entry disabled — QA step removed from workflow.
      // if (slip.qaApproval != null)
      //   _TimelineEntry(
      //     icon: Icons.verified_outlined,
      //     label: 'QA approved by ${slip.qaApproval!.name}',
      //     at: slip.qaApproval!.at,
      //     remarks: slip.qaApproval!.remarks,
      //   ),
      if (slip.deoApproval != null)
        _TimelineEntry(
          icon: Icons.receipt_long_outlined,
          label: slip.invoiceNo.trim().isNotEmpty
              ? 'Invoice ${slip.invoiceNo.trim()} added by '
                  '${slip.deoApproval!.name}'
              : 'Sent for PDI by ${slip.deoApproval!.name}',
          at: slip.deoApproval!.at,
          remarks: slip.deoApproval!.remarks,
        ),
      if (slip.pdiApproval != null)
        _TimelineEntry(
          icon: Icons.check_circle_outline,
          label: 'PDI approved by ${slip.pdiApproval!.name}',
          at: slip.pdiApproval!.at,
          remarks: slip.pdiApproval!.remarks,
        ),
      if (slip.rejection != null)
        _TimelineEntry(
          icon: Icons.cancel_outlined,
          label:
              '${slip.rejection!.role.toUpperCase()} rejected by ${slip.rejection!.name}',
          at: slip.rejection!.at,
          remarks: slip.rejection!.reason,
          danger: true,
        ),
      if (slip.dispatchedAt != null)
        _TimelineEntry(
          icon: Icons.local_shipping_outlined,
          label: 'Dispatched by ${slip.dispatchedBy?.name ?? "-"}',
          at: slip.dispatchedAt,
        ),
    ];

    if (entries.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Activity', style: DplText.h3()),
          const SizedBox(height: 8),
          for (final e in entries) ...[
            _TimelineRow(entry: e),
            if (e != entries.last)
              Divider(height: 12, color: DplColors.divider),
          ],
        ],
      ),
    );
  }
}

class _TimelineEntry {
  final IconData icon;
  final String label;
  final DateTime? at;
  final String? remarks;
  final bool danger;
  const _TimelineEntry({
    required this.icon,
    required this.label,
    required this.at,
    this.remarks,
    this.danger = false,
  });
}

class _TimelineRow extends StatelessWidget {
  final _TimelineEntry entry;
  const _TimelineRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd MMM yyyy, HH:mm');
    final color = entry.danger ? DplColors.error : DplColors.primaryDark;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: entry.danger ? DplColors.errorBg : DplColors.primaryTint,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(entry.icon, size: 16, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.label,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              if (entry.at != null)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    dateFmt.format(entry.at!.toLocal()),
                    style: TextStyle(
                      color: DplColors.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 11.5,
                    ),
                  ),
                ),
              if (entry.remarks != null && entry.remarks!.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '"${entry.remarks!.trim()}"',
                    style: TextStyle(
                      color: entry.danger
                          ? DplColors.error
                          : DplColors.textSecondary,
                      fontStyle: FontStyle.italic,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Role-aware action bar at the bottom. Only the actions valid for the
/// user's role on the slip's current status are rendered — the rest are
/// hidden to keep the screen unambiguous.
///
/// **Scan-to-act gate**: when [requiresScan] is true and [scanVerified]
/// is false, the Approve/Reject pair is replaced by a single "Scan slip
/// QR" CTA. This enforces that pure QA/PDI users physically have the
/// printed paper before they can act. After a successful scan a small
/// "Verified" pill appears at the top of the card and the real
/// Approve/Reject row is revealed.
class _RoleActions extends ConsumerWidget {
  final DplDispatchSlip slip;
  final String role;
  final bool requiresScan;
  final bool scanVerified;
  final VoidCallback onScan;

  const _RoleActions({
    required this.slip,
    required this.role,
    required this.requiresScan,
    required this.scanVerified,
    required this.onScan,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // QA branch intentionally disabled — the QA approval step was
    // removed from the workflow, so we never surface QA buttons.
    // final isQa = AppConstants.isDplQaRole(role);
    final isPdi = AppConstants.isDplPdiRole(role);
    final isDispatch = AppConstants.isDplDispatchRole(role);

    // Manager is VIEW-ONLY on the Dispatch dashboard (reached via the
    // Production⇄Dispatch toggle): the old `|| isManager` override was
    // dropped so a manager can read slips but not PDI-approve/reject or
    // mark-dispatched. Approval/dispatch authority stays with the actual
    // PDI / Dispatch roles.
    final canPdiAct =
        isPdi && slip.status == DplDispatchSlipStatus.pendingPdi;
    final canDispatch =
        isDispatch && slip.status == DplDispatchSlipStatus.approved;

    if (!canPdiAct && !canDispatch) {
      return const SizedBox.shrink();
    }

    // PDI must scan first. Replace the Approve/Reject row with a
    // single "Scan slip QR" CTA until they do. Dispatch action is not
    // gated here (Dispatch has its own gate-scan flow).
    final gateApprovals = requiresScan && !scanVerified;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
        boxShadow: DplShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Actions', style: DplText.h3()),
              if (requiresScan && scanVerified) ...[
                const SizedBox(width: 8),
                const _VerifiedPill(),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (gateApprovals && canPdiAct)
            _ScanToActCta(slipNo: slip.slipNo, onScan: onScan)
          else ...[
            // QA approve/reject row intentionally disabled — see
            // top-of-method comment.
            // if (canQaAct)
            //   _ApprovalRow(
            //     approveAction: DispatchSlipApprovalAction.qaApprove,
            //     rejectAction: DispatchSlipApprovalAction.qaReject,
            //     slip: slip,
            //   ),
            if (canPdiAct)
              _ApprovalRow(
                approveAction: DispatchSlipApprovalAction.pdiApprove,
                rejectAction: DispatchSlipApprovalAction.pdiReject,
                slip: slip,
              ),
          ],
          if (canDispatch)
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => MarkDispatchedConfirmDialog.show(
                      context,
                      ref,
                      slip: slip,
                    ),
                    icon: const Icon(Icons.local_shipping_outlined),
                    label: const Text('Mark Dispatched'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Sits in place of Approve/Reject while a QA/PDI user hasn't yet
/// scanned the printed slip's QR. Explains *why* the actions are locked
/// so the user isn't left wondering where the buttons went.
class _ScanToActCta extends StatelessWidget {
  final String slipNo;
  final VoidCallback onScan;
  const _ScanToActCta({required this.slipNo, required this.onScan});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: DplColors.warningBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DplColors.warning),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.lock_outline, size: 18, color: DplColors.warning),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Scan the printed slip to unlock approval',
                  style: TextStyle(
                    color: DplColors.warning,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 26),
            child: Text(
              'Approve / Reject is hidden until the scanned QR matches '
              '$slipNo. This makes sure you have the paper slip in hand.',
              style: TextStyle(
                color: DplColors.textSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 11.5,
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: onScan,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('Scan slip QR'),
          ),
        ],
      ),
    );
  }
}

class _VerifiedPill extends StatelessWidget {
  const _VerifiedPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: DplColors.successBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: DplColors.success),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_outlined, size: 14, color: DplColors.success),
          SizedBox(width: 4),
          Text(
            'Verified',
            style: TextStyle(
              color: DplColors.success,
              fontWeight: FontWeight.w800,
              fontSize: 11,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalRow extends StatelessWidget {
  final DispatchSlipApprovalAction approveAction;
  final DispatchSlipApprovalAction rejectAction;
  final DplDispatchSlip slip;
  const _ApprovalRow({
    required this.approveAction,
    required this.rejectAction,
    required this.slip,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: DplColors.error,
              side: BorderSide(color: DplColors.error),
            ),
            onPressed: () => DispatchSlipActionSheet.show(
              context,
              slip: slip,
              action: rejectAction,
            ),
            icon: const Icon(Icons.cancel_outlined),
            label: const Text('Reject'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: FilledButton.icon(
            onPressed: () => DispatchSlipActionSheet.show(
              context,
              slip: slip,
              action: approveAction,
            ),
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Approve'),
          ),
        ),
      ],
    );
  }
}

/// Slim full-screen scanner that pops the first QR token it reads back
/// to the caller via `Navigator.pop(scannedString)`. Used by the
/// QA/PDI scan-to-act gate — no backend round-trip, the caller verifies
/// the scanned token against `slip.qrPayload` locally because the slip
/// payload itself already came from a trusted authenticated API call.
class _SlipScanGateScreen extends StatefulWidget {
  final String slipNo;
  const _SlipScanGateScreen({required this.slipNo});

  @override
  State<_SlipScanGateScreen> createState() => _SlipScanGateScreenState();
}

class _SlipScanGateScreenState extends State<_SlipScanGateScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final code = capture.barcodes
        .map((b) => b.rawValue?.trim() ?? '')
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (code.isEmpty) return;
    _handled = true;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: DplAppBar(
        title: 'Scan ${widget.slipNo}',
        actions: [
          IconButton(
            tooltip: 'Toggle torch',
            icon: const Icon(Icons.flash_on_outlined),
            onPressed: _controller.toggleTorch,
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (_, err, _) =>
                ScannerErrorView(error: err, onRetry: _controller.start),
          ),
          IgnorePointer(child: CustomPaint(painter: _ScanGateOverlayPainter())),
          Positioned(
            left: 0,
            right: 0,
            bottom: 32,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.qr_code_scanner_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Point the camera at the QR on ${widget.slipNo}.',
                        style: const TextStyle(
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
      ),
    );
  }
}

/// Soft scrim with a centred square cut-out + purple frame so the user
/// knows where to hold the slip. Mirrors the existing verifier overlay
/// look so the two scanners feel like the same product.
class _ScanGateOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final shorter = size.shortestSide;
    final box = shorter * 0.68;
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: box,
      height: box,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(20));

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
    const tickLen = 22.0;
    final r = rrect.outerRect;
    canvas
      ..drawLine(
        r.topLeft + const Offset(8, 8),
        r.topLeft + const Offset(8 + tickLen, 8),
        corner,
      )
      ..drawLine(
        r.topLeft + const Offset(8, 8),
        r.topLeft + const Offset(8, 8 + tickLen),
        corner,
      )
      ..drawLine(
        r.topRight + const Offset(-8, 8),
        r.topRight + const Offset(-8 - tickLen, 8),
        corner,
      )
      ..drawLine(
        r.topRight + const Offset(-8, 8),
        r.topRight + const Offset(-8, 8 + tickLen),
        corner,
      )
      ..drawLine(
        r.bottomLeft + const Offset(8, -8),
        r.bottomLeft + const Offset(8 + tickLen, -8),
        corner,
      )
      ..drawLine(
        r.bottomLeft + const Offset(8, -8),
        r.bottomLeft + const Offset(8, -8 - tickLen),
        corner,
      )
      ..drawLine(
        r.bottomRight + const Offset(-8, -8),
        r.bottomRight + const Offset(-8 - tickLen, -8),
        corner,
      )
      ..drawLine(
        r.bottomRight + const Offset(-8, -8),
        r.bottomRight + const Offset(-8, -8 - tickLen),
        corner,
      );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
