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
import '../../models/dpl_stock_control.dart';
import '../common/maxion_kit.dart';
import 'stock_providers.dart';
import 'stock_scan_widgets.dart';

/// Stock adjustments and unlabelled lots (backend API.md §10.1–10.2).
///
/// One person requests, another approves: the requester can never approve
/// their own (`SAME_PERSON`), stock never goes negative
/// (`INSUFFICIENT_STOCK`), and a wheel that moved since the request is
/// refused (`WHEEL_MOVED`). Every one of those is the server's call and is
/// shown verbatim.

const _adjStatuses = <String?, String>{
  'pending': 'Pending',
  'approved': 'Approved',
  'rejected': 'Rejected',
  null: 'All',
};

Color _adjColor(String status) => switch (status) {
      'pending' => DplColors.warning,
      'approved' => DplColors.success,
      'rejected' => DplColors.error,
      _ => DplColors.neutral,
    };

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

class DplStockAdjustmentsScreen extends ConsumerStatefulWidget {
  final bool showAppBar;

  const DplStockAdjustmentsScreen({super.key, this.showAppBar = true});

  @override
  ConsumerState<DplStockAdjustmentsScreen> createState() => _DplStockAdjustmentsScreenState();
}

class _DplStockAdjustmentsScreenState extends ConsumerState<DplStockAdjustmentsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)..addListener(() => setState(() {}));
  String? _status = 'pending';
  final Set<int> _busy = {};

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _new() async {
    final created = await Navigator.of(context).push<DplStockAdjustment>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const DplNewStockAdjustmentPage()),
    );
    if (created == null || !mounted) return;
    ref.invalidate(dplStockAdjustmentsProvider);
    DplSnacks.success(context, '${created.adjustmentNo} raised — waiting for approval.');
  }

  Future<void> _decide(DplStockAdjustment a, bool approve) async {
    final note = await askDplNote(
      context,
      title: approve ? 'Approve ${a.adjustmentNo}?' : 'Reject ${a.adjustmentNo}',
      confirmLabel: approve ? 'Approve' : 'Reject',
      hint: approve ? 'Note' : 'Why?',
      minLength: approve ? 0 : 1,
    );
    if (note == null || !mounted) return;
    setState(() => _busy.add(a.id));
    final res = await ref.read(dplApiServiceProvider).decideStockAdjustment(a.id, approve: approve, note: note.isEmpty ? null : note);
    if (!mounted) return;
    setState(() => _busy.remove(a.id));
    if (res.isError) {
      showFloorError(context, res);
      return;
    }
    DplSnacks.success(context, '${a.adjustmentNo} ${approve ? 'approved' : 'rejected'}.');
    ref.invalidate(dplStockAdjustmentsProvider);
    ref.invalidate(dplStockLotsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(dplPermissionsProvider);
    final tabBar = TabBar(
      controller: _tabs,
      labelColor: DplColors.primary,
      indicatorColor: DplColors.primary,
      tabs: const [Tab(text: 'Adjustments'), Tab(text: 'Lots')],
    );
    final body = Column(children: [
      if (!widget.showAppBar) Material(color: Colors.white, child: tabBar),
      Expanded(
        child: TabBarView(controller: _tabs, children: [
          _adjustmentsTab(perms.can(DplPermission.stockAdjustApprove)),
          const DplStockLotsList(),
        ]),
      ),
    ]);
    final fab = perms.can(DplPermission.stockAdjust) && _tabs.index == 0
        ? FloatingActionButton.extended(
            heroTag: 'dpl-new-adjustment',
            onPressed: _new,
            icon: const Icon(Icons.add),
            label: const Text('New adjustment'),
          )
        : null;
    if (!widget.showAppBar) {
      return Scaffold(backgroundColor: DplColors.pageBg, body: body, floatingActionButton: fab);
    }
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Stock adjustments',
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(kTextTabBarHeight),
          child: Material(color: Colors.white, child: tabBar),
        ),
      ),
      body: body,
      floatingActionButton: fab,
    );
  }

  Widget _adjustmentsTab(bool canApprove) {
    final async = ref.watch(dplStockAdjustmentsProvider(_status));
    final fmt = DateFormat('d MMM, HH:mm');
    final list = async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => DplInlineErrorRetry(message: '$e', onRetry: () => ref.invalidate(dplStockAdjustmentsProvider(_status))),
      data: (res) {
        if (res.isError) {
          return DplInlineErrorRetry(message: res.floorMessage, onRetry: () => ref.invalidate(dplStockAdjustmentsProvider(_status)));
        }
        final rows = res.data ?? const <DplStockAdjustment>[];
        if (rows.isEmpty) {
          return const DplEmptyView(icon: Icons.tune, title: 'No adjustments');
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(dplStockAdjustmentsProvider(_status));
            await ref.read(dplStockAdjustmentsProvider(_status).future);
          },
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(DplSpacing.lg, DplSpacing.sm, DplSpacing.lg, 96),
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final a = rows[i];
              final isWheels = a.kind == 'wheels';
              final sign = isWheels || a.direction == 'decrease' ? '−' : '+';
              return DplCard(
                margin: const EdgeInsets.only(bottom: DplSpacing.sm),
                accentColor: _adjColor(a.status),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(a.adjustmentNo, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
                    DplTagPill(label: _cap(a.status), color: _adjColor(a.status)),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                    [
                      isWheels ? 'Write-off $sign${a.qty} wheel${a.qty == 1 ? '' : 's'}' : 'Lot $sign${a.qty}',
                      if (a.customerPartNo != null) a.customerPartNo!,
                      a.reason ?? a.reasonCode,
                    ].join('  ·  '),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (a.note.isNotEmpty) ...[const SizedBox(height: 4), Text(a.note)],
                  if (a.requestedAt != null)
                    Text('Requested ${fmt.format(a.requestedAt!.toLocal())}',
                        style: const TextStyle(color: DplColors.textSecondary, fontSize: 12)),
                  if ((a.decisionNote ?? '').isNotEmpty)
                    Text('Decision: ${a.decisionNote}', style: const TextStyle(color: DplColors.textSecondary, fontSize: 12.5)),
                  if (a.isPending && canApprove) ...[
                    const SizedBox(height: 8),
                    Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      TextButton(onPressed: _busy.contains(a.id) ? null : () => _decide(a, false), child: const Text('Reject')),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: _busy.contains(a.id) ? null : () => _decide(a, true), child: const Text('Approve')),
                    ]),
                  ],
                ]),
              );
            },
          ),
        );
      },
    );
    return Column(children: [
      SizedBox(
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: DplSpacing.lg, vertical: DplSpacing.sm),
          children: [
            for (final e in _adjStatuses.entries)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(label: Text(e.value), selected: _status == e.key, onSelected: (_) => setState(() => _status = e.key)),
              ),
          ],
        ),
      ),
      Expanded(child: list),
    ]);
  }
}

