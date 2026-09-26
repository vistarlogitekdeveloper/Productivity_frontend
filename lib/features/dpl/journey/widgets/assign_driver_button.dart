import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_trip_dispatch_readiness.dart';

/// Compact "Assign driver" pill that renders on the trip card. When the
/// trip has no driver yet it says "Assign Driver"; once assigned it
/// shows the driver's name and tapping opens the same picker for a
/// change (only allowed pre-gate-out per the BE guard).
///
/// The picker is a bottom sheet — fetch drivers on open, tap a row to
/// PATCH /dispatch/trips/:id/driver, snack + onAssigned() callback so
/// the card can refetch its trip.
class AssignDriverButton extends ConsumerWidget {
  final int tripId;
  final String? currentDriverName;
  final Color accent;
  final VoidCallback? onAssigned;

  /// When true the trip has left our plant — the backend blocks
  /// reassignment, so with a driver already set we render a read-only
  /// locked chip instead of a picker that would only 409.
  final bool locked;

  /// Dispatch-completeness of the trip. When non-null and not `ready`, the
  /// button renders as a disabled "why not" chip instead of opening the
  /// picker: the backend rejects assignment on a trip whose slips aren't
  /// all dispatched (`TRIP_NOT_DISPATCHED`), because such a trip can never
  /// gate out and would strand the driver.
  final TripDispatchReadiness? readiness;

  const AssignDriverButton({
    super.key,
    required this.tripId,
    required this.accent,
    this.currentDriverName,
    this.onAssigned,
    this.locked = false,
    this.readiness,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasDriver =
        currentDriverName != null && currentDriverName!.trim().isNotEmpty;

    // Trip has left the plant → the backend blocks reassignment (its guard
    // keys on gate_out / driver_user_id, not the name), so render a read-only
    // chip on `locked` alone. A departed trip always has a driver on file;
    // fall back to a generic label if the name is somehow blank.
    if (locked) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_rounded, size: 16, color: accent),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(
                hasDriver ? currentDriverName!.trim() : 'Driver assigned',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: accent,
                ),
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.lock_rounded,
                size: 12, color: DplColors.textSecondary),
          ],
        ),
      );
    }

    // First assignment onto a trip that isn't dispatch-complete → the backend
    // refuses with TRIP_NOT_DISPATCHED. Don't offer an action that cannot
    // succeed; show why instead, and let a tap explain in full.
    //
    // The `!hasDriver` guard is load-bearing and mirrors the backend, which
    // only applies the readiness check when trip.driver_user_id is null. A
    // trip that ALREADY has a driver stays swappable even when not ready:
    // readiness can regress after a valid assignment (slipping batch 2 puts a
    // fresh pending slip on the trip), and since there is no unassign
    // endpoint, blocking the swap would trap that driver with no way out.
    final r = readiness;
    if (!hasDriver && r != null && !r.ready) {
      return _BlockedChip(reason: r);
    }

    return TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
      icon: Icon(
        hasDriver ? Icons.person_rounded : Icons.person_add_alt_1_rounded,
        size: 16,
      ),
      label: Text(
        hasDriver ? currentDriverName!.trim() : 'Assign Driver',
        overflow: TextOverflow.ellipsis,
      ),
      onPressed: () => _openPicker(context, ref),
    );
  }

  Future<void> _openPicker(BuildContext context, WidgetRef ref) async {
    final result = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DriverPickerSheet(
        tripId: tripId,
        currentDriverName: currentDriverName,
      ),
    );
    if (result != null && context.mounted) {
      onAssigned?.call();
    }
  }
}

