import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../../../core/scanner/hardware_scanner.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_pallet.dart';
import '../../models/dpl_wheel_trolley.dart';
import 'dpl_qr_scan_sheet.dart';

/// Fill a stored half pallet from a trolley, one scanned wheel at a time.
///
/// The second half of the trolley flow. Wheels were parked loose at the pack
/// point because opening a pallet for fourteen of them would have created yet
/// another half pallet; this is where they go onto the half pallets that
/// already exist.
///
/// NOTHING IS WRITTEN UNTIL COMMIT. Every scan lands in a list on this screen,
/// and the merge is one call at the end. That is deliberate: it makes undo
/// free — a mis-scan is removed from a list rather than needing a reverse
/// operation that would have to know which cart to put the wheel back on —
/// and it matches the server, which applies the whole batch or none of it.
///
/// The scanned code is matched against what the trolley actually holds,
/// locally, so a wrong wheel is refused the instant it is scanned instead of
/// after a round trip at the end. The server re-checks everything under a lock
/// regardless; this is for the operator's speed, not for correctness.
class QaTrolleyMergeScreen extends ConsumerStatefulWidget {
  /// The closed half pallet being filled.
  final DplPallet target;

  const QaTrolleyMergeScreen({super.key, required this.target});

  @override
  ConsumerState<QaTrolleyMergeScreen> createState() =>
      _QaTrolleyMergeScreenState();
}

class _QaTrolleyMergeScreenState extends ConsumerState<QaTrolleyMergeScreen> {
  final _scanCtrl = TextEditingController();
  final _scanFocus = FocusNode();

  bool _loading = true;
  bool _busy = false;
  String? _error;

  List<DplWheelTrolley> _trolleys = const [];
  DplWheelTrolley? _trolley;

  /// What that cart holds OF THIS PALLET'S ITEM. The picker and the scan
  /// matcher both work off this, so a wheel of another item on the same cart
  /// is invisible here rather than being offered and then refused.
  List<DplTrolleyWheel> _available = const [];

  /// Chosen so far, in scan order. Ids only would be enough for the call, but
  /// the operator needs to see the serials to know what they have picked up.
  final List<DplTrolleyWheel> _picked = [];

  /// Marks this screen's subtree as the one scans belong to while it is open.
  ///
  /// A pushed route sits OUTSIDE the shell's activeArea — that key points at
  /// the Merge tab still underneath — so without claiming, a wheel scanned
  /// here would be delivered to the screen behind. Losing a scan is annoying;
  /// the wrong screen acting on a real wheel is not.
  final _scanArea = GlobalKey();

  @override
  void initState() {
    super.initState();
    HardwareScanScope.claimArea(_scanArea);
    _loadTrolleys();
  }

  @override
  void dispose() {
    HardwareScanScope.releaseArea(_scanArea);
    _scanCtrl.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  /// How many more this pallet can take before it is full.
  int get _room {
    final std = widget.target.standardQty;
    if (std == null || std <= 0) return 9999;
    return std - widget.target.qty;
  }

  bool get _wouldOverfill => _picked.length >= _room;

  // -------------------------------------------------------------------------
  // Loading
  // -------------------------------------------------------------------------

  Future<void> _loadTrolleys() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await ref.read(dplApiServiceProvider).getTrolleys();
    if (!mounted) return;

    if (res.isError) {
      setState(() {
        _loading = false;
        _error = res.error ?? 'Could not load the trolleys.';
      });
      return;
    }

    final rows = (res.data ?? const <DplWheelTrolley>[])
        .where((t) => t.isActive)
        .toList(growable: false);

    setState(() {
      _trolleys = rows;
      _loading = false;
    });

    // One cart is the common case and asking about it is a tap for nothing.
    if (rows.length == 1) {
      await _pick(rows.first);
    } else if (rows.isEmpty) {
      setState(() => _error = 'No trolley has been set up yet. Park some '
          'wheels from the Pallet screen first.');
    }
  }

