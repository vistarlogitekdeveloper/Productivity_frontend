import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_pallet_audit.dart';
import '../../qa/screens/dpl_qr_scan_sheet.dart';

/// Checking one pallet, wheel by wheel.
///
/// The auditor has already scanned the pallet label; this screen holds the
/// running audit. It lists what the system says is on the pallet, ticks each
/// wheel off as it is scanned, and collects anything that turns up which does
/// not belong.
///
/// THE VERDICT IS A SET COMPARISON, NOT A COUNT. Ten scans against an expected
/// ten passes a counter and hides two wheels missing and two from another
/// pallet — which is the exact case this screen exists for. So Approve is
/// enabled only when nothing is outstanding and nothing is foreign, and the
/// server recomputes the same thing and refuses a client that claims otherwise.
///
/// The scan field stays focused and takes hardware-trigger decodes the same
/// way the QA pallet screen does. The camera is behind a button, never opened
/// on its own — an auditor walking a rack with a ring scanner does not want a
/// viewfinder over the list they are reading.
class DplPalletAuditScreen extends ConsumerStatefulWidget {
  const DplPalletAuditScreen({super.key, required this.session});

  /// The audit as the server handed it back from `POST /warehouse/audits` —
  /// already started, and already carrying any scans from an earlier attempt
  /// that was interrupted.
  final DplPalletAuditSession session;

  @override
  ConsumerState<DplPalletAuditScreen> createState() =>
      _DplPalletAuditScreenState();
}

class _DplPalletAuditScreenState extends ConsumerState<DplPalletAuditScreen> {
  final _scanCtrl = TextEditingController();
  final _scanFocus = FocusNode();

  late DplPalletAuditSession _s;
  bool _busy = false;

  /// Serialised, for the same reason the QA pallet screen serialises: a
  /// hardware trigger fires far faster than a round trip, and several scans in
  /// flight together each decide against a list that is already stale.
  Future<void> _queue = Future<void>.value();
  int _queued = 0;

  @override
  void initState() {
    super.initState();
    _s = widget.session;
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  int get _expected => _s.wheels.length;
  int get _matched => _s.matchedCount;
  List<DplAuditWheel> get _outstanding => _s.notYetScanned;
  List<DplPalletAuditLine> get _foreign => _s.foreign;

  /// Everything accounted for and nothing extra. The server checks this again.
  bool get _clean => _outstanding.isEmpty && _foreign.isEmpty;

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  Future<void> _refresh() async {
    final res = await ref.read(dplApiServiceProvider).getPalletAudit(_s.audit.id);
    if (!mounted) return;
    if (res.isOk && res.data != null) setState(() => _s = res.data!);
  }

  Future<void> _scan(String code) {
    final value = code.trim();
    _scanCtrl.clear();
    _scanFocus.requestFocus();
    if (value.isEmpty) return Future.value();

    setState(() => _queued += 1);
    _queue = _queue
        .then((_) => _sendScan(value))
        .catchError((_) {})
        .whenComplete(() {
          _queued -= 1;
          if (mounted) setState(() {});
        });
    return _queue;
  }

  Future<void> _sendScan(String value) async {
    final res = await ref.read(dplApiServiceProvider).scanWheelForAudit(
          auditId: _s.audit.id,
          code: value,
        );
    if (!mounted) return;

    if (res.isError) {
      HapticFeedback.heavyImpact();
      DplSnacks.error(
        context,
        res.floorMessage.isEmpty ? 'That scan was refused.' : res.floorMessage,
      );
      return;
    }

    final out = res.data!;
    if (out.duplicate) {
      // Not an error. The trigger fires faster than a round trip, so a repeat
      // is the scanner's doing — saying "already scanned" is information, not
      // a telling-off.
      HapticFeedback.selectionClick();
      DplSnacks.info(context, '$value was already scanned.');
      return;
    }

    if (out.line.isForeign) {
      // Worth a strong signal: this is the finding, not a mis-scan.
      HapticFeedback.heavyImpact();
      DplSnacks.warning(
        context,
        out.line.foundOnPalletId == null
            ? '$value does not belong to this pallet.'
            : '$value belongs to another pallet.',
      );
    } else {
      HapticFeedback.selectionClick();
    }

    await _refresh();
  }

  Future<void> _scanWithCamera() async {
    final code = await DplQrScanSheet.open(
      context,
      expecting: 'Scan a wheel on this pallet',
    );
    if (code == null || !mounted) return;
    await _scan(code);
  }

  Future<void> _undo(DplPalletAuditLine line) async {
    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).undoAuditScan(
          auditId: _s.audit.id,
          lineId: line.id,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.isError) {
      DplSnacks.error(context, res.floorMessage.isEmpty ? 'Failed to undo.' : res.floorMessage);
      return;
    }
    await _refresh();
  }