/// Unlabelled lot stock: opening quantity against what is left.
class DplStockLotsList extends ConsumerWidget {
  const DplStockLotsList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dplStockLotsProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => DplInlineErrorRetry(message: '$e', onRetry: () => ref.invalidate(dplStockLotsProvider)),
      data: (res) {
        if (res.isError) return DplInlineErrorRetry(message: res.floorMessage, onRetry: () => ref.invalidate(dplStockLotsProvider));
        final lots = res.data ?? const <DplStockLot>[];
        if (lots.isEmpty) {
          return const DplEmptyView(
            icon: Icons.inventory_2_outlined,
            title: 'No unlabelled stock',
            message: 'Lots appear here after an opening-stock import.',
          );
        }
        final total = lots.fold<int>(0, (s, l) => s + l.qtyRemaining);
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(dplStockLotsProvider);
            await ref.read(dplStockLotsProvider.future);
          },
          child: ListView.builder(
            padding: const EdgeInsets.all(DplSpacing.lg),
            itemCount: lots.length + 1,
            itemBuilder: (_, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: DplSpacing.sm),
                  child: Text('${lots.length} lots  ·  $total wheels unlabelled',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                );
              }
              final l = lots[i - 1];
              final frac = l.openingQty <= 0 ? 0.0 : (l.qtyRemaining / l.openingQty).clamp(0.0, 1.0);
              return DplCard(
                margin: const EdgeInsets.only(bottom: DplSpacing.sm),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(l.customerPartNo ?? 'Part #${l.partId}', style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                    Text('${l.qtyRemaining} / ${l.openingQty}', style: const TextStyle(fontWeight: FontWeight.w800)),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (l.lotNo != null) 'Lot ${l.lotNo}',
                      if (l.sourceLocationCode != null) l.sourceLocationCode!,
                      if (l.fifoDate != null) 'FIFO ${l.fifoDate}',
                    ].join('  ·  '),
                    style: const TextStyle(color: DplColors.textSecondary, fontSize: 12.5),
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: frac, minHeight: 6, borderRadius: BorderRadius.circular(3)),
                  const SizedBox(height: 2),
                  const Text('remaining of opening', style: TextStyle(color: DplColors.textTertiary, fontSize: 11)),
                ]),
              );
            },
          ),
        );
      },
    );
  }
}

