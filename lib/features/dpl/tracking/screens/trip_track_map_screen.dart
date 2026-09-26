import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/design/dpl_format.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../models/dpl_trip_location.dart';

/// Live breadcrumb map for one dispatch trip.
///
/// Tiles come from OpenStreetMap rather than Google Maps: no API key, no
/// billing account, no per-load cost. The trade-off is that we're using
/// someone else's donated infrastructure, so we play by the OSM tile
/// usage policy — a real identifying User-Agent ([_userAgent]), no bulk
/// prefetching, and visible attribution.
///
/// The screen polls [_pollEvery] and asks only for fixes newer than the
/// last one it holds, so a six-hour trip doesn't re-download its whole
/// trail every 20 seconds.
class TripTrackMapScreen extends ConsumerStatefulWidget {
  final int tripId;
  final int? tripNumber;
  final String? plantName;
  final String? vehicleNo;

  const TripTrackMapScreen({
    super.key,
    required this.tripId,
    this.tripNumber,
    this.plantName,
    this.vehicleNo,
  });

  @override
  ConsumerState<TripTrackMapScreen> createState() => _TripTrackMapScreenState();
}

class _TripTrackMapScreenState extends ConsumerState<TripTrackMapScreen> {
  static const Duration _pollEvery = Duration(seconds: 20);

  /// OSM's tile policy requires a User-Agent that identifies the actual
  /// app. `flutter_map` builds one from this package id.
  static const String _userAgent = 'com.vistar.pulse';

  static const String _tileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// Stale-trail grey. Pinned rather than themed: the OSM tiles stay light
  /// in dark mode, where the text greys turn pale and vanish on the map.
  static const Color _mapIdle = Color(0xFF625D78);

  final MapController _map = MapController();

  DplTripTrack? _track;
  bool _loading = true;
  String? _error;
  Timer? _poll;

  /// The tracking endpoints aren't on this server yet (404 on the route
  /// itself, not "no rows"). Distinct from [_error] because it isn't a
  /// failure the viewer can retry their way out of — it needs a backend
  /// deploy — so we say so plainly instead of showing a router message,
  /// and we stop polling a route that cannot start existing mid-session.
  bool _routeMissing = false;

  /// When true the camera snaps to each new fix. Turned off the moment
  /// the user pans, so we never fight them for control of the map.
  bool _follow = true;

