import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_logistics.dart';
import '../common/maxion_kit.dart';
import 'gate_pass_screen.dart';
import 'logistics_providers.dart';

/// Reasons a truck overstays, offered first so the TAT report groups cleanly.
/// Anything else goes in as free text under "Other".
const List<String> kTatReasons = [
  'Waiting for invoice',
  'Material not ready',
  'Loading delay',
  'Vehicle reported late',
  'Documentation pending',
  'Quality hold',
  'Driver not available',
  'Dock not free',
];
const String kTatOther = 'Other';

/// The editable copy of a trip's shipment details.
///
/// Kept apart from the widget so "send only what changed" (§8.2: the PATCH is
/// partial and `null` clears a field) is a plain function that can be tested
/// without pumping the form.
class DplShipmentDraft {
  int? transporterId;
  int? consigneeId;
  String? vehicleNo;
  String? driverName;
  String? driverMobile;
  String? driverLicenceNo;
  String? sealNo;
  String? lrNo;
  DateTime? lrDate;
  DateTime? vehicleInAt;
  DateTime? dockInAt;
  DateTime? dockOutAt;
  DateTime? vehicleOutAt;
  String? tatReason;
  String? tatRemark;

  DplShipmentDraft({
    this.transporterId,
    this.consigneeId,
    this.vehicleNo,
    this.driverName,
    this.driverMobile,
    this.driverLicenceNo,
    this.sealNo,
    this.lrNo,
    this.lrDate,
    this.vehicleInAt,
    this.dockInAt,
    this.dockOutAt,
    this.vehicleOutAt,
    this.tatReason,
    this.tatRemark,
  });

  factory DplShipmentDraft.fromShipment(DplTripShipment s) => DplShipmentDraft(
        transporterId: s.transporter?.id,
        consigneeId: s.consignee?.id,
        vehicleNo: s.vehicleNo,
        driverName: s.driverName,
        driverMobile: s.driverMobile,
        driverLicenceNo: s.driverLicenceNo,
        sealNo: s.sealNo,
        lrNo: s.lrNo,
        lrDate: _parseYmd(s.lrDate),
        vehicleInAt: s.vehicleInAt,
        dockInAt: s.dockInAt,
        dockOutAt: s.dockOutAt,
        vehicleOutAt: s.vehicleOutAt,
        tatReason: s.tatReason,
        tatRemark: s.tatRemark,
      );

  static DateTime? _parseYmd(String? s) {
    if (s == null || s.trim().length < 10) return null;
    return DateTime.tryParse(s.trim().substring(0, 10));
  }

  static String? _text(String? v, {bool upper = false}) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return null;
    return upper ? t.toUpperCase() : t;
  }

  static String? _iso(DateTime? d) => d?.toUtc().toIso8601String();

  static bool _sameMoment(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == b;
    return a.isAtSameMomentAs(b);
  }

  /// The PATCH body: only the keys whose value differs from [original].
  /// Times go as ISO-8601 UTC, the LR date as yyyy-MM-dd, a blanked field as null.
  Map<String, dynamic> changesFrom(DplShipmentDraft original) {
    final out = <String, dynamic>{};
    void text(String key, String? now, String? was, {bool upper = false}) {
      final a = _text(now, upper: upper);
      final b = _text(was, upper: upper);
      if (a != b) out[key] = a;
    }

    void time(String key, DateTime? now, DateTime? was) {
      if (!_sameMoment(now, was)) out[key] = _iso(now);
    }

    if (transporterId != original.transporterId) out['transporter_id'] = transporterId;
    if (consigneeId != original.consigneeId) out['consignee_id'] = consigneeId;
    text('vehicle_no', vehicleNo, original.vehicleNo, upper: true);
    text('transport_driver_name', driverName, original.driverName);
    text('transport_driver_mobile', driverMobile, original.driverMobile);
    text('driver_licence_no', driverLicenceNo, original.driverLicenceNo, upper: true);
    text('seal_no', sealNo, original.sealNo, upper: true);
    text('lr_no', lrNo, original.lrNo, upper: true);
    final lrNow = lrDate == null ? null : ymd(lrDate!);
    final lrWas = original.lrDate == null ? null : ymd(original.lrDate!);
    if (lrNow != lrWas) out['lr_date'] = lrNow;
    time('vehicle_in_at', vehicleInAt, original.vehicleInAt);
    time('dock_in_at', dockInAt, original.dockInAt);
    time('dock_out_at', dockOutAt, original.dockOutAt);
    time('vehicle_out_at', vehicleOutAt, original.vehicleOutAt);
    text('tat_reason', tatReason, original.tatReason);
    text('tat_remark', tatRemark, original.tatRemark);
    return out;
  }
}

