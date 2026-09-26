import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/vistar_palette.dart';
import '../../../auth/auth_provider.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_constants.dart';
import '../../core/dpl_organization_provider.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../journey/screens/consolidated_slip_screen.dart';
import '../../journey/widgets/trip_journey_drawer.dart';
import '../../models/dpl_dispatch_slip.dart';
import '../../tracking/screens/trip_track_map_screen.dart';
import '../providers/dispatch_slips_provider.dart';
import '../services/dispatch_slip_pdf.dart';
import '../widgets/dispatch_slip_status_badge.dart';
import 'dispatch_slip_detail_screen.dart';

/// Single-screen view of every slip cut from one manager-submitted
/// trip. Replaces the "scroll past N near-identical slip cards in the
/// inbox" UX with one card per trip → tap → this screen shows the
/// trip's slip stack in order, scrollable, with a single Print-all
/// action that produces one multi-page PDF (one A4-landscape page per
/// slip).
///
/// The slips are passed in from the inbox (the same snapshot the
/// inbox is showing). Tapping a slip pushes the existing
/// [DispatchSlipDetailScreen] so QA / PDI / Dispatch actions and the
/// scan-to-act flow are unchanged.
class TripSlipsScreen extends ConsumerStatefulWidget {
  final int? tripId;
  final int tripNumber;
  final String plantCode;
  final String plantName;
  final List<DplDispatchSlip> slips;

  const TripSlipsScreen({
    super.key,
    required this.tripId,
    required this.tripNumber,
    required this.plantCode,
    required this.plantName,
    required this.slips,
  });

  @override
  ConsumerState<TripSlipsScreen> createState() => _TripSlipsScreenState();
}

class _TripSlipsScreenState extends ConsumerState<TripSlipsScreen> {
  /// Guards the AppBar Email-all button so back-to-back taps can't fire
  /// N concurrent uploads. Rendering all PDFs + posting is sequential
  /// (one slip at a time) so SMTP throttling on the server stays sane.
  bool _emailing = false;

  /// Mutable working copy of the trip's slips. Starts as the snapshot
  /// the inbox passed in; replaced with the server's updated slips once
  /// the DEO sends a batch for PDI (so the invoice + new status render
  /// without a round-trip).
  late List<DplDispatchSlip> _slips;

  /// One invoice controller per pending_deo slip id — multi-batch, each
  /// slip the DEO forwards carries its OWN invoice. Created lazily and
  /// disposed together at teardown.
  final Map<int, TextEditingController> _invoiceCtrls = {};

  /// Optional DEO remarks applied to the whole batch.
  final TextEditingController _remarksCtrl = TextEditingController();