  /// Guards the initial auto-fit — we frame the trail once on first
  /// load, then leave the camera alone.
  bool _didInitialFit = false;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(_pollEvery, (_) => _load(incremental: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _map.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------------

  Future<void> _load({bool incremental = false}) async {
    final existing = _track;
    // Only ask for the tail when we already have a trail to append to.
    final since =
        (incremental && existing != null && existing.isNotEmpty)
            ? existing.last!.recordedAt
            : null;

    if (!incremental) setState(() => _loading = true);

    final res = await ref
        .read(dplApiServiceProvider)
        .getTripTrack(widget.tripId, since: since);

    if (!mounted) return;

    if (res.isError) {
      // 404 here is the route itself missing, not an empty trail — a
      // deployed endpoint returns 200 with no points. Retrying can't fix
      // it, so stop the poll and explain rather than flashing a router
      // error at the user every 20 seconds.
      final routeMissing = res.statusCode == 404;
      if (routeMissing) {
        _poll?.cancel();
        _poll = null;
      }
      setState(() {
        _loading = false;
        _routeMissing = routeMissing;
        // A failed incremental poll keeps the trail we already have on
        // screen — a dropped refresh shouldn't blank the map.
        if (routeMissing) {
          _error = null;
        } else if (!incremental) {
          _error = res.error ?? 'Failed to load trip track.';
        }
      });
      return;
    }

    // Recovered (e.g. the endpoint shipped while the screen was open and
    // the user hit refresh) — resume polling.
    if (_routeMissing) {
      _routeMissing = false;
      _poll ??= Timer.periodic(_pollEvery, (_) => _load(incremental: true));
    }

    final fresh = res.data ?? DplTripTrack(tripId: widget.tripId);
    setState(() {
      _loading = false;
      _error = null;
      _track = (since == null) ? fresh : _merge(existing!, fresh);
    });

    _autoFrame();
  }

  /// Appends [fresh] onto [base], tolerating a backend that ignores
  /// `since` and replays points we already hold.
  DplTripTrack _merge(DplTripTrack base, DplTripTrack fresh) {
    if (fresh.isEmpty) return base;

    final seen = {for (final p in base.points) _fingerprint(p)};
    final merged = [...base.points];
    for (final p in fresh.points) {
      if (seen.add(_fingerprint(p))) merged.add(p);
    }
    merged.sort((a, b) => a.recordedAt.compareTo(b.recordedAt));

    return DplTripTrack(
      tripId: base.tripId,
      points: merged,
      // Prefer whatever the newer response knew; fall back to the base.
      driverName: fresh.driverName ?? base.driverName,
      vehicleNo: fresh.vehicleNo ?? base.vehicleNo,
      sharing: fresh.sharing ?? base.sharing,
      distanceKm: DplTripTrack.distanceKmOf(merged),
    );
  }

  String _fingerprint(DplTripLocation p) =>
      '${p.recordedAt.toUtc().toIso8601String()}'
      '@${p.lat.toStringAsFixed(6)},${p.lng.toStringAsFixed(6)}';

  // ---------------------------------------------------------------------------
  // Camera
  // ---------------------------------------------------------------------------

  void _autoFrame() {
    final track = _track;
    if (track == null || track.isEmpty) return;

    if (!_didInitialFit) {
      _didInitialFit = true;
      // One point can't make bounds — just centre on it.
      if (track.points.length == 1) {
        _map.move(_latLng(track.points.first), 15);
      } else {
        _fitTrail();
      }
      return;
    }

    if (_follow && track.last != null) {
      _map.move(_latLng(track.last!), _map.camera.zoom);
    }
  }

  void _fitTrail() {
    final track = _track;
    if (track == null || track.isEmpty) return;
    if (track.points.length == 1) {
      _map.move(_latLng(track.points.first), 15);
      return;
    }
    _map.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(
          [for (final p in track.points) _latLng(p)],
        ),
        padding: const EdgeInsets.fromLTRB(48, 140, 48, 190),
        maxZoom: 16,
      ),
    );
  }

