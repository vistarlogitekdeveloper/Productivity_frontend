import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_empty_state.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/_json_helpers.dart';
import '../../models/dpl_location.dart';
import '../../models/dpl_stock_control.dart';
import '../../qa/widgets/location_picker_sheet.dart';
import '../common/maxion_kit.dart';
import '../sync/offline_outbox.dart';
import '../sync/offline_scan.dart';
import '../sync/sync_providers.dart';
import '../sync/sync_status_widgets.dart';
import 'stock_providers.dart';
import 'stock_scan_widgets.dart';

/// Blind rack counts (backend API.md §10.3).
///
/// While a count is open it is BLIND: the counter sees only what they have
/// found, never what the system expects on the rack. The server enforces that
/// by leaving the expected side out of every response; this screen adds
/// nothing of its own that could hint at it. The comparison — matched,
/// misplaced, missing, unexpected — appears only after submit.

const _countStatuses = <String?, String>{
  null: 'All',
  'open': 'Open',
  'submitted': 'Submitted',
  'approved': 'Approved',
  'rejected': 'Rejected',
  'cancelled': 'Cancelled',
};

Color _statusColor(String status) {
  switch (status) {
    case 'open':
      return DplColors.info;
    case 'submitted':
      return DplColors.warning;
    case 'approved':
      return DplColors.success;
    case 'rejected':
      return DplColors.error;
    default:
      return DplColors.neutral;
  }
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// The list of rack counts, with a way to start one.
class DplRackCountsScreen extends ConsumerStatefulWidget {
  final bool showAppBar;

  const DplRackCountsScreen({super.key, this.showAppBar = true});

  @override
  ConsumerState<DplRackCountsScreen> createState() => _DplRackCountsScreenState();
}

class _DplRackCountsScreenState extends ConsumerState<DplRackCountsScreen> {
  String? _status;

  Future<void> _start() async {
    final count = await showModalBottomSheet<DplRackCount>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _StartCountSheet(),
    );
    if (count == null || !mounted) return;
    ref.invalidate(dplRackCountsProvider);
    await _open(count.countId);
  }

  Future<void> _open(int id) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => DplRackCountScreen(countId: id)));
    if (mounted) ref.invalidate(dplRackCountsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(dplPermissionsProvider);
    final canCount = perms.can(DplPermission.stockCount);
    final async = ref.watch(dplRackCountsProvider(_status));
    final fmt = DateFormat('d MMM, HH:mm');

    final list = async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => DplInlineErrorRetry(message: '$e', onRetry: () => ref.invalidate(dplRackCountsProvider(_status))),
      data: (res) {
        if (res.isError) {
          return DplInlineErrorRetry(message: res.floorMessage, onRetry: () => ref.invalidate(dplRackCountsProvider(_status)));
        }
        final rows = res.data ?? const [];
        if (rows.isEmpty) {
          return DplEmptyView(
            icon: Icons.fact_check_outlined,
            title: 'No rack counts',
            message: canCount ? 'Start a count to check what is really on the racks.' : null,
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(dplRackCountsProvider(_status));
            await ref.read(dplRackCountsProvider(_status).future);
          },
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(DplSpacing.lg, DplSpacing.sm, DplSpacing.lg, 96),
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final r = rows[i];
              final status = parseStringOr(r['status']);
              final started = parseDateTimeOrNull(r['started_at']);
              final racks = parseIntOr(r['racks']);
              return DplCard(
                margin: const EdgeInsets.only(bottom: DplSpacing.sm),
                accentColor: _statusColor(status),
                onTap: () => _open(parseIntOr(r['count_id'])),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(parseStringOr(r['count_no'], 'Count'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(
                        '$racks rack${racks == 1 ? '' : 's'}${started == null ? '' : '  ·  started ${fmt.format(started.toLocal())}'}',
                        style: TextStyle(color: DplColors.textSecondary, fontSize: 12.5),
                      ),
                    ]),
                  ),
                  DplTagPill(label: _cap(status), color: _statusColor(status)),
                  Icon(Icons.chevron_right, color: DplColors.textTertiary),
                ]),
              );
            },
          ),
        );
      },
    );

    final body = Column(children: [
      SizedBox(
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: DplSpacing.lg, vertical: DplSpacing.sm),
          children: [
            for (final e in _countStatuses.entries)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(e.value),
                  selected: _status == e.key,
                  onSelected: (_) => setState(() => _status = e.key),
                ),
              ),
          ],
        ),
      ),
      Expanded(child: list),
    ]);

    final fab = canCount
        ? FloatingActionButton.extended(
            heroTag: 'dpl-start-count',
            onPressed: _start,
            icon: const Icon(Icons.add),
            label: const Text('Start a count'),
          )
        : null;

    if (!widget.showAppBar) {
      return Scaffold(backgroundColor: DplColors.pageBg, body: body, floatingActionButton: fab);
    }
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: const DplAppBar(title: 'Rack counts', actions: [DplSyncStatusChip(hideWhenSynced: true)]),
      body: body,
      floatingActionButton: fab,
    );
  }
}

