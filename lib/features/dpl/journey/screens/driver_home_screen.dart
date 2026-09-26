import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../models/dpl_dispatch_trip.dart';
import 'driver_trip_screen.dart';

/// Driver's home screen — lists every trip currently assigned to the
/// logged-in driver via GET /driver/my-trips. Tap a trip → open the
/// driver trip screen where they show/scan the appropriate artefacts
/// for the current stage.
class DriverHomeScreen extends ConsumerStatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  ConsumerState<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends ConsumerState<DriverHomeScreen> {
  Future<List<DplTrip>>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<DplTrip>> _load() async {
    final api = ref.read(dplApiServiceProvider);
    final res = await api.getMyDriverTrips();
    if (res.isError) {
      throw Exception(res.error ?? 'Failed to load trips');
    }
    return res.data ?? const <DplTrip>[];
  }

  Future<void> _refresh() async {
    final fresh = _load();
    setState(() => _future = fresh);
    await fresh;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: const DplAppBar(title: 'My Trips'),
      body: FutureBuilder<List<DplTrip>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _error(snap.error.toString().replaceFirst('Exception: ', ''));
          }
          final trips = snap.data ?? const <DplTrip>[];
          if (trips.isEmpty) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                children: [
                  SizedBox(height: 120),
                  Icon(Icons.local_shipping_outlined,
                      size: 64, color: DplColors.textSecondary),
                  SizedBox(height: 12),
                  Center(
                    child: Text(
                      'No trips assigned yet.',
                      style: TextStyle(color: DplColors.textSecondary),
                    ),
                  ),
                  SizedBox(height: 6),
                  Center(
                    child: Text(
                      'Pull down to refresh.',
                      style: TextStyle(
                        color: DplColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: trips.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _tripCard(trips[i]),
            ),
          );
        },
      ),
    );
  }

  Widget _error(String msg) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: DplColors.error, size: 40),
            const SizedBox(height: 12),
            Text(msg, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            TextButton(onPressed: _refresh, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _tripCard(DplTrip trip) {
    final assignedAt = trip.driverAssignedAt != null
        ? DateFormat('dd MMM · HH:mm').format(
            trip.driverAssignedAt!.toUtc().add(const Duration(hours: 5, minutes: 30)))
        : null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DriverTripScreen(tripId: trip.id),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: DplColors.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: DplColors.divider),
            boxShadow: DplShadows.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Trip #${trip.tripNumber}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: DplColors.primary.withValues(alpha: 0.10),
                      border:
                          Border.all(color: DplColors.primary.withValues(alpha: 0.30)),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      trip.status,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: DplColors.primary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                [
                  if (trip.plantName.isNotEmpty) trip.plantName,
                  if ((trip.vehicleNo ?? '').isNotEmpty) trip.vehicleNo!,
                ].join(' · '),
                style: TextStyle(color: DplColors.textSecondary),
              ),
              if (assignedAt != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Assigned $assignedAt IST',
                  style: TextStyle(
                    fontSize: 12,
                    color: DplColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