  Future<void> _pick(DplWheelTrolley t) async {
    setState(() {
      _trolley = t;
      _busy = true;
      _picked.clear();
    });

    final res = await ref
        .read(dplApiServiceProvider)
        .getTrolleyWheels(t.id, partId: widget.target.partId);
    if (!mounted) return;

    setState(() {
      _busy = false;
      if (res.isError) {
        _error = res.error ?? 'Could not load what is on that trolley.';
        _available = const [];
      } else {
        _error = null;
        _available = res.data?.packable ?? const [];
      }
    });
    _scanFocus.requestFocus();
  }

  // -------------------------------------------------------------------------
  // Scanning
  // -------------------------------------------------------------------------

  void _scan(String raw) {
    final code = raw.trim();
    _scanCtrl.clear();
    _scanFocus.requestFocus();
    if (code.isEmpty) return;

    if (_wouldOverfill) {
      _refuse('This pallet only has room for $_room more.');
      return;
    }

    // Matched case-insensitively against the raw payload the label carries —
    // which for an adopted old label is NOT the stored serial, because that is
    // a shortened hash printed on nothing.
    final wanted = code.toUpperCase();
    final found = _available
        .where((w) => w.serialNo.toUpperCase() == wanted)
        .firstOrNull;

    if (found == null) {
      _refuse(
        'That wheel is not on ${_trolley?.trolleyNo ?? 'this trolley'} — '
        'or it is a different item from this pallet.',
      );
      return;
    }
    if (_picked.any((w) => w.id == found.id)) {
      _refuse('${found.serialNo} is already on the list.');
      return;
    }

    setState(() => _picked.add(found));
    HapticFeedback.selectionClick();
  }

  void _refuse(String message) {
    HapticFeedback.heavyImpact();
    DplSnacks.error(context, message);
  }

  Future<void> _scanWithCamera() async {
    final code = await DplQrScanSheet.open(
      context,
      expecting: widget.target.customerPartNo,
      allowExternal:
          ref.read(dplPermissionsProvider).can(DplPermission.labelsScanExternal),
    );
    if (code == null || !mounted) return;
    _scan(code);
  }

  /// Take everything the cart holds for this item, up to what fits.
  ///
  /// The plan already says the answer is usually "all of them, and it completes
  /// the pallet"; making the operator scan eight labels to agree with it is
  /// work for its own sake when the wheels are in front of them.
  void _takeWhatFits() {
    setState(() {
      for (final w in _available) {
        if (_picked.length >= _room) break;
        if (_picked.any((p) => p.id == w.id)) continue;
        _picked.add(w);
      }
    });
  }

  // -------------------------------------------------------------------------
  // Commit
  // -------------------------------------------------------------------------