/// Raise an adjustment: a lot quantity change, or a write-off of labelled
/// wheels. Pops the created [DplStockAdjustment].
class DplNewStockAdjustmentPage extends ConsumerStatefulWidget {
  const DplNewStockAdjustmentPage({super.key});

  @override
  ConsumerState<DplNewStockAdjustmentPage> createState() => _DplNewStockAdjustmentPageState();
}

class _DplNewStockAdjustmentPageState extends ConsumerState<DplNewStockAdjustmentPage> {
  bool _wheels = false;

  // Lot mode
  DplStockLot? _lot;
  String _direction = 'decrease';
  final _qtyCtrl = TextEditingController();
  final _lotSearch = TextEditingController();

  // Wheel mode
  final List<String> _codes = [];
  final _codeCtrl = TextEditingController();
  final _codeFocus = FocusNode();

  String? _reason;
  final _noteCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _lotSearch.dispose();
    _codeCtrl.dispose();
    _codeFocus.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  int? get _qty => int.tryParse(_qtyCtrl.text.trim());

  bool get _valid {
    if (_reason == null || _noteCtrl.text.trim().length < 5) return false;
    if (_wheels) return _codes.isNotEmpty;
    final q = _qty;
    return _lot != null && q != null && q >= 1 && q <= 100000;
  }

  bool _addCode(String raw) {
    final code = raw.trim();
    if (code.isEmpty || _codes.contains(code)) return false;
    setState(() => _codes.add(code));
    return true;
  }