  // ---------------------------------------------------------------------------
  // The verdict
  // ---------------------------------------------------------------------------

  Future<void> _approve() async {
    // Belt and braces: the button is disabled unless clean, and the server
    // recomputes it anyway. This catches a scan landing between the tap and
    // here.
    if (!_clean) {
      DplSnacks.warning(context, 'Something is still outstanding — check the list.');
      return;
    }
    await _decide(approve: true, reason: null);
  }

  Future<void> _reject() async {
    final reason = await _askReason();
    if (reason == null || !mounted) return;
    await _decide(approve: false, reason: reason);
  }

  /// The reason is compulsory, and the server refuses a blank one too.
  ///
  /// Whoever picks this pallet up next has only this sentence to go on, so the
  /// dialog will not close on an empty field rather than accepting one and
  /// leaving them a rejection that says nothing.
  Future<String?> _askReason() async {
    final ctrl = TextEditingController(text: _suggestedReason());
    String? error;

    final out = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Reject this pallet'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Say what is wrong. Whoever picks the pallet up next has only '
                'this to go on.',
                style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 3,
                maxLength: 1000,
                decoration: InputDecoration(
                  labelText: 'Reason',
                  errorText: error,
                  isDense: true,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Keep checking'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: DplColors.error),
              onPressed: () {
                final v = ctrl.text.trim();
                if (v.isEmpty) {
                  setLocal(() => error = 'A reason is required.');
                  return;
                }
                Navigator.of(ctx).pop(v);
              },
              child: const Text('Reject'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    return out;
  }

  /// Pre-fills what the screen already knows, so the auditor edits a sentence
  /// rather than composing one on a handheld keyboard at a rack.
  String _suggestedReason() {
    final missing = _outstanding.length;
    final extra = _foreign.length;
    if (missing == 0 && extra == 0) return '';
    final parts = <String>[];
    if (missing > 0) {
      parts.add('$missing wheel${missing == 1 ? '' : 's'} not found');
    }
    if (extra > 0) {
      parts.add('$extra from another pallet');
    }
    return parts.join(', ');
  }

  Future<void> _decide({required bool approve, String? reason}) async {
    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).decidePalletAudit(
          auditId: _s.audit.id,
          approve: approve,
          reason: reason,
        );
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError) {
      // AUDIT_NOT_CLEAN and REASON_REQUIRED both name the situation already.
      DplSnacks.error(
        context,
        res.floorMessage.isEmpty ? 'Failed to record the verdict.' : res.floorMessage,
      );
      return;
    }

    setState(() => _s = res.data!);
    HapticFeedback.mediumImpact();
    if (approve) {
      DplSnacks.success(context, '${_palletNo()} approved.');
    } else {
      DplSnacks.warning(context, '${_palletNo()} rejected.');
    }
    Navigator.of(context).pop(true);
  }