/// Disabled stand-in for "Assign Driver" on a trip whose slips aren't all
/// dispatched yet.
///
/// Rendered greyed rather than hidden on purpose: a dispatcher looking for
/// the button needs to see that it exists and learn *why* it isn't
/// available. Hiding it would just read as a missing feature. Tapping opens
/// the full reason, since the chip only has room for the short form.
class _BlockedChip extends StatelessWidget {
  final TripDispatchReadiness reason;
  const _BlockedChip({required this.reason});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: DplColors.textSecondary,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
      ),
      icon: const Icon(Icons.lock_clock_rounded, size: 16),
      label: Text(reason.shortReason, overflow: TextOverflow.ellipsis),
      onPressed: () => showDialog<void>(
        context: context,
        // Pop through the DIALOG's context, never this chip's. The chip sits
        // in a lazily-built trip card and is routinely unmounted while the
        // dialog is open: _TripCardActions starts with a null driver name and
        // fetches it asynchronously, so a card whose trip already has a driver
        // renders this chip for one frame, then swaps to the driver button
        // when the fetch lands — deactivating this element. Closing over the
        // outer context would then make "Got it" throw ("Looking up a
        // deactivated widget's ancestor is unsafe") and silently stop working.
        builder: (dialogCtx) => AlertDialog(
          icon: Icon(Icons.local_shipping_outlined,
              color: DplColors.warning, size: 32),
          title: const Text("Can't assign a driver yet"),
          content: Text(
            reason.blockReason,
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Got it'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DriverPickerSheet extends ConsumerStatefulWidget {
  final int tripId;
  final String? currentDriverName;
  const _DriverPickerSheet({
    required this.tripId,
    required this.currentDriverName,
  });

  @override
  ConsumerState<_DriverPickerSheet> createState() =>
      _DriverPickerSheetState();
}

class _DriverPickerSheetState extends ConsumerState<_DriverPickerSheet> {
  Future<List<DplDriverUser>>? _future;
  int? _busyDriverId;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<DplDriverUser>> _load() async {
    final api = ref.read(dplApiServiceProvider);
    final res = await api.listDrivers();
    if (res.isError) throw Exception(res.error ?? 'Failed to load drivers');
    return res.data ?? const <DplDriverUser>[];
  }

  Future<void> _assign(DplDriverUser d) async {
    setState(() => _busyDriverId = d.id);
    final api = ref.read(dplApiServiceProvider);
    final res = await api.assignTripDriver(
      widget.tripId,
      driverUserId: d.id,
    );
    if (!mounted) return;
    setState(() => _busyDriverId = null);
    if (res.isError) {
      final err = res.error ?? 'Failed to assign driver';
      // TRIP_NOT_DISPATCHED and DRIVER_BUSY are refusals the dispatcher has
      // to read and act on, not transient failures — and both carry a long,
      // specific explanation from the server. A 4-second snackbar is the
      // wrong surface for that, so they get a dialog that waits for
      // acknowledgement. The FE normally blocks the first case before the
      // picker opens; this covers the race where slips changed underneath,
      // and any other entry point.
      if (res.code == 'TRIP_NOT_DISPATCHED' || res.code == 'DRIVER_BUSY') {
        await showDialog<void>(
          context: context,
          // Same rule as _BlockedChip: pop through the dialog's own context.
          // Safe here today (the picker sheet outlives the dialog), but
          // closing over an outer context is the kind of thing that breaks
          // silently the moment this widget is reused elsewhere.
          builder: (dialogCtx) => AlertDialog(
            icon: Icon(
              res.code == 'DRIVER_BUSY'
                  ? Icons.person_off_outlined
                  : Icons.local_shipping_outlined,
              color: DplColors.warning,
              size: 32,
            ),
            title: Text(
              res.code == 'DRIVER_BUSY'
                  ? 'Driver is already on a trip'
                  : "Can't assign a driver yet",
            ),
            content: Text(
              err,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: const Text('Got it'),
              ),
            ],
          ),
        );
        return;
      }
      DplSnacks.error(context, err);
      return;
    }
    DplSnacks.success(context, 'Driver assigned: ${d.name}');
    Navigator.of(context).pop(d.id);
  }

  @override
  Widget build(BuildContext context) {
    final hasDriver = (widget.currentDriverName ?? '').trim().isNotEmpty;
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
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
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hasDriver ? 'Change driver' : 'Assign driver',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            'Trip #${widget.tripId}'
                            '${hasDriver ? " · currently: ${widget.currentDriverName}" : ""}',
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
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(child: _list()),
          ],
        ),
      ),
    );
  }

  Widget _list() {
    return FutureBuilder<List<DplDriverUser>>(
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
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => setState(() => _future = _load()),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        final drivers = snap.data ?? const <DplDriverUser>[];
        if (drivers.isEmpty) {
          return Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.person_off_outlined,
                      size: 40, color: DplColors.textSecondary),
                  SizedBox(height: 8),
                  Text(
                    'No drivers in this org.',
                    style: TextStyle(color: DplColors.textSecondary),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Ask an admin to seed a dpl_driver user first.',
                    style: TextStyle(
                      fontSize: 12,
                      color: DplColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: drivers.length,
          separatorBuilder: (_, _) =>
              Divider(height: 1, color: DplColors.divider),
          itemBuilder: (_, i) => _driverTile(drivers[i]),
        );
      },
    );
  }

  Widget _driverTile(DplDriverUser d) {
    final busy = _busyDriverId != null;
    final thisBusy = _busyDriverId == d.id;
    // Busy on ANOTHER trip → unavailable. A driver committed to THIS trip
    // (activeTripId == this trip) stays selectable — re-picking is a no-op.
    final busyElsewhere =
        d.activeTripId != null && d.activeTripId != widget.tripId;
    return ListTile(
      enabled: !busyElsewhere,
      leading: CircleAvatar(
        backgroundColor:
            busyElsewhere ? DplColors.divider : DplColors.primaryTint,
        child: Icon(
          busyElsewhere ? Icons.lock_rounded : Icons.local_shipping_rounded,
          color: busyElsewhere ? DplColors.textSecondary : DplColors.primary,
          size: 20,
        ),
      ),
      title: Text(
        d.name.isNotEmpty ? d.name : 'Driver #${d.id}',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: busyElsewhere
          ? Text(
              'On trip #${d.activeTripNumber ?? d.activeTripId} — unavailable',
              style: TextStyle(
                fontSize: 12,
                color: DplColors.error,
                fontWeight: FontWeight.w600,
              ),
            )
          : Text(
              [
                if ((d.employeeCode ?? '').isNotEmpty) d.employeeCode,
                if ((d.email ?? '').isNotEmpty) d.email,
              ].whereType<String>().join(' · '),
              style: const TextStyle(fontSize: 12),
            ),
      trailing: thisBusy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : (busyElsewhere
              ? Icon(Icons.block_rounded,
                  color: DplColors.textSecondary, size: 18)
              : Icon(Icons.chevron_right_rounded,
                  color: DplColors.textSecondary)),
      onTap: (busy || busyElsewhere) ? null : () => _assign(d),
    );
  }
}

/// Current driver + lock state for a trip, for callers that don't already
/// hold the trip object in scope (the dispatch trip-group card — the slip
/// group doesn't carry these trip-scope fields).
class TripDriverInfo {
  final String? driverName;
  final bool hasLeftPlant;
  const TripDriverInfo({this.driverName, this.hasLeftPlant = false});
}

/// Fetch a trip's current driver name + whether it has left the plant via
/// the trip endpoint. Returns empty info on error so the card degrades to
/// the plain "Assign Driver" action.
Future<TripDriverInfo> fetchTripDriverInfo(WidgetRef ref, int tripId) async {
  final api = ref.read(dplApiServiceProvider);
  final res = await api.getTrip(tripId);
  if (res.isError || res.data == null) return const TripDriverInfo();
  final t = res.data!;
  final name = (t.driverName ?? '').trim();
  return TripDriverInfo(
    driverName: name.isEmpty ? null : name,
    hasLeftPlant: t.hasLeftPlant,
  );
}