/// "1 h 25 min" / "40 min".
String formatMinutes(int? minutes) {
  if (minutes == null) return '—';
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

/// Shipment details for a trip — Ekatm's Shipment Creation (§8.2).
class DplTripShipmentScreen extends ConsumerStatefulWidget {
  const DplTripShipmentScreen({
    super.key,
    required this.tripId,
    this.tripNumber,
    this.showAppBar = true,
  });

  final int tripId;
  final int? tripNumber;
  final bool showAppBar;

  @override
  ConsumerState<DplTripShipmentScreen> createState() => _DplTripShipmentScreenState();
}

class _DplTripShipmentScreenState extends ConsumerState<DplTripShipmentScreen> {
  final _vehicle = TextEditingController();
  final _driverName = TextEditingController();
  final _driverMobile = TextEditingController();
  final _licence = TextEditingController();
  final _seal = TextEditingController();
  final _lrNo = TextEditingController();
  final _tatOther = TextEditingController();
  final _remark = TextEditingController();

  /// The server's latest copy; the diff is always taken against this.
  DplTripShipment? _server;
  DplShipmentDraft? _original;

  int? _transporterId;
  int? _consigneeId;
  DateTime? _lrDate;
  DateTime? _vehicleIn;
  DateTime? _dockIn;
  DateTime? _dockOut;
  DateTime? _vehicleOut;
  String? _tatChoice;

  /// Bumped whenever the form is reset from the server, to rebuild dropdowns.
  int _epoch = 0;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_vehicle, _driverName, _driverMobile, _licence, _seal, _lrNo, _tatOther, _remark]) {
      c.dispose();
    }
    super.dispose();
  }

  void _resetFrom(DplTripShipment s) {
    final d = DplShipmentDraft.fromShipment(s);
    _server = s;
    _original = d;
    _transporterId = d.transporterId;
    _consigneeId = d.consigneeId;
    _vehicle.text = d.vehicleNo ?? '';
    _driverName.text = d.driverName ?? '';
    _driverMobile.text = d.driverMobile ?? '';
    _licence.text = d.driverLicenceNo ?? '';
    _seal.text = d.sealNo ?? '';
    _lrNo.text = d.lrNo ?? '';
    _lrDate = d.lrDate;
    _vehicleIn = d.vehicleInAt;
    _dockIn = d.dockInAt;
    _dockOut = d.dockOutAt;
    _vehicleOut = d.vehicleOutAt;
    final reason = d.tatReason?.trim() ?? '';
    if (reason.isEmpty) {
      _tatChoice = null;
      _tatOther.text = '';
    } else if (kTatReasons.contains(reason)) {
      _tatChoice = reason;
      _tatOther.text = '';
    } else {
      _tatChoice = kTatOther;
      _tatOther.text = reason;
    }
    _remark.text = d.tatRemark ?? '';
    _epoch++;
  }

  DplShipmentDraft _draft() => DplShipmentDraft(
        transporterId: _transporterId,
        consigneeId: _consigneeId,
        vehicleNo: _vehicle.text,
        driverName: _driverName.text,
        driverMobile: _driverMobile.text,
        driverLicenceNo: _licence.text,
        sealNo: _seal.text,
        lrNo: _lrNo.text,
        lrDate: _lrDate,
        vehicleInAt: _vehicleIn,
        dockInAt: _dockIn,
        dockOutAt: _dockOut,
        vehicleOutAt: _vehicleOut,
        tatReason: _tatChoice == kTatOther ? _tatOther.text : _tatChoice,
        tatRemark: _remark.text,
      );

  Map<String, dynamic> get _changes =>
      _original == null ? const {} : _draft().changesFrom(_original!);

  Future<void> _save() async {
    final changes = _changes;
    if (changes.isEmpty) {
      DplSnacks.info(context, 'Nothing has changed.');
      return;
    }
    setState(() => _saving = true);
    final res = await ref.read(dplApiServiceProvider).updateTripShipment(widget.tripId, changes);
    if (!mounted) return;
    setState(() => _saving = false);
    if (res.isError || res.data == null) {
      showFloorError(context, res, fallback: 'Could not save the shipment details.');
      return;
    }
    setState(() => _resetFrom(res.data!));
    DplSnacks.success(context, 'Shipment details saved.');
  }

  Future<DateTime?> _pickDateTime(DateTime? current) async {
    final now = DateTime.now();
    final base = (current ?? now).toLocal();
    final date = await showDatePicker(
      context: context,
      initialDate: base.isAfter(now) ? now : base,
      firstDate: DateTime(now.year - 1),
      lastDate: now,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(base));
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(tripShipmentProvider(widget.tripId));
    final title = widget.tripNumber == null ? 'Shipment details' : 'Shipment · Trip #${widget.tripNumber}';

    final body = async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => DplInlineErrorRetry(
        message: e.toString(),
        onRetry: () => ref.invalidate(tripShipmentProvider(widget.tripId)),
      ),
      data: (res) {
        if (res.isError || res.data == null) {
          return DplInlineErrorRetry(
            message: res.floorMessage.isEmpty ? 'Could not load the shipment details.' : res.floorMessage,
            onRetry: () => ref.invalidate(tripShipmentProvider(widget.tripId)),
          );
        }
        if (_original == null) _resetFrom(res.data!);
        return _form();
      },
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(title: title),
      body: body,
    );
  }

  Widget _form() {
    final canEdit = ref.watch(dplPermissionsProvider).can(DplPermission.tripsShipment);
    final transportersRes = ref.watch(logisticsTransportersProvider).value;
    final consigneesRes = ref.watch(logisticsConsigneesProvider).value;
    final transporters = transportersRes?.data ?? const <DplTransporter>[];
    final consignees = consigneesRes?.data ?? const <DplConsignee>[];
    // Only call a saved pick "inactive" once the active list has actually loaded.
    final tInactive = transportersRes?.isOk == true ? ' (inactive)' : '';
    final cInactive = consigneesRes?.isOk == true ? ' (inactive)' : '';
    final s = _server!;
    final dirty = _changes.isNotEmpty;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(DplSpacing.md),
            children: [
              if (!canEdit)
                Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('View only — you can see these details but not change them.',
                      style: TextStyle(color: DplColors.textSecondary, fontSize: 12.5)),
                ),
              _section('Transport', [
                _dropdown<int>(
                  label: 'Transporter',
                  value: _transporterId,
                  enabled: canEdit,
                  items: {
                    for (final t in transporters) t.id: t.name,
                    if (s.transporter != null && !transporters.any((t) => t.id == s.transporter!.id))
                      s.transporter!.id: '${s.transporter!.name}$tInactive',
                  },
                  onChanged: (v) => setState(() => _transporterId = v),
                ),
                _dropdown<int>(
                  label: 'Consignee (ship to)',
                  value: _consigneeId,
                  enabled: canEdit,
                  items: {
                    for (final c in consignees) c.id: c.city == null ? c.name : '${c.name} · ${c.city}',
                    if (s.consignee != null && !consignees.any((c) => c.id == s.consignee!.id))
                      s.consignee!.id: '${s.consignee!.name}$cInactive',
                  },
                  onChanged: (v) => setState(() => _consigneeId = v),
                ),
                _text(_vehicle, 'Vehicle no', canEdit, upper: true, hint: 'MH14 GD 4521'),
                _text(_driverName, 'Driver name', canEdit),
                _text(_driverMobile, 'Driver mobile', canEdit, keyboard: TextInputType.phone),
                _text(_licence, 'Driving licence no', canEdit, upper: true),
              ]),
              _section('Documents', [
                _text(_seal, 'Seal no', canEdit, upper: true),
                _text(_lrNo, 'LR no', canEdit, upper: true),
                _dateRow(canEdit),
              ]),
              _section('Times', [
                _timeRow('Vehicle in', _vehicleIn, canEdit, (v) => setState(() => _vehicleIn = v)),
                _timeRow('Dock in', _dockIn, canEdit, (v) => setState(() => _dockIn = v)),
                _timeRow('Dock out', _dockOut, canEdit, (v) => setState(() => _dockOut = v)),
                _timeRow('Vehicle out', _vehicleOut, canEdit, (v) => setState(() => _vehicleOut = v)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 6, children: [
                  _minutesChip('At dock', s.minutesAtDock),
                  _minutesChip('In plant', s.minutesInPlant),
                ]),
                const SizedBox(height: 4),
                Text('Times must run vehicle in → dock in → dock out → vehicle out.',
                    style: TextStyle(fontSize: 11.5, color: DplColors.textSecondary)),
              ]),
              _section('Turnaround (TAT)', [
                _dropdown<String>(
                  label: 'TAT reason',
                  value: _tatChoice,
                  enabled: canEdit,
                  items: {for (final r in [...kTatReasons, kTatOther]) r: r},
                  onChanged: (v) => setState(() => _tatChoice = v),
                ),
                if (_tatChoice == kTatOther) _text(_tatOther, 'Other reason', canEdit),
                _text(_remark, 'Remark', canEdit, maxLines: 3),
              ]),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => DplGatePassScreen(tripId: widget.tripId),
                    )),
                    icon: const Icon(Icons.receipt_long_outlined, size: 18),
                    label: const Text('Gate pass'),
                  ),
                ),
                if (canEdit) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving || !dirty ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.save_outlined, size: 18),
                      label: Text(dirty ? 'Save (${_changes.length})' : 'Saved'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _section(String title, List<Widget> children) => DplCard(
        margin: const EdgeInsets.only(bottom: DplSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 8),
            for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 10), child: c),
          ],
        ),
      );

  Widget _text(TextEditingController c, String label, bool enabled,
      {bool upper = false, String? hint, TextInputType? keyboard, int maxLines = 1}) {
    return TextField(
      controller: c,
      enabled: enabled,
      maxLines: maxLines,
      keyboardType: keyboard,
      textCapitalization: upper ? TextCapitalization.characters : TextCapitalization.sentences,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(labelText: label, hintText: hint, isDense: true, border: const OutlineInputBorder()),
    );
  }

  Widget _dropdown<T>({
    required String label,
    required T? value,
    required bool enabled,
    required Map<T, String> items,
    required ValueChanged<T?> onChanged,
  }) {
    return DropdownButtonFormField<T?>(
      key: ValueKey('$label-$_epoch'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
      items: [
        DropdownMenuItem<T?>(value: null, child: const Text('— none —')),
        for (final e in items.entries)
          DropdownMenuItem<T?>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }

  Widget _dateRow(bool enabled) {
    return InputDecorator(
      decoration: const InputDecoration(labelText: 'LR date', isDense: true, border: OutlineInputBorder()),
      child: Row(
        children: [
          Expanded(child: Text(_lrDate == null ? '—' : DateFormat('d MMM yyyy').format(_lrDate!))),
          if (enabled) ...[
            IconButton(
              tooltip: 'Pick date',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.calendar_today_outlined, size: 18),
              onPressed: () async {
                final now = DateTime.now();
                final d = await showDatePicker(
                  context: context,
                  initialDate: _lrDate ?? now,
                  firstDate: DateTime(now.year - 1),
                  lastDate: DateTime(now.year + 1),
                );
                if (d != null) setState(() => _lrDate = d);
              },
            ),
            if (_lrDate != null)
              IconButton(
                tooltip: 'Clear',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(() => _lrDate = null),
              ),
          ],
        ],
      ),
    );
  }

  Widget _timeRow(String label, DateTime? value, bool enabled, ValueChanged<DateTime?> onChanged) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
      child: Row(
        children: [
          Expanded(
            child: Text(value == null ? '—' : DateFormat('d MMM, HH:mm').format(value.toLocal()),
                style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
          ),
          if (enabled) ...[
            TextButton(
              onPressed: () => onChanged(DateTime.now()),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: const Text('Now'),
            ),
            IconButton(
              tooltip: 'Pick date and time',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.schedule, size: 18),
              onPressed: () async {
                final v = await _pickDateTime(value);
                if (v != null) onChanged(v);
              },
            ),
            if (value != null)
              IconButton(
                tooltip: 'Clear',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => onChanged(null),
              ),
          ],
        ],
      ),
    );
  }

  Widget _minutesChip(String label, int? minutes) => Chip(
        visualDensity: VisualDensity.compact,
        avatar: const Icon(Icons.timer_outlined, size: 16),
        label: Text('$label: ${formatMinutes(minutes)}', style: const TextStyle(fontWeight: FontWeight.w600)),
      );
}