  Future<void> _commit() async {
    final t = _trolley;
    if (t == null || _picked.isEmpty) return;

    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).mergeTrolleyIntoPallet(
          palletId: widget.target.id,
          trolleyId: t.id,
          stickerIds: _picked.map((w) => w.id).toList(),
        );
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError) {
      // OVER_CAPACITY, WHEEL_MOVED and PART_MISMATCH each name a different
      // remedy, so they are shown exactly as the server worded them.
      DplSnacks.error(context, res.error ?? 'Failed to move those wheels.');
      return;
    }

    Navigator.of(context).pop(res.data);
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: AppBar(title: const Text('Fill from a trolley')),
      // Keyed so the claim registered in initState can find this subtree and
      // deliver scans here rather than to the tab underneath.
      body: KeyedSubtree(
        key: _scanArea,
        child: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
              children: [
                _targetCard(),
                const SizedBox(height: 12),
                if (_trolley == null) _trolleyPicker() else ...[
                  _scanCard(),
                  const SizedBox(height: 12),
                  _pickedCard(),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  DplInlineErrorRetry(
                    message: _error!,
                    onRetry: _loadTrolleys,
                  ),
                ],
              ],
            ),
      ),
    );
  }

  Widget _targetCard() {
    final p = widget.target;
    final after = p.qty + _picked.length;
    final std = p.standardQty;
    final willBeFull = std != null && after >= std;

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            p.palletNo,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 3),
          Text(
            '${p.customerPartNo}${p.partDescription.isEmpty ? '' : ' · ${p.partDescription}'}',
            style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$after',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: willBeFull ? DplColors.success : DplColors.primary,
                ),
              ),
              if (std != null)
                Text(
                  ' / $std',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: DplColors.textSecondary,
                  ),
                ),
              const Spacer(),
              if (willBeFull)
                Text(
                  'Becomes a FULL pallet',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: DplColors.success,
                  ),
                ),
            ],
          ),
          if (_picked.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              // Says the number change out loud. The operator is holding the
              // old label and will be handed a new one; being told why before
              // the print is the difference between a reprint and a surprise.
              'Filling from a trolley makes this a production merge, so it is '
              'renumbered onto the PM series and the label is reprinted.',
              style: TextStyle(fontSize: 11.5, color: DplColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _trolleyPicker() {
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Which trolley?',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            // An empty cart is listed but not tappable, rather than hidden.
            // Hiding it would leave an operator hunting for a trolley they can
            // see in front of them and cannot find on the screen.
            'A trolley with nothing on it cannot fill anything.',
            style: TextStyle(fontSize: 11.5, color: DplColors.textSecondary),
          ),
          const SizedBox(height: 8),
          for (final t in _trolleys)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                t.label,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              subtitle: Text(
                t.isEmpty
                    ? 'Nothing on it'
                    : '${t.wheelQty} wheel${t.wheelQty == 1 ? '' : 's'} on it',
                style: TextStyle(fontSize: 11.5, color: DplColors.textSecondary),
              ),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: t.isEmpty ? null : () => _pick(t),
            ),
        ],
      ),
    );
  }

  Widget _scanCard() {
    final canCamera =
        ref.watch(dplPermissionsProvider).can(DplPermission.palletScanCamera);
    final left = _available.length - _picked.length;

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'On ${_trolley!.trolleyNo}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              if (_trolleys.length > 1)
                TextButton(
                  onPressed: _busy ? null : () => setState(() => _trolley = null),
                  child: const Text('Change'),
                ),
            ],
          ),
          Text(
            _available.isEmpty
                ? 'Nothing on this trolley is for ${widget.target.customerPartNo}.'
                : '$left of ${_available.length} '
                    '${widget.target.customerPartNo} wheel'
                    '${_available.length == 1 ? '' : 's'} still to pick. '
                    'This pallet has room for $_room.',
            style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
          ),
          if (_available.isNotEmpty) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _scanCtrl,
              focusNode: _scanFocus,
              enabled: !_busy && !_wouldOverfill,
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: _wouldOverfill
                    ? 'The pallet is full'
                    : 'Scan a wheel off the trolley',
                prefixIcon: const Icon(Icons.qr_code_scanner_rounded),
                isDense: true,
                helperText: 'Pick the wheel up, scan it, put it on the pallet. '
                    'Nothing is recorded until you press Move below.',
                helperMaxLines: 3,
              ),
              onSubmitted: _busy ? null : _scan,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (canCamera)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          _busy || _wouldOverfill ? null : _scanWithCamera,
                      icon: const Icon(Icons.photo_camera_outlined, size: 18),
                      label: const Text('Camera'),
                    ),
                  ),
                if (canCamera) const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy || _wouldOverfill ? null : _takeWhatFits,
                    icon: const Icon(Icons.done_all_rounded, size: 18),
                    label: const Text('Take what fits'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _pickedCard() {
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _picked.isEmpty
                ? 'Nothing picked yet'
                : '${_picked.length} picked',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 6),
          if (_picked.isEmpty)
            Text(
              'Scan the wheels you are moving. Anything scanned by mistake can '
              'be taken off this list — nothing has been recorded yet.',
              style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
            ),
          for (final w in _picked)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.check_circle,
                size: 18,
                color: DplColors.success,
              ),
              title: Text(
                w.serialNo,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              subtitle: w.shiftCode.isEmpty
                  ? null
                  : Text(
                      'Shift ${w.shiftCode}',
                      style: TextStyle(
                        fontSize: 11,
                        color: DplColors.textSecondary,
                      ),
                    ),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Take off the list',
                onPressed: _busy
                    ? null
                    : () => setState(
                        () => _picked.removeWhere((p) => p.id == w.id)),
              ),
            ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy || _picked.isEmpty ? null : _commit,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_outlined, size: 18),
              label: Text(
                _picked.isEmpty
                    ? 'Scan some wheels first'
                    : _busy
                        ? 'Moving…'
                        : 'Move ${_picked.length} & print the label',
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