  LatLng _latLng(DplTripLocation p) => LatLng(p.lat, p.lng);

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final track = _track;
    final title = widget.tripNumber != null
        ? 'Track · Trip #${widget.tripNumber}'
        : 'Track trip';

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: title,
        actions: [
          IconButton(
            tooltip: _follow ? 'Following truck' : 'Follow truck',
            icon: Icon(
              _follow ? Icons.my_location_rounded : Icons.location_searching_rounded,
            ),
            onPressed: (track == null || track.isEmpty)
                ? null
                : () {
                    setState(() => _follow = !_follow);
                    if (_follow && track.last != null) {
                      _map.move(_latLng(track.last!), math.max(_map.camera.zoom, 15));
                    }
                  },
          ),
          IconButton(
            tooltip: 'Fit whole route',
            icon: const Icon(Icons.zoom_out_map_rounded),
            onPressed: (track == null || track.isEmpty)
                ? null
                : () {
                    setState(() => _follow = false);
                    _fitTrail();
                  },
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _load(),
          ),
        ],
      ),
      body: _loading && track == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null && track == null
              ? _errorView(_error!)
              : _mapStack(track),
    );
  }

  Widget _errorView(String msg) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: DplColors.error, size: 40),
              const SizedBox(height: 12),
              Text(msg, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              TextButton(onPressed: () => _load(), child: const Text('Retry')),
            ],
          ),
        ),
      );

  Widget _mapStack(DplTripTrack? track) {
    final hasTrail = track != null && track.isNotEmpty;

    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            // Falls back to the geographic centre of India until the
            // first fix lands — better than (0,0) in the Atlantic.
            initialCenter: hasTrail
                ? _latLng(track.last!)
                : const LatLng(22.9734, 78.6569),
            initialZoom: hasTrail ? 14 : 4.5,
            minZoom: 3,
            maxZoom: 18,
            interactionOptions: const InteractionOptions(
              // Rotation off: a north-up map is what dispatch expects,
              // and an accidental two-finger twist is disorienting.
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onPositionChanged: (camera, hasGesture) {
              // The user grabbed the map — stop yanking it back.
              if (hasGesture && _follow) {
                setState(() => _follow = false);
              }
            },
          ),
          children: [
            TileLayer(
              urlTemplate: _tileUrl,
              userAgentPackageName: _userAgent,
              maxNativeZoom: 19,
            ),
            if (hasTrail) ..._trailLayers(track),
            const RichAttributionWidget(
              attributions: [
                TextSourceAttribution('OpenStreetMap contributors'),
              ],
            ),
          ],
        ),
        Positioned(
          top: 10,
          left: 12,
          right: 12,
          child: _statusBanner(track),
        ),
        if (hasTrail)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: _statsBar(track),
          )
        else
          Positioned(
            left: 24,
            right: 24,
            bottom: 40,
            child: _routeMissing ? _notEnabledHint() : _emptyHint(),
          ),
      ],
    );
  }

  // ── map layers

  List<Widget> _trailLayers(DplTripTrack track) {
    final pts = [for (final p in track.points) _latLng(p)];
    final last = track.last!;
    final first = track.first!;
    final live = track.isLive;

    return [
      PolylineLayer(
        polylines: [
          // Casing underneath the route line — the standard map-route
          // treatment; keeps the trail legible over dark satellite-ish
          // tiles and busy city blocks.
          Polyline(
            points: pts,
            strokeWidth: 8,
            color: Colors.white.withValues(alpha: 0.85),
          ),
          Polyline(
            points: pts,
            strokeWidth: 4.5,
            color: live ? DplColors.primary : _mapIdle,
          ),
        ],
      ),
      MarkerLayer(
        markers: [
          if (pts.length > 1)
            Marker(
              point: _latLng(first),
              width: 26,
              height: 26,
              alignment: Alignment.center,
              child: _originDot(),
            ),
          Marker(
            point: _latLng(last),
            width: 54,
            height: 54,
            alignment: Alignment.center,
            child: _truckMarker(last, live: live),
          ),
        ],
      ),
    ];
  }

  Widget _originDot() => Container(
        decoration: BoxDecoration(
          color: DplColors.success,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: DplShadows.card,
        ),
      );

  Widget _truckMarker(DplTripLocation fix, {required bool live}) {
    final color = live ? DplColors.primary : _mapIdle;
    final heading = fix.headingDeg;

    return Stack(
      alignment: Alignment.center,
      children: [
        // Accuracy halo — communicates "we know it's roughly here",
        // which matters when the fix came off cell towers.
        Container(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            shape: BoxShape.circle,
          ),
        ),
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: DplShadows.card,
          ),
          child: heading == null
              ? const Icon(Icons.local_shipping_rounded,
                  size: 16, color: Colors.white)
              : Transform.rotate(
                  angle: heading * math.pi / 180.0,
                  child: const Icon(Icons.navigation_rounded,
                      size: 17, color: Colors.white),
                ),
        ),
      ],
    );
  }

  // ── overlays

  Widget _statusBanner(DplTripTrack? track) {
    final last = track?.last;
    final live = track?.isLive ?? false;

    final Color fg;
    final Color bg;
    final IconData icon;
    final String label;

    if (last == null) {
      fg = DplColors.textSecondary;
      bg = DplColors.neutralBg;
      icon = Icons.location_off_rounded;
      label = 'Not sharing yet';
    } else if (live) {
      fg = DplColors.success;
      bg = DplColors.successBg;
      icon = Icons.podcasts_rounded;
      label = last.isMoving
          ? 'Live · moving'
          : 'Live · stopped';
    } else {
      fg = DplColors.warning;
      bg = DplColors.warningBg;
      icon = Icons.cloud_off_rounded;
      label = 'Last seen ${DplFormat.relative(last.recordedAt)}';
    }

    final subtitle = [
      if ((track?.driverName ?? '').isNotEmpty) track!.driverName!,
      if ((widget.vehicleNo ?? track?.vehicleNo ?? '').isNotEmpty)
        (widget.vehicleNo ?? track!.vehicleNo)!,
      if ((widget.plantName ?? '').isNotEmpty) widget.plantName!,
    ].join(' · ');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(DplRadius.md),
        border: Border.all(color: DplColors.divider),
        boxShadow: DplShadows.card,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(DplRadius.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: fg),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: DplColors.textSecondary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statsBar(DplTripTrack track) {
    final last = track.last!;
    final avg = track.averageKmph;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(DplRadius.lg),
        border: Border.all(color: DplColors.divider),
        boxShadow: DplShadows.card,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _stat('Distance', '${track.distanceKm.toStringAsFixed(1)} km'),
              _divider(),
              _stat(
                'Speed',
                last.speedKmph == null
                    ? '—'
                    : '${last.speedKmph!.round()} km/h',
              ),
              _divider(),
              _stat('Avg', avg == null ? '—' : '${avg.round()} km/h'),
              _divider(),
              _stat('Elapsed', DplFormat.duration(track.elapsed)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.schedule_rounded,
                  size: 13, color: DplColors.textSecondary),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  'Last fix ${DplFormat.dateTime(last.recordedAt)} IST'
                  '${last.accuracyM != null ? " · ±${last.accuracyM!.round()}m" : ""}',
                  style: TextStyle(
                    fontSize: 11,
                    color: DplColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${track.points.length} pts',
                style: TextStyle(
                  fontSize: 11,
                  color: DplColors.textTertiary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Expanded(
        child: Column(
          children: [
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: DplColors.textPrimary,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: DplColors.textSecondary,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      );

  Widget _divider() => Container(
        width: 1,
        height: 26,
        color: DplColors.divider,
      );

  /// Shown when the server has no tracking routes yet. Deliberately not
  /// phrased as an error: nothing is broken on this device and there is
  /// nothing the viewer can do, so it reads as "not switched on yet"
  /// while still naming the missing piece for whoever is on support.
  Widget _notEnabledHint() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: DplColors.cardBg,
          borderRadius: BorderRadius.circular(DplRadius.lg),
          border: Border.all(color: DplColors.divider),
          boxShadow: DplShadows.card,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded,
                size: 34, color: DplColors.textSecondary),
            const SizedBox(height: 10),
            const Text(
              'Live tracking isn\'t enabled yet',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              'This server doesn\'t have the trip-location service running '
              'yet. Everything else on the trip works as normal — the map '
              'starts filling in as soon as it goes live.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: DplColors.textSecondary,
              ),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: DplColors.primary,
                visualDensity: VisualDensity.compact,
                textStyle:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Check again'),
              onPressed: () => _load(),
            ),
          ],
        ),
      );

  Widget _emptyHint() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: DplColors.cardBg,
          borderRadius: BorderRadius.circular(DplRadius.lg),
          border: Border.all(color: DplColors.divider),
          boxShadow: DplShadows.card,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.satellite_alt_outlined,
                size: 34, color: DplColors.textSecondary),
            SizedBox(height: 10),
            Text(
              'No location shared yet',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
            ),
            SizedBox(height: 6),
            Text(
              'The trail appears once the driver turns on "Share live '
              'location" on their trip screen. Sharing starts after gate-out '
              'and stops automatically when the trip closes.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: DplColors.textSecondary,
              ),
            ),
          ],
        ),
      );
}