  String _palletNo() => _s.pallet?.palletNo ?? 'This pallet';

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final canCamera =
        ref.watch(dplPermissionsProvider).can(DplPermission.palletScanCamera);

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: AppBar(title: Text(_palletNo())),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
        children: [
          _headerCard(),
          const SizedBox(height: 12),
          _scanCard(canCamera),
          const SizedBox(height: 12),
          if (_foreign.isNotEmpty) ...[
            _foreignCard(),
            const SizedBox(height: 12),
          ],
          _wheelsCard(),
          const SizedBox(height: 12),
          _verdictCard(),
        ],
      ),
    );
  }

  Widget _headerCard() {
    final p = _s.pallet;
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  p?.palletNo ?? '—',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                ),
              ),
              _counter(),
            ],
          ),
          if ((p?.customerPartNo ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '${p!.customerPartNo}'
              '${p.partDescription.isEmpty ? '' : ' · ${p.partDescription}'}',
              style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _counter() {
    final done = _matched;
    final colour = _clean
        ? DplColors.success
        : (_foreign.isNotEmpty ? DplColors.error : DplColors.textSecondary);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(DplRadius.pill),
      ),
      child: Text(
        '$done / $_expected',
        style: TextStyle(fontWeight: FontWeight.w800, color: colour, fontSize: 15),
      ),
    );
  }

  Widget _scanCard(bool canCamera) {
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Scan each wheel',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _scanCtrl,
                  focusNode: _scanFocus,
                  enabled: !_busy && _s.audit.isOpen,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: 'Wheel label',
                    isDense: true,
                  ),
                  onSubmitted: _scan,
                ),
              ),
              if (canCamera) ...[
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: (_busy || !_s.audit.isOpen) ? null : _scanWithCamera,
                  icon: const Icon(Icons.qr_code_scanner),
                  tooltip: 'Use the camera',
                ),
              ],
            ],
          ),
          if (_queued > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Sending $_queued…',
              style: TextStyle(fontSize: 11.5, color: DplColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  /// Wheels that turned up and do not belong. Shown ABOVE the expected list,
  /// because it is the finding — burying it under thirty ticked rows is how an
  /// auditor approves a pallet they should not have.
  Widget _foreignCard() {
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 18, color: DplColors.error),
              const SizedBox(width: 8),
              Text(
                '${_foreign.length} not from this pallet',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  color: DplColors.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final l in _foreign)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.serialNo,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          l.foundOnPalletId == null
                              // No row anywhere for it. Either a label from
                              // another system, or one that was never issued.
                              ? 'Not a label this system printed'
                              : 'Belongs to pallet #${l.foundOnPalletId}',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: DplColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_s.audit.isOpen)
                    TextButton(
                      onPressed: _busy ? null : () => _undo(l),
                      child: const Text('Undo'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _wheelsCard() {
    final done = _s.scannedKeys;
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'On this pallet',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
              if (_outstanding.isNotEmpty)
                Text(
                  '${_outstanding.length} to find',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: DplColors.warning,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (_s.wheels.isEmpty)
            Text(
              'The system says there is nothing on this pallet.',
              style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
            ),
          for (final w in _s.wheels)
            _wheelRow(w, done.contains(w.serialNo.trim().toUpperCase())),
        ],
      ),
    );
  }

  Widget _wheelRow(DplAuditWheel w, bool scanned) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            scanned ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 18,
            color: scanned ? DplColors.success : DplColors.textTertiary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  w.serialNo,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: scanned ? FontWeight.w600 : FontWeight.w700,
                    color: scanned ? DplColors.textSecondary : DplColors.textPrimary,
                    decoration: scanned ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (w.isExternal)
                  Text(
                    // Says the code came off a supplier label, so an auditor
                    // who cannot find it in our numbering knows why.
                    'Supplier label',
                    style: TextStyle(fontSize: 11, color: DplColors.textSecondary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _verdictCard() {
    if (!_s.audit.isOpen) {
      return DplCard(
        child: Row(
          children: [
            Icon(
              _s.audit.isApproved ? Icons.verified : Icons.report_problem_outlined,
              color: _s.audit.isApproved ? DplColors.success : DplColors.error,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _s.audit.isApproved
                    ? 'Approved.'
                    : 'Rejected — ${_s.audit.reason ?? ''}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
    }

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _clean
                ? 'Everything on this pallet is accounted for.'
                : [
                    if (_outstanding.isNotEmpty)
                      '${_outstanding.length} still to find',
                    if (_foreign.isNotEmpty)
                      '${_foreign.length} not from this pallet',
                  ].join(' · '),
            style: TextStyle(
              fontSize: 12.5,
              color: _clean ? DplColors.success : DplColors.warning,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _reject,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('Reject'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: DplColors.error,
                    minimumSize: const Size.fromHeight(46),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  // Disabled rather than hidden, so an auditor looking for it
                  // can see it is there and read the line above saying why it
                  // is not available yet.
                  onPressed: (_busy || !_clean || _queued > 0) ? null : _approve,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('Approve'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
