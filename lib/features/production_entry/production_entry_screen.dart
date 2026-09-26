import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme/vistar_palette.dart';
import '../../core/widgets/shimmer_skeleton.dart';
import '../../data/models/production_entry_model.dart';
import '../auth/auth_provider.dart';
import 'master_data_provider.dart';
import 'production_entry_provider.dart';

class ProductionEntryScreen extends ConsumerStatefulWidget {
  final bool embedded;

  const ProductionEntryScreen({super.key, this.embedded = false});

  @override
  ConsumerState<ProductionEntryScreen> createState() =>
      _ProductionEntryScreenState();
}

class _ProductionEntryScreenState extends ConsumerState<ProductionEntryScreen> {
  final _formKey = GlobalKey<FormState>();

  String _shift = 'A';
  String? _machineId;
  String? _itemId;
  DateTime _startDate = DateTime.now();
  DateTime _endDate = DateTime.now();
  TimeOfDay? _startTime;
  TimeOfDay? _endTime;
  bool _addMachineDowntime = false;
  TimeOfDay? _downtimeStartTime;
  TimeOfDay? _downtimeEndTime;
  final _actualCtrl = TextEditingController();
  final _rejectCtrl = TextEditingController(text: '0');
  final _rcNumberCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final Map<String, int> _rejectionReasons = {};
  final List<TextEditingController> _operatorNameCtrls = [];

  bool _submittedOnce = false;
  String? _formError;
  double _itemWeightG = 0;
  double _runningHours = 0;
  double _partsPerHour = 0;
  double _weightKg = 0;

  static const _fallbackRejectionReasons = [
    'Forging Defects',
    'Rolling Defects',
    'Finishing defects',
    'All Process defect',
  ];

  @override
  void initState() {
    super.initState();
    _actualCtrl.addListener(_recompute);
  }

  @override
  void dispose() {
    _actualCtrl.removeListener(_recompute);
    _actualCtrl.dispose();
    _rejectCtrl.dispose();
    _rcNumberCtrl.dispose();
    _notesCtrl.dispose();
    for (final ctrl in _operatorNameCtrls) {
      ctrl.dispose();
    }
    super.dispose();
  }

  void _addOperatorField() {
    setState(() {
      _operatorNameCtrls.add(TextEditingController());
    });
  }

