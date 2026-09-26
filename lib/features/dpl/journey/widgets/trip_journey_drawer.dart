import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../models/dpl_trip_journey_event.dart';

/// Vertical stepper showing all 5 possible post-dispatch journey events
/// for a trip. Manager / Dispatch / DEO / QA / PDI can read this; the
/// three journey actors (Security / QRE / Driver) can also read it for
/// their own trip context.
///
/// Each step renders as:
///   • filled icon + timestamp + actor when the event exists
///   • empty icon + "Pending" when it doesn't
///   • payload badges below the row when relevant
///     (leci_no + truck for tata_gate_in, empty_trolley_count for
///      tata_dock_out)
///
/// Pull-to-refresh re-fetches from GET /dispatch/trips/:id/journey.
class TripJourneyDrawer extends ConsumerStatefulWidget {
  final int tripId;
  final int? tripNumber;
  final String? plantName;
  final String? vehicleNo;

  const TripJourneyDrawer({
    super.key,
    required this.tripId,
    this.tripNumber,
    this.plantName,
    this.vehicleNo,
  });

  @override
  ConsumerState<TripJourneyDrawer> createState() => _TripJourneyDrawerState();
}

class _TripJourneyDrawerState extends ConsumerState<TripJourneyDrawer> {
  static const _stages = <String>[
    'gate_out',
    'tata_gate_in',
    'tata_dock_in',
    'tata_dock_out',
    'tata_gate_out',
    'gate_in',
  ];

  Future<List<DplTripJourneyEvent>>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<DplTripJourneyEvent>> _load() async {
    final api = ref.read(dplApiServiceProvider);
    final res = await api.listTripJourney(widget.tripId);
    if (res.isError) {
      throw Exception(res.error ?? 'Failed to load journey');
    }
    return res.data ?? const <DplTripJourneyEvent>[];
  }

  Future<void> _refresh() async {
    final fresh = _load();
    setState(() => _future = fresh);
    await fresh;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        decoration: BoxDecoration(
          color: DplColors.pageBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: DplColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.tripNumber != null
                              ? 'Trip #${widget.tripNumber} · Journey'
                              : 'Trip Journey',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: DplColors.textPrimary,
                          ),
                        ),
                        if ((widget.plantName ?? '').isNotEmpty ||
                            (widget.vehicleNo ?? '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              [
                                if ((widget.plantName ?? '').isNotEmpty)
                                  widget.plantName,
                                if ((widget.vehicleNo ?? '').isNotEmpty)
                                  widget.vehicleNo,
                              ].whereType<String>().join(' · '),
                              style: TextStyle(
                                fontSize: 12,
                                color: DplColors.textSecondary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh_rounded),
                    onPressed: _refresh,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    return FutureBuilder<List<DplTripJourneyEvent>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline,
                    color: DplColors.error, size: 40),
                const SizedBox(height: 12),
                Text(
                  snap.error.toString().replaceFirst('Exception: ', ''),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: DplColors.textSecondary),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _refresh,
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        final events = snap.data ?? const <DplTripJourneyEvent>[];
        final byEvent = <String, DplTripJourneyEvent>{
          for (final e in events) e.event: e,
        };
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            itemCount: _stages.length,
            itemBuilder: (_, i) => _stageTile(
              stage: _stages[i],
              event: byEvent[_stages[i]],
              isLast: i == _stages.length - 1,
            ),
          ),
        );
      },
    );
  }

  Widget _stageTile({
    required String stage,
    required DplTripJourneyEvent? event,
    required bool isLast,
  }) {
    final done = event != null;
    final title = _stageTitle(stage);
    final dotColor = done ? DplColors.success : DplColors.divider;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Column(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: done ? DplColors.success : DplColors.cardBg,
                    border: Border.all(color: dotColor, width: 2),
                    shape: BoxShape.circle,
                  ),
                  child: done
                      ? const Icon(Icons.check,
                          color: Colors.white, size: 18)
                      : null,
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: DplColors.divider,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(bottom: isLast ? 8 : 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: done
                            ? DplColors.textPrimary
                            : DplColors.textSecondary,
                      ),
                    ),
                    if (done) ...[
                      const SizedBox(height: 2),
                      Text(
                        _formatTime(event.occurredAt),
                        style: TextStyle(
                          fontSize: 12,
                          color: DplColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${event.actorName} · ${_roleLabel(event.actorRole)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: DplColors.textSecondary,
                        ),
                      ),
                      ..._payloadBadges(event),
                    ] else
                      Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text(
                          'Pending',
                          style: TextStyle(
                            fontSize: 12,
                            color: DplColors.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _payloadBadges(DplTripJourneyEvent event) {
    final chips = <Widget>[];
    final p = event.typedPayload;
    if (event.event == 'tata_gate_in') {
      final leci = p.leciNo;
      final truck = p.leciTruckNo;
      final v = event.payload['verified'];
      if ((leci ?? '').isNotEmpty) chips.add(_chip('LECI #$leci'));
      if ((truck ?? '').isNotEmpty) chips.add(_chip('Truck $truck'));
      if (v == true) chips.add(_chip('Verified', color: DplColors.success));
    } else if (event.event == 'tata_dock_out') {
      final n = p.emptyTrolleyCount;
      if (n != null) chips.add(_chip('$n empty trolley${n == 1 ? '' : 's'}'));
      final r = p.remarks;
      if ((r ?? '').isNotEmpty) chips.add(_chip('Note: $r'));
    }
    if (chips.isEmpty) return const [];
    return [
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 4, children: chips),
    ];
  }

  Widget _chip(String text, {Color? color}) {
    final c = color ?? DplColors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        border: Border.all(color: c.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: c,
        ),
      ),
    );
  }

  String _stageTitle(String stage) {
    switch (stage) {
      case 'gate_out':      return 'Gate Out (Origin plant)';
      case 'tata_gate_in':  return 'TATA — Gate In';
      case 'tata_dock_in':  return 'TATA — Dock In';
      case 'tata_dock_out': return 'TATA — Dock Out';
      case 'tata_gate_out': return 'TATA — Gate Out';
      case 'gate_in':       return 'Return · Origin Gate In';
      default:              return stage;
    }
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'dpl_security': return 'Security';
      case 'dpl_qre':      return 'QRE';
      case 'dpl_driver':   return 'Driver';
      case 'dpl_manager':  return 'Manager';
      default:             return role.replaceAll('dpl_', '').toUpperCase();
    }
  }

  String _formatTime(DateTime? t) {
    if (t == null) return '—';
    final ist = t.toUtc().add(const Duration(hours: 5, minutes: 30));
    return '${DateFormat('dd MMM yyyy · HH:mm').format(ist)} IST';
  }
}

/// Convenience helper that shows the journey drawer as a modal bottom
/// sheet. Call from a trip card / detail screen's "Journey" button.
Future<void> showTripJourneyDrawer(
  BuildContext context, {
  required int tripId,
  int? tripNumber,
  String? plantName,
  String? vehicleNo,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => TripJourneyDrawer(
      tripId: tripId,
      tripNumber: tripNumber,
      plantName: plantName,
      vehicleNo: vehicleNo,
    ),
  );
}