  Future<void> _submit() async {
    final body = _wheels
        ? dplWheelWriteOffBody(codes: _codes, reasonCode: _reason!, note: _noteCtrl.text)
        : dplLotAdjustmentBody(lotId: _lot!.lotId, direction: _direction, qty: _qty!, reasonCode: _reason!, note: _noteCtrl.text);
    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).requestStockAdjustment(body);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.isError || res.data == null) {
      showFloorError(context, res, fallback: 'Could not raise the adjustment.');
      return;
    }
    ref.invalidate(dplStockLotsProvider);
    Navigator.of(context).pop(res.data);
  }

  @override
  Widget build(BuildContext context) {
    final reasons = ref.watch(dplStockReasonsProvider).asData?.value.data ?? const <({String code, String label})>[];
    final canCamera = ref.watch(dplPermissionsProvider).can(DplPermission.palletScanCamera);
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: AppBar(title: const Text('New adjustment')),
      body: ListView(
        padding: const EdgeInsets.all(DplSpacing.lg),
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Lot quantity'), icon: Icon(Icons.inventory_2_outlined)),
              ButtonSegment(value: true, label: Text('Write off wheels'), icon: Icon(Icons.delete_sweep_outlined)),
            ],
            selected: {_wheels},
            onSelectionChanged: (s) => setState(() => _wheels = s.first),
          ),
          const SizedBox(height: DplSpacing.lg),
          if (_wheels) ..._wheelFields(canCamera) else ..._lotFields(),
          const SizedBox(height: DplSpacing.lg),
          DropdownButtonFormField<String>(
            initialValue: _reason,
            decoration: const InputDecoration(labelText: 'Reason', border: OutlineInputBorder()),
            items: [for (final r in reasons) DropdownMenuItem(value: r.code, child: Text(r.label.isEmpty ? r.code : r.label))],
            onChanged: (v) => setState(() => _reason = v),
          ),
          const SizedBox(height: DplSpacing.md),
          TextField(
            controller: _noteCtrl,
            minLines: 2,
            maxLines: 4,
            maxLength: 500,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Note',
              helperText: 'Explain what happened (at least 5 characters).',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: DplSpacing.md),
          FilledButton.icon(
            onPressed: _busy || !_valid ? null : _submit,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send),
            label: const Text('Request approval'),
          ),
          const SizedBox(height: 6),
          const Text(
            'Someone else must approve it before stock changes.',
            style: TextStyle(color: DplColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  List<Widget> _lotFields() {
    final async = ref.watch(dplStockLotsProvider);
    final lots = async.asData?.value.data ?? const <DplStockLot>[];
    final q = _lotSearch.text.trim().toLowerCase();
    final shown = q.isEmpty
        ? lots
        : lots
            .where((l) => '${l.customerPartNo ?? ''} ${l.lotNo ?? ''} ${l.sourceLocationCode ?? ''}'.toLowerCase().contains(q))
            .toList();
    return [
      if (_lot != null)
        DplCard(
          accentColor: DplColors.primary,
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_lot!.customerPartNo ?? 'Part #${_lot!.partId}', style: const TextStyle(fontWeight: FontWeight.w800)),
                Text('Lot ${_lot!.lotNo ?? '—'}  ·  ${_lot!.qtyRemaining} left',
                    style: const TextStyle(color: DplColors.textSecondary)),
              ]),
            ),
            TextButton(onPressed: () => setState(() => _lot = null), child: const Text('Change')),
          ]),
        )
      else ...[
        TextField(
          controller: _lotSearch,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Find a lot by item code, lot or location',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        if (async.isLoading)
          const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
        else if (async.asData?.value.isError ?? false)
          DplInlineErrorChip(message: async.asData!.value.floorMessage, onRetry: () => ref.invalidate(dplStockLotsProvider))
        else if (shown.isEmpty)
          const Text('No lots match.', style: TextStyle(color: DplColors.textSecondary))
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final l in shown)
                  ListTile(
                    dense: true,
                    title: Text(l.customerPartNo ?? 'Part #${l.partId}'),
                    subtitle: Text([
                      if (l.lotNo != null) 'Lot ${l.lotNo}',
                      if (l.sourceLocationCode != null) l.sourceLocationCode!,
                      if (l.fifoDate != null) 'FIFO ${l.fifoDate}',
                    ].join('  ·  ')),
                    trailing: Text('${l.qtyRemaining}', style: const TextStyle(fontWeight: FontWeight.w800)),
                    onTap: () => setState(() => _lot = l),
                  ),
              ],
            ),
          ),
      ],
      const SizedBox(height: DplSpacing.md),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'decrease', label: Text('Decrease'), icon: Icon(Icons.remove)),
          ButtonSegment(value: 'increase', label: Text('Increase'), icon: Icon(Icons.add)),
        ],
        selected: {_direction},
        onSelectionChanged: (s) => setState(() => _direction = s.first),
      ),
      const SizedBox(height: DplSpacing.md),
      TextField(
        controller: _qtyCtrl,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: 'Quantity',
          border: const OutlineInputBorder(),
          helperText: _direction == 'decrease' && _lot != null ? 'At most ${_lot!.qtyRemaining}.' : null,
        ),
      ),
    ];
  }

  List<Widget> _wheelFields(bool canCamera) {
    return [
      const Text(
        'Scan each wheel to write off. Wheels on a pallet must be taken off the pallet first.',
        style: TextStyle(color: DplColors.textSecondary),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _codeCtrl,
        focusNode: _codeFocus,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          hintText: 'Scan, or type the serial',
          prefixIcon: Icon(Icons.qr_code_scanner_rounded),
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onSubmitted: (v) {
          _codeCtrl.clear();
          _codeFocus.requestFocus();
          if (!_addCode(v) && v.trim().isNotEmpty) DplSnacks.warning(context, 'Already in the list.');
        },
      ),
      if (canCamera) ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => DplContinuousScanPage.open(
            context,
            title: 'Wheels to write off',
            onCode: (code) async =>
                _addCode(code) ? DplScanFeedback('Added $code') : DplScanFeedback('$code is already in the list', ok: false),
          ),
          icon: const Icon(Icons.photo_camera_outlined, size: 18),
          label: const Text('Scan with the camera'),
        ),
      ],
      const SizedBox(height: 8),
      if (_codes.isEmpty)
        const Text('No wheels yet.', style: TextStyle(color: DplColors.textSecondary))
      else ...[
        Text('${_codes.length} wheel${_codes.length == 1 ? '' : 's'}', style: const TextStyle(fontWeight: FontWeight.w800)),
        for (final c in _codes)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(c, style: const TextStyle(fontFamily: 'monospace')),
            trailing: IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _codes.remove(c)),
            ),
          ),
      ],
    ];
  }
}