  /// Guards the DEO "Send for PDI" action against double taps.
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _slips = List.of(widget.slips);
  }

  @override
  void dispose() {
    for (final c in _invoiceCtrls.values) {
      c.dispose();
    }
    _remarksCtrl.dispose();
    super.dispose();
  }

  /// Lazily-created (and cached) invoice controller for one slip.
  TextEditingController _invoiceCtrlFor(int slipId) =>
      _invoiceCtrls.putIfAbsent(slipId, () => TextEditingController());

  /// The pending_deo slips the DEO has typed an invoice for — the batch
  /// "Send for PDI" will forward. Blank slips are excluded so the DEO can
  /// send a subset and leave the rest for a later batch.
  List<DeoSlipInvoice> _filledBatch() {
    final out = <DeoSlipInvoice>[];
    for (final s in _slips) {
      if (s.status != DplDispatchSlipStatus.pendingDeo) continue;
      final inv = _invoiceCtrls[s.id]?.text.trim() ?? '';
      if (inv.isNotEmpty) {
        out.add(DeoSlipInvoice(slipId: s.id, invoiceNo: inv));
      }
    }
    return out;
  }

  /// True when the current user is a Dispatch DEO and this trip still
  /// has at least one slip waiting in `pending_deo` — i.e. the DEO can
  /// stamp invoices and forward them.
  bool _deoCanAct(String role) =>
      AppConstants.isDplDeoRole(role) &&
      _slips.any((s) => s.status == DplDispatchSlipStatus.pendingDeo);

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final slips = _slips;
    final role = ref.watch(authControllerProvider).asData?.value?.role ?? '';
    final showDeoPanel = _deoCanAct(role);
    final totalQty =
        slips.fold<int>(0, (s, x) => s + x.totalQty);
    final plantLabel =
        widget.plantName.isNotEmpty ? widget.plantName : widget.plantCode;

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Trip #${widget.tripNumber}',
        actions: [
          // Post-dispatch actions — only surface once at least one slip
          // on this trip has been mark-dispatched (there is no trip-level
          // 'dispatched' status; the signal is on slip.status per recon).
          if (widget.tripId != null &&
              slips.any(
                  (s) => s.status == DplDispatchSlipStatus.dispatched)) ...[
            IconButton(
              tooltip: 'View trip journey',
              icon: const Icon(Icons.route_rounded),
              onPressed: () => showTripJourneyDrawer(
                context,
                tripId: widget.tripId!,
                tripNumber: widget.tripNumber,
                plantName: widget.plantName,
                vehicleNo: slips.isNotEmpty ? slips.first.vehicleNo : null,
              ),
            ),
            IconButton(
              tooltip: 'Consolidated slip',
              icon: const Icon(Icons.qr_code_2_rounded),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      ConsolidatedSlipScreen(tripId: widget.tripId!),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Track location',
              icon: const Icon(Icons.location_on_rounded),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TripTrackMapScreen(
                    tripId: widget.tripId!,
                    tripNumber: widget.tripNumber,
                    plantName: widget.plantName,
                    vehicleNo:
                        slips.isNotEmpty ? slips.first.vehicleNo : null,
                  ),
                ),
              ),
            ),
          ],
          IconButton(
            tooltip: _emailing
                ? 'Emailing trip PDF…'
                : slips.length == 1
                    ? 'Email slip'
                    : 'Email all ${slips.length} slips as one PDF',
            icon: _emailing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.mail_outline_rounded),
            onPressed: (slips.isEmpty || _emailing || _sending)
                ? null
                : () => _emailAll(context),
          ),
          IconButton(
            tooltip: 'Print all (${slips.length}-page PDF)',
            icon: const Icon(Icons.print_outlined),
            onPressed: (slips.isEmpty || _sending)
                ? null
                : () => _printAll(context),
          ),
        ],
      ),
      body: Column(
        children: [
          if (showDeoPanel) _buildDeoPanel(),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: slips.length + 1,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                if (i == 0) {
                  return _TripSummaryCard(
                    tripNumber: widget.tripNumber,
                    plantLabel: plantLabel,
                    slipCount: slips.length,
                    totalQty: totalQty,
                    fmt: fmt,
                  );
                }
                final slip = slips[i - 1];
                final deoEditable = showDeoPanel &&
                    slip.status == DplDispatchSlipStatus.pendingDeo;
                return _SlipDetailTile(
                  slip: slip,
                  index: i,
                  total: slips.length,
                  fmt: fmt,
                  invoiceController:
                      deoEditable ? _invoiceCtrlFor(slip.id) : null,
                  onInvoiceChanged:
                      deoEditable ? (_) => setState(() {}) : null,
                  invoiceEnabled: !_sending,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// DEO action card pinned above the slip list. Each pending_deo slip
  /// gets its own invoice field down in the list (multi-batch); this card
  /// carries the progress count, an optional remarks note, and the Send
  /// button. "Send" forwards only the slips that have an invoice typed —
  /// blank ones stay in the DEO queue for a later batch.
  Widget _buildDeoPanel() {
    final total = _slips
        .where((s) => s.status == DplDispatchSlipStatus.pendingDeo)
        .length;
    final filled = _filledBatch().length;
    final allFilled = filled == total;
    final canSend = !_sending && filled > 0;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.primary),
        boxShadow: DplShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.receipt_long_outlined,
                  size: 18, color: DplColors.primaryDark),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Add invoices & send for PDI',
                  style: DplText.h3(),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: allFilled
                      ? DplColors.successBg
                      : DplColors.warningBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$filled / $total invoiced',
                  style: TextStyle(
                    color: allFilled ? DplColors.success : DplColors.warning,
                    fontWeight: FontWeight.w800,
                    fontSize: 10.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Enter an invoice no for each slip below, then send. Each slip '
            'keeps its own invoice; slips left blank stay in the DEO queue '
            'for a later batch.',
            style: TextStyle(
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 11.5,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _remarksCtrl,
            maxLength: 200,
            maxLines: 1,
            enabled: !_sending,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.notes_outlined, size: 18),
              labelText: 'Remarks (optional)',
              counterText: '',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: canSend ? () => _sendForPdi() : null,
            icon: _sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send_rounded, size: 18),
            label: Text(
              _sending
                  ? 'Sending…'
                  : filled > 0
                      ? 'Send $filled for PDI'
                      : 'Send for PDI',
            ),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// Forwards the DEO's filled batch — each pending_deo slip with an
  /// invoice typed — to PDI: stamps the per-slip invoices, transitions
  /// those slips to `pending_pdi`, then emails the batch PDF to PDI.
  /// Stays on the trip (the panel hides once nothing is left in
  /// pending_deo) so the DEO can forward another batch later.
  Future<void> _sendForPdi() async {
    final tripId = widget.tripId;
    if (tripId == null) {
      DplSnacks.error(
        context,
        'This trip has no id on record, so it cannot be forwarded.',
      );
      return;
    }
    final batch = _filledBatch();
    if (batch.isEmpty) {
      DplSnacks.error(
        context,
        'Enter an invoice no for at least one slip before sending.',
      );
      return;
    }
    final batchIds = {for (final b in batch) b.slipId};
    final remarks = _remarksCtrl.text.trim();

    setState(() => _sending = true);
    final api = ref.read(dplApiServiceProvider);
    final res = await api.sendTripForPdi(
      tripId,
      slipInvoices: batch,
      remarks: remarks.isEmpty ? null : remarks,
    );
    if (!mounted) return;

    if (res.isError) {
      setState(() => _sending = false);
      final code = (res.code ?? '').toUpperCase();
      // NO_PENDING_SLIPS: the trip's DEO queue is already drained. Mark
      // the local pending_deo slips forwarded so the panel hides, refresh
      // the queue, and stay.
      if (code == 'NO_PENDING_SLIPS') {
        ref.invalidate(dplDispatchSlipsProvider);
        setState(() {
          _slips = [
            for (final s in _slips)
              s.status == DplDispatchSlipStatus.pendingDeo
                  ? s.copyWith(status: DplDispatchSlipStatus.pendingPdi)
                  : s,
          ];
        });
        DplSnacks.warning(
          context,
          'All slips on this trip have already been sent for PDI.',
        );
        return;
      }
      // INVALID_STATUS: a listed slip changed status under us (another
      // DEO moved it). Refresh the queue and ask the DEO to reopen with
      // fresh state before re-sending.
      if (code == 'INVALID_STATUS') {
        ref.invalidate(dplDispatchSlipsProvider);
        DplSnacks.warning(
          context,
          res.error ??
              'A slip changed status — refresh and re-select before sending.',
        );
        return;
      }
      // VALIDATION_ERROR (or anything else) — surface verbatim and stay so
      // the DEO can fix the input.
      DplSnacks.error(context, res.error ?? 'Send for PDI failed.');
      return;
    }

    // Merge the server's updated slips (this batch, now pending_pdi with
    // their own invoice) into the on-screen list BY ID, preserving slips
    // forwarded in earlier batches. If the backend didn't echo them, stamp
    // each slip's own invoice + forwarded status locally so the emailed
    // PDF is still correct.
    final updated = res.data ?? const <DplDispatchSlip>[];
    if (updated.isNotEmpty) {
      final byId = {for (final s in updated) s.id: s};
      setState(() {
        _slips = [
          for (final s in _slips) byId[s.id] ?? s,
          for (final s in updated)
            if (!_slips.any((x) => x.id == s.id)) s,
        ];
      });
    } else {
      final invById = {for (final b in batch) b.slipId: b.invoiceNo};
      setState(() {
        _slips = [
          for (final s in _slips)
            invById.containsKey(s.id)
                ? s.copyWith(
                    invoiceNo: invById[s.id],
                    status: DplDispatchSlipStatus.pendingPdi,
                  )
                : s,
        ];
      });
    }

    // Email JUST this batch (the slips just forwarded, by id) — earlier
    // batches were already emailed. Recipient is server-side config (PDI).
    final batchSlips = _slips.where((s) => batchIds.contains(s.id)).toList();
    final emailResp = await _renderAndEmail(
      batchSlips.isNotEmpty ? batchSlips : _slips,
    );

    // Guard BEFORE touching `ref` — if the screen was popped mid-email the
    // State is disposed and `ref.invalidate` would throw a StateError.
    if (!mounted) return;
    // Refresh the inbox so the forwarded slips leave the DEO queue.
    ref.invalidate(dplDispatchSlipsProvider);
    _remarksCtrl.clear();
    setState(() => _sending = false);

    final emailData = emailResp?.data;
    final mailNote = emailResp == null
        ? ' (PDF email could not be rendered)'
        : emailResp.isError
            ? ' (email failed: ${emailResp.error ?? "unknown error"})'
            : emailData == null
                ? ''
                : emailData.sent
                    ? ' · emailed to PDI'
                    : emailData.skipped
                        ? ' · email skipped (SMTP not configured)'
                        : ' · email not sent';
    // Stay on the trip (no auto-navigate) — the DEO may forward another
    // batch. The panel auto-hides once no pending_deo slips remain.
    DplSnacks.success(
      context,
      'Batch of ${batch.length} slip${batch.length == 1 ? "" : "s"} '
      'sent for PDI$mailNote.',
    );
  }

  /// Builds a multi-page PDF — one page per slip in the trip's current
  /// slips — and hands it to the OS print sheet via the `printing`
  /// plugin. Same error surface as the single-slip print path on the
  /// detail screen.
  Future<void> _printAll(BuildContext context) async {
    final orgLabel = ref.read(dplActiveOrganizationProvider)?.displayLabel;
    final name = 'Trip-${widget.tripNumber}-'
        '${widget.plantCode.isEmpty ? "slips" : widget.plantCode}';

    try {
      await Printing.layoutPdf(
        name: name,
        onLayout: (_) => DispatchSlipPdfBuilder.buildBatch(
          _slips,
          organizationLabel: orgLabel,
        ),
      );
    } on MissingPluginException {
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

  /// Renders ALL slips into ONE multi-page PDF (via [buildBatch]) and
  /// POSTs it as a single multipart upload — so Dispatch receives a
  /// single email with a single PDF attachment regardless of how many
  /// slips the trip has, instead of N emails.
  ///
  /// **Endpoint quirk**: the email endpoint is keyed by slip id
  /// (`/dispatch/slips/:id/email`). With no trip-level endpoint
  /// available we aim the single POST at the FIRST slip's id and rely
  /// on `subject_suffix=Trip #N (N slips)` to mark it as a batch in
  /// the recipient inbox. We also pass `slip_ids` (every slip in the
  /// trip) so the server can build the email details table from the
  /// whole stack once it reads that field; until then the body still
  /// references only the anchor slip — see "Backend ask" in the PR
  /// description for the clean fix (a trip-level email endpoint).
  Future<void> _emailAll(BuildContext context) async {
    if (_slips.isEmpty) return;

    setState(() => _emailing = true);
    final res = await _renderAndEmail(_slips);
    if (!context.mounted) return;
    setState(() => _emailing = false);

    if (res == null) {
      DplSnacks.error(context, 'Could not render trip PDF for email.');
      return;
    }
    if (res.isError) {
      DplSnacks.error(
        context,
        'Email failed: ${res.error ?? "unknown error"}',
      );
      return;
    }

    final data = res.data;
    if (data == null) {
      DplSnacks.error(context, 'Email response was empty.');
      return;
    }
    if (data.sent) {
      final toLabel = data.to.isNotEmpty ? data.to.first : 'the recipient';
      DplSnacks.success(
        context,
        _slips.length == 1
            ? 'Slip emailed to $toLabel.'
            : '${_slips.length} slips emailed to $toLabel in one PDF.',
      );
    } else if (data.skipped) {
      DplSnacks.warning(
        context,
        'Trip not emailed — SMTP is not configured on this deploy.',
      );
    } else {
      DplSnacks.error(
        context,
        'Email not sent: ${data.reason ?? "unknown reason"}',
      );
    }
  }

  /// Renders [slips] into ONE multi-page PDF (via [buildBatch]) and POSTs
  /// it as a single multipart upload so the recipient gets one email with
  /// one PDF regardless of slip count. Returns the API response, or `null`
  /// if the PDF couldn't be rendered. Recipients are server-side config.
  ///
  /// **Endpoint quirk**: the email endpoint is keyed by slip id
  /// (`/dispatch/slips/:id/email`). With no trip-level endpoint we aim the
  /// single POST at the FIRST slip's id and pass `slip_ids` (every slip in
  /// the trip) + `subject_suffix=Trip #N` so the server can build the
  /// details table from the whole stack.
  Future<DplApiResponse<DplDispatchSlipEmailResult>?> _renderAndEmail(
    List<DplDispatchSlip> slips,
  ) async {
    if (slips.isEmpty) return null;
    final orgLabel = ref.read(dplActiveOrganizationProvider)?.displayLabel;
    final api = ref.read(dplApiServiceProvider);
    final anchor = slips.first;
    final suffix = slips.length == 1
        ? 'Trip #${widget.tripNumber}'
        : 'Trip #${widget.tripNumber} (${slips.length} slips)';
    final filename = slips.length == 1
        ? '${anchor.slipNo}.pdf'
        : 'Trip-${widget.tripNumber}-'
            '${widget.plantCode.isEmpty ? "slips" : widget.plantCode}.pdf';

    Uint8List bytes;
    try {
      bytes = await DispatchSlipPdfBuilder.buildBatch(
        slips,
        organizationLabel: orgLabel,
      );
    } catch (_) {
      return null;
    }

    return api.sendDispatchSlipEmail(
      anchor.id,
      pdfBytes: bytes,
      filename: filename,
      subjectSuffix: suffix,
      slipIds: slips.map((s) => s.id).toList(),
    );
  }
}

/// Trip-header card: rolled-up totals for the slips visible in the
/// list below. Kept compact — the per-slip tiles carry the detail.
class _TripSummaryCard extends StatelessWidget {
  final int tripNumber;
  final String plantLabel;
  final int slipCount;
  final int totalQty;
  final NumberFormat fmt;

  const _TripSummaryCard({
    required this.tripNumber,
    required this.plantLabel,
    required this.slipCount,
    required this.totalQty,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: VistarPalette.heroGradient,
        borderRadius: BorderRadius.circular(14),
        boxShadow: DplShadows.card,
      ),
      child: Row(
        children: [
          const Icon(Icons.local_shipping_rounded,
              color: Colors.white, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Trip #$tripNumber',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  plantLabel,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$slipCount slip${slipCount == 1 ? "" : "s"}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${fmt.format(totalQty)} NOS',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One slip rendered inline. Shows everything the inbox card surfaced
/// (slip no, machine, part, qty, status, requester + timestamp) plus
/// the vehicle no and a sign-off strip so the user can scroll through
/// the trip's slips end-to-end without opening each one. Tap → push
/// the existing [DispatchSlipDetailScreen] for the printable surface,
/// QR scan, and role actions.
class _SlipDetailTile extends StatelessWidget {
  final DplDispatchSlip slip;
  final int index;
  final int total;
  final NumberFormat fmt;

  /// When non-null, the DEO is acting on this (pending_deo) slip — the
  /// tile renders an editable per-slip invoice field wired to this
  /// controller. Null for every other slip/role, which instead shows the
  /// stamped invoice read-only (when present).
  final TextEditingController? invoiceController;
  final ValueChanged<String>? onInvoiceChanged;
  final bool invoiceEnabled;

  const _SlipDetailTile({
    required this.slip,
    required this.index,
    required this.total,
    required this.fmt,
    this.invoiceController,
    this.onInvoiceChanged,
    this.invoiceEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd MMM yyyy, HH:mm');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DispatchSlipDetailScreen(slipId: slip.id),
          ),
        ),
        child: Ink(
          decoration: BoxDecoration(
            color: DplColors.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: DplColors.divider),
            boxShadow: DplShadows.card,
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: DplColors.primaryTint,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$index of $total',
                      style: TextStyle(
                        color: DplColors.primaryDark,
                        fontWeight: FontWeight.w800,
                        fontSize: 10.5,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      slip.slipNo,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                        letterSpacing: 0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  DispatchSlipStatusBadge(status: slip.status, dense: true),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                // Single-item slips read "machine • description • Qty N"
                // (the part-description code inline). Multi-item slips keep
                // the compact "machine • N items • NOS" summary.
                slip.isSingleItem
                    ? (slip.description.trim().isEmpty
                        ? '${slip.machineLabel} • Qty ${fmt.format(slip.qty)}'
                        : '${slip.machineLabel} • ${slip.description.trim()} '
                            '• Qty ${fmt.format(slip.qty)}')
                    : '${slip.machineLabel} • ${slip.items.length} items '
                        '• ${fmt.format(slip.totalQty)} NOS',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),

              const SizedBox(height: 2),
              Text(
                slip.partLabel,
                style: TextStyle(
                  color: DplColors.textSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (slip.vehicleNo.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.local_shipping_outlined,
                        size: 13, color: DplColors.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      slip.vehicleNo,
                      style: TextStyle(
                        color: DplColors.textSecondary,
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ],
              // Per-slip invoice. The DEO gets an editable field on
              // pending_deo slips; everyone else (and forwarded slips)
              // sees the stamped invoice read-only.
              if (invoiceController != null) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: invoiceController,
                  enabled: invoiceEnabled,
                  textCapitalization: TextCapitalization.characters,
                  maxLength: 64,
                  onChanged: onInvoiceChanged,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.tag_rounded, size: 16),
                    labelText: 'Invoice no for this slip *',
                    counterText: '',
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ] else if (slip.invoiceNo.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.receipt_long_outlined,
                        size: 13, color: DplColors.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      'Invoice ${slip.invoiceNo.trim()}',
                      style: TextStyle(
                        color: DplColors.textSecondary,
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              _SignOffStrip(slip: slip),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.person_outline,
                      size: 13, color: DplColors.textSecondary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      slip.requestedBy?.name ?? '-',
                      style: TextStyle(
                        color: DplColors.textSecondary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (slip.requestedAt != null)
                    Text(
                      dateFmt.format(slip.requestedAt!.toLocal()),
                      style: TextStyle(
                        color: DplColors.textSecondary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact three-step QA / PDI / Dispatched strip — visually mirrors
/// the printable slip's sign-off row so the user can see at a glance
/// where each slip is in the pipeline without opening it.
class _SignOffStrip extends StatelessWidget {
  final DplDispatchSlip slip;
  const _SignOffStrip({required this.slip});

  @override
  Widget build(BuildContext context) {
    final isRejected = slip.status == DplDispatchSlipStatus.rejected;
    return Row(
      children: [
        Expanded(
          child: _Step(
            label: 'DEO',
            done: slip.deoApproval != null ||
                slip.invoiceNo.trim().isNotEmpty,
            rejected: false,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _Step(
            label: 'PDI',
            done: slip.pdiApproval != null,
            rejected: isRejected && (slip.rejection?.isPdi ?? false),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _Step(
            label: 'Dispatched',
            done: slip.dispatchedAt != null,
            rejected: false,
          ),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  final String label;
  final bool done;
  final bool rejected;
  const _Step({
    required this.label,
    required this.done,
    required this.rejected,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final IconData icon;
    if (rejected) {
      bg = DplColors.errorBg;
      fg = DplColors.error;
      icon = Icons.close_rounded;
    } else if (done) {
      bg = DplColors.successBg;
      fg = DplColors.success;
      icon = Icons.check_rounded;
    } else {
      bg = DplColors.neutralBg;
      fg = DplColors.textSecondary;
      icon = Icons.radio_button_unchecked;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: fg,
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