  void _removeOperatorField(int index) {
    if (index < 0 || index >= _operatorNameCtrls.length) return;
    final removed = _operatorNameCtrls.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  List<String> _collectOperatorNames() {
    final names = <String>[];
    for (final ctrl in _operatorNameCtrls) {
      final text = ctrl.text.trim();
      if (text.isNotEmpty) names.add(text);
    }
    return names;
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime ?? TimeOfDay.now(),
    );
    if (picked == null) return;
    setState(() {
      _startTime = picked;
      _formError = null;
    });
    _recompute();
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime ?? TimeOfDay.now(),
    );
    if (picked == null) return;
    setState(() {
      _endTime = picked;
      _formError = null;
    });
    _recompute();
  }

  Future<void> _pickStartDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) return;
    setState(() {
      _startDate = DateTime(picked.year, picked.month, picked.day);
      if (_endDate.isBefore(_startDate)) {
        _endDate = _startDate;
      }
      _formError = null;
    });
    _recompute();
  }

  Future<void> _pickEndDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate.isBefore(_startDate) ? _startDate : _endDate,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) return;
    setState(() {
      _endDate = DateTime(picked.year, picked.month, picked.day);
      _formError = null;
    });
    _recompute();
  }

  void _resetForm() {
    for (final ctrl in _operatorNameCtrls) {
      ctrl.dispose();
    }
    _operatorNameCtrls.clear();
    final today = DateTime.now();
    setState(() {
      _shift = 'A';
      _machineId = null;
      _itemId = null;
      _startDate = DateTime(today.year, today.month, today.day);
      _endDate = DateTime(today.year, today.month, today.day);
      _startTime = null;
      _endTime = null;
      _addMachineDowntime = false;
      _downtimeStartTime = null;
      _downtimeEndTime = null;
      _actualCtrl.clear();
      _rejectCtrl.text = '0';
      _rcNumberCtrl.clear();
      _notesCtrl.clear();
      _rejectionReasons.clear();
      _itemWeightG = 0;
      _runningHours = 0;
      _partsPerHour = 0;
      _weightKg = 0;
      _submittedOnce = false;
      _formError = null;
    });
  }

  int _safeInt(String v) => int.tryParse(v.trim()) ?? 0;

  DateTime? _toDate(TimeOfDay? t, DateTime date) {
    if (t == null) return null;
    return DateTime(date.year, date.month, date.day, t.hour, t.minute);
  }

  DateTime? _shiftStart() => _toDate(_startTime, _startDate);
  DateTime? _shiftEnd() => _toDate(_endTime, _endDate);

  DateTime? _inferDowntimeDateTime(TimeOfDay? t) {
    if (t == null) return null;
    final sameDay = _startDate.year == _endDate.year &&
        _startDate.month == _endDate.month &&
        _startDate.day == _endDate.day;
    if (sameDay || _startTime == null) {
      return _toDate(t, _startDate);
    }
    final startMins = _startTime!.hour * 60 + _startTime!.minute;
    final tMins = t.hour * 60 + t.minute;
    return _toDate(t, tMins >= startMins ? _startDate : _endDate);
  }

  bool _isTimeValid() {
    final s = _shiftStart();
    final e = _shiftEnd();
    if (s == null || e == null) return false;
    return e.isAfter(s);
  }

  bool _isDowntimeWithinShift() {
    if (!_addMachineDowntime) return true;

    final shiftStart = _shiftStart();
    final shiftEnd = _shiftEnd();
    final downtimeStart = _inferDowntimeDateTime(_downtimeStartTime);
    final downtimeEnd = _inferDowntimeDateTime(_downtimeEndTime);

    if (shiftStart == null ||
        shiftEnd == null ||
        downtimeStart == null ||
        downtimeEnd == null) {
      return false;
    }

    if (!shiftEnd.isAfter(shiftStart)) return false;
    if (!downtimeEnd.isAfter(downtimeStart)) return false;

    final startsInRange =
        !downtimeStart.isBefore(shiftStart) && !downtimeStart.isAfter(shiftEnd);
    final endsInRange =
        !downtimeEnd.isBefore(shiftStart) && !downtimeEnd.isAfter(shiftEnd);

    return startsInRange && endsInRange;
  }

  String? _timeError() {
    if (_startTime == null || _endTime == null) {
      return 'Start Time and End Time are required.';
    }
    if (!_isTimeValid()) {
      return 'End date/time must be greater than Start date/time.';
    }
    if (_addMachineDowntime) {
      if (_downtimeStartTime == null || _downtimeEndTime == null) {
        return 'Both Downtime Start and Downtime End are required when downtime is enabled.';
      }
      final downtimeStart = _inferDowntimeDateTime(_downtimeStartTime);
      final downtimeEnd = _inferDowntimeDateTime(_downtimeEndTime);
      if (downtimeStart == null || downtimeEnd == null) {
        return 'Invalid downtime values.';
      }
      if (!downtimeEnd.isAfter(downtimeStart)) {
        return 'Downtime End must be greater than Downtime Start.';
      }
      if (!_isDowntimeWithinShift()) {
        return 'Downtime must be within Shift Start and Shift End.';
      }
    }
    return null;
  }

  void _recompute() {
    final controller = ref.read(productionEntryControllerProvider.notifier);
    final actual = _safeInt(_actualCtrl.text);
    if (_isTimeValid()) {
      final useDowntime = _addMachineDowntime && _isDowntimeWithinShift();
      _runningHours = controller.calculateRunningHours(
        _startTime!,
        _endTime!,
        downtimeStart: useDowntime ? _downtimeStartTime : null,
        downtimeEnd: useDowntime ? _downtimeEndTime : null,
      );
      _partsPerHour = controller.calculatePartsPerHour(actual, _runningHours);
    } else {
      _runningHours = 0;
      _partsPerHour = 0;
    }
    _weightKg = controller.calculateWeightInKGs(actual, _itemWeightG);
    if (mounted) setState(() {});
  }

  String? _reqDrop(String? v, String name) =>
      (v == null || v.trim().isEmpty) ? '$name is required.' : null;

  String? _qty(String? v, String name) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return '$name is required.';
    if (!RegExp(r'^\d+$').hasMatch(t)) return 'Enter a valid number.';
    return null;
  }

  String? _operatorNameValidator(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return 'Operator name cannot be empty.';
    return null;
  }

  String _err(Object e) {
    final s = e.toString();
    return s.startsWith('Exception:')
        ? s.substring('Exception:'.length).trim()
        : s;
  }

  Future<void> _pickDowntime(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _downtimeStartTime = picked;
      } else {
        _downtimeEndTime = picked;
      }
      _formError = null;
    });
    _recompute();
  }

  Future<void> _showReasonDialog({required List<String> reasons}) async {
    final availableReasons = reasons
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (availableReasons.isEmpty) {
      availableReasons.addAll(_fallbackRejectionReasons);
    }

    final draft = Map<String, int>.from(_rejectionReasons);
    final actual = _safeInt(_actualCtrl.text);
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialog) {
            int total = 0;
            for (final v in draft.values) {
              total += v;
            }
            final invalid = total > actual;
            final maxContentHeight = MediaQuery.of(context).size.height * 0.45;
            return AlertDialog(
              title: const Text('Rejection Details'),
              content: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxContentHeight),
                child: SizedBox(
                  width: 360,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final r in availableReasons)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(
                              children: [
                                Expanded(child: Text(r)),
                                SizedBox(
                                  width: 88,
                                  child: TextFormField(
                                    initialValue: (draft[r] ?? 0).toString(),
                                    textAlign: TextAlign.center,
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [
                                      FilteringTextInputFormatter.digitsOnly,
                                    ],
                                    onChanged: (v) {
                                      final p = int.tryParse(v) ?? 0;
                                      setDialog(() {
                                        if (p <= 0) {
                                          draft.remove(r);
                                        } else {
                                          draft[r] = p;
                                        }
                                      });
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          'Total: $total / Actual: $actual',
                          style: TextStyle(
                            color: invalid ? VistarPalette.bad : VistarPalette.ok,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (invalid)
                          Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Text(
                              'Rejection Quantity cannot exceed Actual Quantity.',
                              style: TextStyle(color: VistarPalette.bad),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: invalid
                      ? null
                      : () {
                          setState(() {
                            _rejectionReasons
                              ..clear()
                              ..addAll(draft);
                            int t = 0;
                            for (final v in _rejectionReasons.values) {
                              t += v;
                            }
                            _rejectCtrl.text = '$t';
                          });
                          Navigator.pop(ctx);
                        },
                  child: const Text('Apply'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _submittedOnce = true;
      _formError = null;
    });
    _recompute();

    if (!(_formKey.currentState?.validate() ?? false)) {
      setState(
        () => _formError =
            'Mandatory fields must not be empty and numeric fields must be valid.',
      );
      return;
    }
    final timeError = _timeError();
    if (timeError != null) {
      setState(() => _formError = timeError);
      return;
    }

    final actual = _safeInt(_actualCtrl.text);
    final reject = _safeInt(_rejectCtrl.text);
    if (reject > actual) {
      setState(
        () => _formError = 'Rejection Quantity cannot exceed Actual Quantity.',
      );
      return;
    }
    final rejectionDetailTotal = _rejectionReasons.values.fold<int>(
      0,
      (sum, qty) => sum + qty,
    );
    if (_rejectionReasons.isNotEmpty && rejectionDetailTotal != reject) {
      setState(
        () => _formError =
            'Rejection details total ($rejectionDetailTotal) must match Rejection Quantity ($reject).',
      );
      return;
    }

    final s = _shiftStart()!;
    final e = _shiftEnd()!;
    final auth = ref.read(authControllerProvider).asData?.value;
    final rcNumber = _rcNumberCtrl.text.trim();
    final operatorNames = _collectOperatorNames();
    final operatorNameJoined = operatorNames.isNotEmpty
        ? operatorNames.join(', ')
        : null;

    final entry = ProductionEntryModel(
      entryDate: DateFormat('yyyy-MM-dd').format(_startDate),
      shift: _shift,
      operatorId: auth?.id ?? 'unknown',
      operatorName: operatorNameJoined,
      operatorNames: operatorNames,
      machineId: _machineId!,
      itemId: _itemId!,
      ccd1Quantity: 0,
      actualQuantity: actual,
      rejectionQuantity: reject,
      startTime: s.toUtc().toIso8601String(),
      endTime: e.toUtc().toIso8601String(),
      rcNumber: rcNumber.isEmpty ? null : rcNumber,
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      machineDowntimeStartTime:
          _addMachineDowntime && _downtimeStartTime != null
          ? _inferDowntimeDateTime(_downtimeStartTime)!.toUtc().toIso8601String()
          : null,
      machineDowntimeEndTime: _addMachineDowntime && _downtimeEndTime != null
          ? _inferDowntimeDateTime(_downtimeEndTime)!.toUtc().toIso8601String()
          : null,
      rejectionDetails: _rejectionReasons.entries
          .where((e) => e.value > 0)
          .map((e) => RejectionDetailModel(reason: e.key, quantity: e.value))
          .toList(),
    );

    await ref
        .read(productionEntryControllerProvider.notifier)
        .submitEntry(entry);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(productionEntryControllerProvider, (prev, next) async {
      if (!mounted) return;
      if (prev?.isLoading == true && next.hasError) {
        setState(() => _formError = _err(next.error!));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_err(next.error!))));
      }
      if (prev?.isLoading == true && next.hasValue) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Production entry submitted successfully.'),
            ),
          );
          if (widget.embedded) {
            _resetForm();
          } else {
            context.pop();
          }
        }
      }
    });

    final submitState = ref.watch(productionEntryControllerProvider);
    final masterData = ref.watch(masterDataControllerProvider);

    final content = masterData.when(
      loading: () =>
          const ShimmerCenteredPlaceholder(titleWidth: 220, subtitleWidth: 150),
      error: (e, _) => Center(child: Text(_err(e))),
      data: (d) => Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [VistarPalette.bg, VistarPalette.bg2, VistarPalette.bg],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -90,
              right: -40,
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  color: VistarPalette.info.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Positioned(
              bottom: -100,
              left: -30,
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  color: VistarPalette.ok.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: VistarPalette.surface.withValues(alpha: 0.50),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: VistarPalette.surface.withValues(alpha: 0.8)),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0F3A8A).withValues(alpha: 0.10),
                          blurRadius: 22,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Form(
                      key: _formKey,
                      autovalidateMode: _submittedOnce
                          ? AutovalidateMode.onUserInteraction
                          : AutovalidateMode.disabled,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _HeadCard(),
                          if (_formError != null) ...[
                            const SizedBox(height: 12),
                            _ErrorBanner(message: _formError!),
                          ],
                          const SizedBox(height: 12),
                          _Section(
                            title: 'Basic Details',
                            child: Column(
                              children: [
                                DropdownButtonFormField<String>(
                                  key: ValueKey('shift_$_shift'),
                                  initialValue: _shift,
                                  decoration: const InputDecoration(
                                    labelText: 'Shift *',
                                    prefixIcon: Icon(Icons.schedule_outlined),
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'A',
                                      child: Text('Shift A'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'B',
                                      child: Text('Shift B'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'C',
                                      child: Text('Shift C'),
                                    ),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => _shift = v ?? 'A'),
                                ),
                                const SizedBox(height: 10),
                                _SearchableDropdownFormField(
                                  key: ValueKey('machine_${_machineId ?? ''}'),
                                  value: _machineId,
                                  labelText: 'Machine *',
                                  prefixIcon:
                                      Icons.precision_manufacturing_outlined,
                                  hintText: '',
                                  options: d.machines
                                      .map(
                                        (m) => _SelectOption(
                                          value: m.id,
                                          label:
                                              '${m.machineNumber} - ${m.name}',
                                        ),
                                      )
                                      .toList(),
                                  enabled: true,
                                  onChanged: (v) =>
                                      setState(() => _machineId = v),
                                  validator: (v) => _reqDrop(v, 'Machine'),
                                ),
                                const SizedBox(height: 10),
                                _SearchableDropdownFormField(
                                  key: ValueKey('item_${_itemId ?? ''}'),
                                  value: _itemId,
                                  labelText: 'Item *',
                                  prefixIcon: Icons.inventory_2_outlined,
                                  hintText: '',
                                  options: d.items
                                      .map(
                                        (i) => _SelectOption(
                                          value: i.id,
                                          label:
                                              '${i.itemCode} - ${i.description}',
                                        ),
                                      )
                                      .toList(),
                                  enabled: true,
                                  onChanged: (v) {
                                    var weight = 0.0;
                                    for (final i in d.items) {
                                      if (i.id == v) {
                                        weight = i.finishWeightG;
                                        break;
                                      }
                                    }
                                    setState(() {
                                      _itemId = v;
                                      _itemWeightG = weight;
                                    });
                                    _recompute();
                                  },
                                  validator: (v) => _reqDrop(v, 'Item'),
                                ),
                                const SizedBox(height: 10),
                                TextFormField(
                                  controller: _rcNumberCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'RC Number',
                                    prefixIcon: Icon(
                                      Icons.confirmation_number_outlined,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          _Section(
                            title: 'Operators (Optional)',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Padding(
                                  padding: EdgeInsets.only(bottom: 8),
                                  child: Text(
                                    'Add one or more operators working this shift.',
                                    style: TextStyle(color: VistarPalette.txt2),
                                  ),
                                ),
                                if (_operatorNameCtrls.isEmpty)
                                  Padding(
                                    padding: EdgeInsets.only(bottom: 8),
                                    child: Text(
                                      'No operators added yet.',
                                      style: TextStyle(
                                        color: VistarPalette.txt3,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ),
                                for (
                                  int i = 0;
                                  i < _operatorNameCtrls.length;
                                  i++
                                )
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: TextFormField(
                                            controller: _operatorNameCtrls[i],
                                            textCapitalization:
                                                TextCapitalization.words,
                                            decoration: InputDecoration(
                                              labelText:
                                                  'Operator ${i + 1} *',
                                              prefixIcon: const Icon(
                                                Icons.person_outline,
                                              ),
                                            ),
                                            validator: _operatorNameValidator,
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: 'Remove operator',
                                          onPressed: () =>
                                              _removeOperatorField(i),
                                          icon: Icon(
                                            Icons.remove_circle_outline,
                                            color: VistarPalette.bad,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: OutlinedButton.icon(
                                    onPressed: _addOperatorField,
                                    icon: const Icon(Icons.person_add_alt_1),
                                    label: const Text('Add Operator'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          _Section(
                            title: 'Time & Quantity',
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          minimumSize: const Size.fromHeight(
                                            52,
                                          ),
                                          alignment: Alignment.centerLeft,
                                        ),
                                        onPressed: _pickStartDate,
                                        icon: const Icon(
                                          Icons.calendar_today_outlined,
                                        ),
                                        label: Text(
                                          'Start Date: ${DateFormat('dd MMM yyyy').format(_startDate)}',
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          minimumSize: const Size.fromHeight(
                                            52,
                                          ),
                                          alignment: Alignment.centerLeft,
                                        ),
                                        onPressed: _pickEndDate,
                                        icon: const Icon(
                                          Icons.calendar_today_outlined,
                                        ),
                                        label: Text(
                                          'End Date: ${DateFormat('dd MMM yyyy').format(_endDate)}',
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          minimumSize: const Size.fromHeight(
                                            52,
                                          ),
                                          alignment: Alignment.centerLeft,
                                        ),
                                        onPressed: _pickStartTime,
                                        icon: const Icon(
                                          Icons.login_outlined,
                                        ),
                                        label: Text(
                                          _startTime == null
                                              ? 'Start Time *'
                                              : _startTime!.format(context),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          minimumSize: const Size.fromHeight(
                                            52,
                                          ),
                                          alignment: Alignment.centerLeft,
                                        ),
                                        onPressed: _pickEndTime,
                                        icon: const Icon(
                                          Icons.logout_outlined,
                                        ),
                                        label: Text(
                                          _endTime == null
                                              ? 'End Time *'
                                              : _endTime!.format(context),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (_submittedOnce && _timeError() != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        _timeError()!,
                                        style: TextStyle(
                                          color: VistarPalette.bad,
                                        ),
                                      ),
                                    ),
                                  ),
                                SwitchListTile(
                                  title: const Text(
                                    'Add Machine Downtime',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  value: _addMachineDowntime,
                                  onChanged: (v) {
                                    setState(() {
                                      _addMachineDowntime = v;
                                      if (!v) {
                                        _downtimeStartTime = null;
                                        _downtimeEndTime = null;
                                      }
                                    });
                                    _recompute();
                                  },
                                  contentPadding: EdgeInsets.zero,
                                ),
                                if (_addMachineDowntime) ...[
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          style: OutlinedButton.styleFrom(
                                            minimumSize:
                                                const Size.fromHeight(52),
                                            alignment: Alignment.centerLeft,
                                          ),
                                          onPressed: () =>
                                              _pickDowntime(true),
                                          icon: const Icon(
                                            Icons.timer_off_outlined,
                                          ),
                                          label: Text(
                                            _downtimeStartTime == null
                                                ? 'Downtime Start *'
                                                : _downtimeStartTime!.format(
                                                    context,
                                                  ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          style: OutlinedButton.styleFrom(
                                            minimumSize:
                                                const Size.fromHeight(52),
                                            alignment: Alignment.centerLeft,
                                          ),
                                          onPressed: () =>
                                              _pickDowntime(false),
                                          icon: const Icon(
                                            Icons.timer_off_outlined,
                                          ),
                                          label: Text(
                                            _downtimeEndTime == null
                                                ? 'Downtime End *'
                                                : _downtimeEndTime!.format(
                                                    context,
                                                  ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                ],
                                const SizedBox(height: 10),
                                TextFormField(
                                  controller: _actualCtrl,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  decoration: const InputDecoration(
                                    labelText: 'Actual Quantity *',
                                    hintText: 'Enter produced units',
                                    prefixIcon: Icon(Icons.pin_outlined),
                                  ),
                                  validator: (v) =>
                                      _qty(v, 'Actual Quantity'),
                                ),
                                const SizedBox(height: 10),
                                TextFormField(
                                  controller: _rejectCtrl,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  decoration: const InputDecoration(
                                    labelText: 'Rejection Quantity *',
                                    hintText: 'Enter rejected units',
                                    prefixIcon: Icon(
                                      Icons.warning_amber_outlined,
                                    ),
                                  ),
                                  validator: (v) =>
                                      _qty(v, 'Rejection Quantity') ??
                                      (() {
                                        final r = _safeInt(v ?? '');
                                        final a = _safeInt(_actualCtrl.text);
                                        return r > a
                                            ? 'Rejection Quantity cannot exceed Actual Quantity.'
                                            : null;
                                      })(),
                                ),
                                const SizedBox(height: 10),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: OutlinedButton.icon(
                                    onPressed: () => _showReasonDialog(
                                      reasons: d.rejectionReasons,
                                    ),
                                    icon: const Icon(Icons.playlist_add),
                                    label: const Text('Rejection Details'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          _Section(
                            title: 'Auto Calculations',
                            child: Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                _Chip(
                                  label: 'Running Hours',
                                  value: _runningHours.toStringAsFixed(2),
                                ),
                                _Chip(
                                  label: 'Parts / Hour',
                                  value: _partsPerHour.toStringAsFixed(2),
                                ),
                                _Chip(
                                  label: 'Weight (KG)',
                                  value: _weightKg.toStringAsFixed(3),
                                ),
                                _Chip(
                                  label: 'Item Weight (g)',
                                  value: _itemWeightG.toStringAsFixed(2),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          _Section(
                            title: 'Notes (Optional)',
                            child: TextFormField(
                              controller: _notesCtrl,
                              maxLines: 3,
                              decoration: const InputDecoration(
                                labelText: 'Notes',
                                hintText: 'Any special observations',
                                prefixIcon: Icon(Icons.notes_outlined),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          Row(
                            children: [
                              Expanded(
                                flex: 1,
                                child: SizedBox(
                                  height: 52,
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: VistarPalette.bad,
                                      side: BorderSide(
                                        color: VistarPalette.badLine,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(
                                          14,
                                        ),
                                      ),
                                    ),
                                    onPressed: submitState.isLoading
                                        ? null
                                        : _resetForm,
                                    child: const Text('Reset'),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 2,
                                child: SizedBox(
                                  height: 52,
                                  child: FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: VistarPalette.primary,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(
                                          14,
                                        ),
                                      ),
                                    ),
                                    onPressed: submitState.isLoading
                                        ? null
                                        : _submit,
                                    icon: submitState.isLoading
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: Center(
                                              child: ShimmerButtonDots(
                                                size: 6.5,
                                                spacing: 3.5,
                                              ),
                                            ),
                                          )
                                        : const Icon(
                                            Icons.check_circle_outline,
                                          ),
                                    label: Text(
                                      submitState.isLoading
                                          ? 'Submitting...'
                                          : 'Log Shift & Submit',
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (widget.embedded) {
      return content;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Log Production Shift'),
      ),
      body: content,
    );
  }
}

class _SelectOption {
  final String value;
  final String label;

  const _SelectOption({required this.value, required this.label});
}

class _SearchableDropdownFormField extends StatelessWidget {
  final String? value;
  final String labelText;
  final IconData prefixIcon;
  final String hintText;
  final bool enabled;
  final List<_SelectOption> options;
  final ValueChanged<String?>? onChanged;
  final String? Function(String?)? validator;

  const _SearchableDropdownFormField({
    super.key,
    required this.value,
    required this.labelText,
    required this.prefixIcon,
    required this.hintText,
    required this.enabled,
    required this.options,
    required this.onChanged,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return FormField<String>(
      initialValue: value,
      validator: validator,
      builder: (state) {
        final selectedValue = state.value;
        String? selectedLabel;
        for (final option in options) {
          if (option.value == selectedValue) {
            selectedLabel = option.label;
            break;
          }
        }

        final canOpen = enabled && onChanged != null;
        final hasSelection =
            selectedValue != null && selectedValue.trim().isNotEmpty;

        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: !canOpen
              ? null
              : () async {
                  final picked = await showModalBottomSheet<String>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => _SearchableOptionsSheet(
                      title: labelText,
                      selectedValue: selectedValue,
                      options: options,
                    ),
                  );

                  if (picked == null || picked == selectedValue) return;
                  state.didChange(picked);
                  onChanged?.call(picked);
                },
          child: InputDecorator(
            isEmpty: !hasSelection,
            decoration: InputDecoration(
              labelText: labelText,
              prefixIcon: Icon(prefixIcon),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 14,
              ),
              suffixIcon: const Icon(Icons.arrow_drop_down_rounded),
              suffixIconConstraints: const BoxConstraints(
                minWidth: 36,
                minHeight: 36,
              ),
              errorText: state.errorText,
              enabled: canOpen,
            ),
            child: SizedBox(
              width: double.infinity,
              child: Text(
                selectedLabel ?? hintText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(
                  color: hasSelection
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context).hintColor,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SearchableOptionsSheet extends StatefulWidget {
  final String title;
  final String? selectedValue;
  final List<_SelectOption> options;

  const _SearchableOptionsSheet({
    required this.title,
    required this.selectedValue,
    required this.options,
  });

  @override
  State<_SearchableOptionsSheet> createState() =>
      _SearchableOptionsSheetState();
}

class _SearchableOptionsSheetState extends State<_SearchableOptionsSheet> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final filtered = widget.options.where((option) {
      if (q.isEmpty) return true;
      return option.label.toLowerCase().contains(q);
    }).toList();

    final maxHeight = MediaQuery.of(context).size.height * 0.75;
    final insets = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: insets),
        child: SizedBox(
          height: maxHeight,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _searchCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Type to search',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          'No matching results.',
                          style: TextStyle(color: VistarPalette.txt2),
                        ),
                      )
                    : ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final option = filtered[index];
                          final isSelected =
                              option.value == widget.selectedValue;
                          return ListTile(
                            dense: true,
                            title: Text(option.label),
                            trailing: isSelected
                                ? Icon(
                                    Icons.check_rounded,
                                    color: VistarPalette.ok,
                                  )
                                : null,
                            onTap: () =>
                                Navigator.of(context).pop(option.value),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeadCard extends StatelessWidget {
  const _HeadCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: VistarPalette.heroGradient,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF153A8A).withValues(alpha: 0.25),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.factory_outlined, color: Colors.white),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Production Run Entry',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Fill in the shift details, start and end times, operators, and final quantities, then submit in a single step.',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VistarPalette.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: VistarPalette.line),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F3A8A).withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String value;
  const _Chip({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final color = switch (label) {
      'Running Hours' => VistarPalette.info,
      'Parts / Hour' => VistarPalette.ok,
      'Weight (KG)' => const Color(0xFF7A4DCC),
      _ => VistarPalette.warn,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.20)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insights_outlined, size: 16, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 12, color: VistarPalette.txt2),
              ),
              Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: VistarPalette.badBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VistarPalette.badLine),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: VistarPalette.bad),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: VistarPalette.badInk,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
