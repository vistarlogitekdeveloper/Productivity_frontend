import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../auth/auth_provider.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../models/dpl_dispatch_trip.dart';
import '../providers/journey_session_state.dart';
import 'security_scanner_screen.dart';

/// Security's landing dashboard.
///
/// Structure:
///   * Greeting header (user name + Security role badge)
///   * Two metric cards — session-scoped counter + last release time
///   * A big "Scan Trip QR" button that pushes the full-screen scanner
///   * Recent activity list (today's session gate-outs)
///
/// The scanner is a full-screen pushed route, not a modal — Material
/// pattern for a workflow that owns the camera. Coming back returns
/// to this dashboard with the counter + list updated (state lives in
/// [securityRecentProvider], so it survives the navigation).
///
/// Trip-level metrics (this-week total, pending trips at plant) need
/// a role-scoped BE endpoint; not exposed yet. The dashboard shows a
/// muted "More metrics coming soon" chip below the two live cards.
class SecurityHomeScreen extends ConsumerStatefulWidget {
  const SecurityHomeScreen({super.key});

  @override
  ConsumerState<SecurityHomeScreen> createState() => _SecurityHomeScreenState();
}

class _SecurityHomeScreenState extends ConsumerState<SecurityHomeScreen> {
  Future<List<DplTrip>>? _pendingFuture;

  @override
  void initState() {
    super.initState();
    _pendingFuture = _loadPending();
  }

  Future<List<DplTrip>> _loadPending() async {
    final res = await ref.read(dplApiServiceProvider).getSecurityPendingGateOut();
    if (res.isError) throw Exception(res.error ?? 'Failed to load pending trips');
    return res.data ?? const <DplTrip>[];
  }

  Future<void> _refresh() async {
    final fresh = _loadPending();
    setState(() => _pendingFuture = fresh);
    await fresh;
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final recent = ref.watch(securityRecentProvider);
    final auth = ref.watch(authControllerProvider).asData?.value;
    final userName = auth?.name ?? auth?.username ?? 'Security';

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: const DplAppBar(title: 'Security'),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _greetingCard(userName),
            const SizedBox(height: 14),
            _metricsRow(recent),
            const SizedBox(height: 14),
            _pendingSection(),
            const SizedBox(height: 14),
            _scanButton(context),
            const SizedBox(height: 22),
            _recentSection(recent),
          ],
        ),
      ),
    );
  }

  Widget _pendingSection() {
    return FutureBuilder<List<DplTrip>>(
      future: _pendingFuture,
      builder: (context, snap) {
        final trips = snap.data ?? const <DplTrip>[];
        final loading = snap.connectionState == ConnectionState.waiting;
        return Container(
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
                  Icon(Icons.local_shipping_rounded,
                      size: 18, color: DplColors.warning),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Trips waiting at gate',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (!loading)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: DplColors.warningBg,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${trips.length}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: DplColors.warning,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (snap.hasError)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    snap.error.toString().replaceFirst('Exception: ', ''),
                    style: TextStyle(
                      color: DplColors.error,
                      fontSize: 12,
                    ),
                  ),
                )
              else if (trips.isEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No trips waiting. Scan a truck when it arrives.',
                    style: TextStyle(
                      color: DplColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                )
              else
                Column(
                  children: [
                    for (final t in trips.take(6)) _pendingTile(t),
                    if (trips.length > 6)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '+ ${trips.length - 6} more…',
                          style: TextStyle(
                            fontSize: 12,
                            color: DplColors.textSecondary,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _pendingTile(DplTrip t) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: DplColors.primaryTint,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '#${t.tripNumber}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: DplColors.primary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    if ((t.vehicleNo ?? '').isNotEmpty) t.vehicleNo!,
                    if (t.plantName.isNotEmpty) t.plantName,
                  ].join(' · '),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if ((t.driverName ?? '').isNotEmpty)
                  Text(
                    'Driver: ${t.driverName}',
                    style: TextStyle(
                      fontSize: 12,
                      color: DplColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _greetingCard(String userName) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DplColors.divider),
        boxShadow: DplShadows.card,
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: DplColors.primaryTint,
            child: Icon(Icons.security_rounded,
                color: DplColors.primary, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  userName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: DplColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'SECURITY · GATE OUT',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: DplColors.primary,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricsRow(List<JourneyActivity> recent) {
    final count = recent.length;
    final last = recent.isNotEmpty ? recent.first.at : null;
    return Row(
      children: [
        Expanded(child: _metricCard(
          icon: Icons.check_circle_rounded,
          value: '$count',
          label: 'This session',
          color: DplColors.success,
        )),
        const SizedBox(width: 10),
        Expanded(child: _metricCard(
          icon: Icons.schedule_rounded,
          value: last != null ? _timeAgo(last) : '—',
          label: 'Last release',
          color: DplColors.primary,
        )),
      ],
    );
  }

  Widget _metricCard({
    required IconData icon,
    required String value,
    required String label,
    required Color color,
  }) {
    return Container(
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
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: DplColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: DplColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _scanButton(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 64,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: DplColors.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        icon: const Icon(Icons.qr_code_scanner_rounded, size: 28),
        label: const Text(
          'Scan Trip QR',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SecurityScannerScreen()),
          );
          // Guard came back from the scanner — any scan they just made
          // means one trip left the pending list on the BE side.
          // Refetch so the "Trips waiting at gate" count is truthful.
          if (mounted) unawaited(_refresh());
        },
      ),
    );
  }

  Widget _recentSection(List<JourneyActivity> recent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            'Recent releases (this session)',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: DplColors.textSecondary,
              letterSpacing: 0.3,
            ),
          ),
        ),
        if (recent.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: DplColors.cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: DplColors.divider),
              boxShadow: DplShadows.card,
            ),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.local_shipping_outlined,
                      size: 40, color: DplColors.textSecondary),
                  SizedBox(height: 8),
                  Text(
                    'No trips released yet in this session.',
                    style: TextStyle(color: DplColors.textSecondary),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Tap "Scan Trip QR" to release the first one.',
                    style: TextStyle(
                      fontSize: 12,
                      color: DplColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: DplColors.cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: DplColors.divider),
              boxShadow: DplShadows.card,
            ),
            child: Column(
              children: [
                for (var i = 0; i < recent.length; i++) ...[
                  _recentTile(recent[i]),
                  if (i != recent.length - 1)
                    Divider(height: 1, color: DplColors.divider),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _recentTile(JourneyActivity a) {
    final t = a.at;
    final ist = t.toUtc().add(const Duration(hours: 5, minutes: 30));
    final time = DateFormat('HH:mm').format(ist);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: DplColors.successBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.check_rounded,
                size: 16, color: DplColors.success),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a.tripNumber != null ? 'Trip #${a.tripNumber}' : 'Trip #${a.tripId}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if ((a.plant ?? '').isNotEmpty || (a.vehicleNo ?? '').isNotEmpty)
                  Text(
                    [
                      if ((a.plant ?? '').isNotEmpty) a.plant,
                      if ((a.vehicleNo ?? '').isNotEmpty) a.vehicleNo,
                    ].whereType<String>().join(' · '),
                    style: TextStyle(
                      fontSize: 12,
                      color: DplColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            time,
            style: TextStyle(
              fontSize: 12,
              color: DplColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _timeAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min';
    if (diff.inHours < 24) return '${diff.inHours} h';
    return '${diff.inDays} d';
  }
}