/// Pick racks (or a zone) and start a count. Pops the new count.
class _StartCountSheet extends ConsumerStatefulWidget {
  const _StartCountSheet();

  @override
  ConsumerState<_StartCountSheet> createState() => _StartCountSheetState();
}

class _StartCountSheetState extends ConsumerState<_StartCountSheet> {
  bool _byZone = false;
  final List<DplLocation> _racks = [];
  final _zoneCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _zoneCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _addRack() async {
    // /stock/counts/locations needs only stock.count, so a counter without
    // pallet permissions still gets the rack list. Full racks stay pickable —
    // a full rack is exactly the one worth counting.
    final res = await ref.read(dplApiServiceProvider).listCountLocations();
    if (!mounted) return;
    DplLocation? loc;
    if (res.isOk && (res.data ?? const []).isNotEmpty) {
      loc = await showModalBottomSheet<DplLocation>(
        context: context,
        showDragHandle: true,
        builder: (c) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final l in res.data!)
                if (!_racks.any((r) => r.id == l.id))
                  ListTile(
                    leading: const Icon(Icons.shelves),
                    title: Text(l.code),
                    subtitle: Text([l.zone, l.name].whereType<String>().where((s) => s.isNotEmpty).join(' · ')),
                    onTap: () => Navigator.pop(c, l),
                  ),
            ],
          ),
        ),
      );
    } else {
      loc = await LocationPickerSheet.show(context, requiredQty: 0, fromWarehouse: true);
    }
    final picked = loc;
    if (picked == null || !mounted) return;
    if (_racks.any((r) => r.id == picked.id)) return;
    setState(() => _racks.add(picked));
  }

  bool get _ready => _byZone ? _zoneCtrl.text.trim().isNotEmpty : _racks.isNotEmpty;

  Future<void> _submit() async {
    setState(() => _busy = true);
    final note = _noteCtrl.text.trim();
    final res = await ref.read(dplApiServiceProvider).startRackCount(
          locationIds: _byZone ? null : _racks.map((r) => r.id).toList(),
          zone: _byZone ? _zoneCtrl.text.trim() : null,
          note: note.isEmpty ? null : note,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.isError || res.data == null) {
      showFloorError(context, res, fallback: 'Could not start the count.');
      return;
    }
    DplSnacks.success(context, '${res.data!.countNo} started.');
    Navigator.of(context).pop(res.data);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Start a rack count', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              'The count is blind: you will see only what you scan, not what the system expects.',
              style: TextStyle(color: DplColors.textSecondary),
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Pick racks'), icon: Icon(Icons.shelves)),
                ButtonSegment(value: true, label: Text('Whole zone'), icon: Icon(Icons.grid_view)),
              ],
              selected: {_byZone},
              onSelectionChanged: (s) => setState(() => _byZone = s.first),
            ),
            const SizedBox(height: 12),
            if (_byZone)
              TextField(
                controller: _zoneCtrl,
                textCapitalization: TextCapitalization.characters,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Zone', hintText: 'e.g. A', border: OutlineInputBorder()),
              )
            else ...[
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final r in _racks)
                  InputChip(
                    label: Text(r.code),
                    onDeleted: () => setState(() => _racks.remove(r)),
                  ),
                ActionChip(avatar: const Icon(Icons.add, size: 18), label: const Text('Add rack'), onPressed: _addRack),
              ]),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _noteCtrl,
              decoration: const InputDecoration(labelText: 'Note (optional)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy || !_ready ? null : _submit,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow),
              label: const Text('Start counting'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One scan in this session, as the counter saw it.
class _ScanEntry {
  final String code;
  final String rack;
  final OfflineScanStatus status;
  final String message;
  const _ScanEntry(this.code, this.rack, this.status, this.message);
}

/// One rack count: scanning while open, the comparison once submitted.
class DplRackCountScreen extends ConsumerStatefulWidget {
  final int countId;

  const DplRackCountScreen({super.key, required this.countId});

  @override
  ConsumerState<DplRackCountScreen> createState() => _DplRackCountScreenState();
}

class _DplRackCountScreenState extends ConsumerState<DplRackCountScreen> {
  final _scanCtrl = TextEditingController();
  final _scanFocus = FocusNode();
  int? _rackId;
  bool _acting = false;
  final List<_ScanEntry> _session = [];

  @override
  void dispose() {
    _scanCtrl.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  void _refresh() => ref.invalidate(dplRackCountProvider(widget.countId));

  String _rackCode(DplRackCount c, int id) =>
      c.racks.firstWhere((r) => r.id == id, orElse: () => (id: id, code: '#$id')).code;

  Future<DplScanFeedback> _scanCode(DplRackCount count, String raw) async {
    final code = raw.trim();
    final rackId = _rackId;
    if (code.isEmpty || rackId == null) return const DplScanFeedback('Pick the rack first.', ok: false);
    final rack = _rackCode(count, rackId);
    final result = await scanCountOrQueue(
      ref,
      countId: widget.countId,
      locationId: rackId,
      code: code,
      userId: ref.read(dplCurrentUserIdProvider) ?? 0,
    );
    if (!mounted) return const DplScanFeedback('');
    late final DplScanFeedback fb;
    switch (result.status) {
      case OfflineScanStatus.online:
        final d = result.data ?? const {};
        final pallet = parseStringOr(d['pallet_no'], code);
        final qty = parseIntOrNull(d['qty']);
        fb = DplScanFeedback('$pallet on $rack${qty == null ? '' : ' — $qty wheels'}');
        _refresh();
      case OfflineScanStatus.queued:
        fb = DplScanFeedback('Offline — $code on $rack queued');
      case OfflineScanStatus.refused:
        final msg = result.response?.floorMessage.trim() ?? '';
        fb = DplScanFeedback(msg.isEmpty ? 'That scan was refused.' : msg, ok: false);
    }
    setState(() => _session.insert(0, _ScanEntry(code, rack, result.status, fb.message)));
    return fb;
  }

  Future<void> _typed(DplRackCount count, String v) async {
    // Clear and re-focus first so the next pallet can be scanned while this
    // one is in flight.
    _scanCtrl.clear();
    _scanFocus.requestFocus();
    if (v.trim().isEmpty) return;
    final fb = await _scanCode(count, v);
    if (!mounted || fb.message.isEmpty) return;
    if (fb.ok) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.heavyImpact();
      DplSnacks.error(context, fb.message);
    }
  }

  Future<void> _action(DplRackCount count, String action) async {
    String? note;
    switch (action) {
      case 'submit':
        final ok = await confirmDpl(context,
            title: 'Submit ${count.countNo}?',
            message: 'You have found ${count.scanned} pallet${count.scanned == 1 ? '' : 's'}. '
                'After submitting, nothing more can be scanned and the comparison with the system is shown.',
            confirmLabel: 'Submit');
        if (!ok) return;
      case 'cancel':
        final ok = await confirmDpl(context,
            title: 'Cancel ${count.countNo}?',
            message: 'The scans are discarded and the racks are free to be counted again.',
            confirmLabel: 'Cancel the count');
        if (!ok) return;
      case 'approve':
        note = await askDplNote(context,
            title: 'Approve ${count.countNo}?',
            confirmLabel: 'Approve',
            message: 'Misplaced and unexpected pallets will be racked where they were found; '
                'missing ones are taken off their rack.');
        if (note == null) return;
      case 'reject':
        note = await askDplNote(context, title: 'Reject ${count.countNo}', confirmLabel: 'Reject', hint: 'Why?', minLength: 1);
        if (note == null) return;
    }
    if (!mounted) return;
    setState(() => _acting = true);
    final res = await ref.read(dplApiServiceProvider).rackCountAction(
          widget.countId,
          action,
          note: (note == null || note.isEmpty) ? null : note,
        );
    if (!mounted) return;
    setState(() => _acting = false);
    if (res.isError) {
      // SAME_PERSON (the counter approving their own count) lands here too.
      showFloorError(context, res);
      return;
    }
    DplSnacks.success(context, '${count.countNo}: ${res.data?.status ?? action}.');
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(dplRackCountProvider(widget.countId));
    final count = async.asData?.value.data;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: count?.countNo ?? 'Rack count',
        actions: const [DplSyncStatusChip(hideWhenSynced: true)],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => DplInlineErrorRetry(message: '$e', onRetry: _refresh),
        data: (res) {
          if (res.isError || res.data == null) {
            return DplInlineErrorRetry(message: res.floorMessage, onRetry: _refresh);
          }
          final c = res.data!;
          if (c.status == 'open' && c.blind) return _openView(c);
          return _closedView(c);
        },
      ),
    );
  }

  Widget _openView(DplRackCount c) {
    final perms = ref.watch(dplPermissionsProvider);
    final canCount = perms.can(DplPermission.stockCount);
    if (_rackId == null || !c.racks.any((r) => r.id == _rackId)) {
      _rackId = c.racks.isEmpty ? null : c.racks.first.id;
    }
    final queuedHere = ref.watch(dplOfflineOutboxProvider).pendingOf('count.scan', where: {'count_id': widget.countId});
    return RefreshIndicator(
      onRefresh: () async {
        _refresh();
        await ref.read(dplRackCountProvider(widget.countId).future);
      },
      child: ListView(
        padding: const EdgeInsets.all(DplSpacing.lg),
        children: [
          DplCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(Icons.visibility_off_outlined, size: 18, color: DplColors.info),
                const SizedBox(width: 6),
                const Expanded(child: Text('Blind count — scan every pallet you find on the rack.')),
                DplTagPill(label: '${c.scanned} found', color: DplColors.primary),
              ]),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _rackId,
                decoration: const InputDecoration(labelText: 'Rack you are counting', border: OutlineInputBorder()),
                items: [for (final r in c.racks) DropdownMenuItem(value: r.id, child: Text(r.code))],
                onChanged: canCount ? (v) => setState(() => _rackId = v) : null,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _scanCtrl,
                focusNode: _scanFocus,
                enabled: canCount && _rackId != null,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  hintText: 'Scan a pallet label, or type the pallet number',
                  prefixIcon: Icon(Icons.qr_code_scanner_rounded),
                  helperText: 'A hardware scanner types the code and presses enter. Any wheel on the pallet also works.',
                  helperMaxLines: 2,
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (v) => _typed(c, v),
              ),
              if (canCount && perms.can(DplPermission.palletScanCamera)) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _rackId == null
                      ? null
                      : () => DplContinuousScanPage.open(
                            context,
                            title: 'Count ${_rackCode(c, _rackId!)}',
                            hint: 'Rack ${_rackCode(c, _rackId!)}',
                            onCode: (code) => _scanCode(c, code),
                          ),
                  icon: const Icon(Icons.photo_camera_outlined, size: 18),
                  label: const Text('Scan with the camera'),
                ),
              ],
            ]),
          ),
          if (_session.isNotEmpty) ...[
            const SizedBox(height: DplSpacing.lg),
            const Text('This session', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            for (final e in _session.take(30))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  switch (e.status) {
                    OfflineScanStatus.online => Icons.check_circle,
                    OfflineScanStatus.queued => Icons.cloud_queue,
                    OfflineScanStatus.refused => Icons.error,
                  },
                  color: switch (e.status) {
                    OfflineScanStatus.online => DplColors.success,
                    OfflineScanStatus.queued => DplColors.warning,
                    OfflineScanStatus.refused => DplColors.error,
                  },
                ),
                title: Text(e.message, maxLines: 3),
                subtitle: Text('${e.code}  ·  ${e.rack}', style: const TextStyle(fontSize: 12)),
              ),
          ],
          const SizedBox(height: DplSpacing.lg),
          Text('Found so far (${c.scanned})', style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          if (c.lines.isEmpty)
            Text('Nothing scanned yet.', style: TextStyle(color: DplColors.textSecondary))
          else
            for (final l in c.lines)
              DplCard(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l.palletNo ?? '—', style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(
                        [if (l.customerPartNo != null) l.customerPartNo!, if (l.qty != null) '${l.qty} wheels'].join('  ·  '),
                        style: TextStyle(color: DplColors.textSecondary, fontSize: 12.5),
                      ),
                    ]),
                  ),
                  if (l.foundLocation != null) DplTagPill(label: l.foundLocation!, color: DplColors.primary),
                ]),
              ),
          if (canCount) ...[
            const SizedBox(height: DplSpacing.xl),
            if (queuedHere > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '$queuedHere scan${queuedHere == 1 ? ' is' : 's are'} still queued on this handheld. '
                  'Sync before submitting, or they will be refused once the count is closed.',
                  style: TextStyle(color: DplColors.warning, fontWeight: FontWeight.w600),
                ),
              ),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _acting ? null : () => _action(c, 'cancel'),
                  child: const Text('Cancel count'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _acting || queuedHere > 0 ? null : () => _action(c, 'submit'),
                  child: const Text('Submit'),
                ),
              ),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _closedView(DplRackCount c) {
    final canApprove = ref.watch(dplPermissionsProvider).can(DplPermission.stockCountApprove);
    return ListView(
      padding: const EdgeInsets.all(DplSpacing.lg),
      children: [
        DplRackCountSummary(count: c),
        if (c.status == 'submitted' && canApprove) ...[
          const SizedBox(height: DplSpacing.xl),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _acting ? null : () => _action(c, 'reject'),
                child: const Text('Reject'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _acting ? null : () => _action(c, 'approve'),
                child: const Text('Approve'),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            'Someone other than the counter must approve.',
            style: TextStyle(color: DplColors.textSecondary, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

/// A submitted (or decided) count: result totals, accuracy, and every line
/// with its result. Only ever given a non-blind count.
class DplRackCountSummary extends StatelessWidget {
  final DplRackCount count;

  const DplRackCountSummary({super.key, required this.count});

  static const results = ['matched', 'misplaced', 'missing', 'unexpected'];

  @override
  Widget build(BuildContext context) {
    final s = count.summary ?? const <String, int>{};
    final acc = count.accuracyPct;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DplCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(count.countNo, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ),
              DplTagPill(label: _cap(count.status), color: _statusColor(count.status)),
            ]),
            const SizedBox(height: 10),
            Text(
              acc == null ? 'Accuracy —' : 'Accuracy ${acc.toStringAsFixed(acc == acc.roundToDouble() ? 0 : 1)}%',
              key: const ValueKey('dpl-count-accuracy'),
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: acc == null ? DplColors.textSecondary : (acc >= 98 ? DplColors.success : (acc >= 90 ? DplColors.warning : DplColors.error)),
              ),
            ),
            if (s['expected'] != null)
              Text('${s['expected']} pallets expected on these racks', style: TextStyle(color: DplColors.textSecondary)),
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (final r in results) DplCountChip(label: _cap(r), count: s[r] ?? 0, color: dplCountResultColor(r)),
            ]),
          ]),
        ),
        const SizedBox(height: DplSpacing.md),
        if (count.lines.isEmpty)
          Text('No lines.', style: TextStyle(color: DplColors.textSecondary))
        else
          for (final l in count.lines)
            DplCard(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.palletNo ?? '—', style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(
                      [
                        if (l.customerPartNo != null) l.customerPartNo!,
                        if (l.qty != null) '${l.qty} wheels',
                        _where(l),
                      ].where((x) => x.isNotEmpty).join('  ·  '),
                      style: TextStyle(color: DplColors.textSecondary, fontSize: 12.5),
                    ),
                  ]),
                ),
                DplTagPill(label: _cap(l.result ?? '—'), color: dplCountResultColor(l.result)),
              ]),
            ),
      ],
    );
  }

  static String _where(DplRackCountLine l) {
    final found = l.foundLocation;
    final expected = l.expectedLocation;
    switch (l.result) {
      case 'misplaced':
        return 'found ${found ?? '—'}, belongs ${expected ?? '—'}';
      case 'missing':
        return 'not found (belongs ${expected ?? '—'})';
      case 'unexpected':
        return 'found ${found ?? '—'}';
      default:
        return found ?? '';
    }
  }
}
