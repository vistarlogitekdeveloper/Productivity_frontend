import '_json_helpers.dart';

class DplLaneStats {
  final String plantCode;
  final String name;
  final int plannedToday;
  final int dispatchedToday;
  final double? fulfilmentTodayPct;
  final int dispatchedMtd;
  final int palletsMtd;
  final int openTrips;
  final int? avgMinutesAtDock;
  final int tripsToday;
  final int slipsToday;
  final int slipsMtd;
  final int? avgMinutesInPlant;

  const DplLaneStats({
    required this.plantCode,
    required this.name,
    required this.plannedToday,
    required this.dispatchedToday,
    required this.dispatchedMtd,
    required this.palletsMtd,
    required this.openTrips,
    this.fulfilmentTodayPct,
    this.avgMinutesAtDock,
    this.tripsToday = 0,
    this.slipsToday = 0,
    this.slipsMtd = 0,
    this.avgMinutesInPlant,
  });

  factory DplLaneStats.fromJson(Map<String, dynamic> j) => DplLaneStats(
        plantCode: parseStringOr(j['plant_code']),
        name: parseStringOr(j['name']),
        plannedToday: parseIntOr(j['planned_today']),
        dispatchedToday: parseIntOr(j['dispatched_today']),
        fulfilmentTodayPct: j['fulfilment_today_pct'] == null ? null : parseDoubleOr(j['fulfilment_today_pct']),
        dispatchedMtd: parseIntOr(j['dispatched_mtd']),
        palletsMtd: parseIntOr(j['pallets_mtd']),
        openTrips: parseIntOr(j['open_trips']),
        avgMinutesAtDock: parseIntOrNull(j['avg_minutes_at_dock']),
        tripsToday: parseIntOr(j['trips_today']),
        slipsToday: parseIntOr(j['slips_today']),
        slipsMtd: parseIntOr(j['slips_mtd']),
        avgMinutesInPlant: parseIntOrNull(j['avg_minutes_in_plant']),
      );
}

/// The manager's home screen in one call (backend phase 4).
class DplOemDashboard {
  final String date;
  final List<DplLaneStats> lanes;
  final int onHandQty;
  final int unlabelledQty;
  final int loadedQty;
  final int halfPallets;
  final Map<String, int> totals;
  final Map<String, int> attention;
  final List<({String consignee, int qty})> returnsMtd;

  const DplOemDashboard({
    required this.date,
    required this.lanes,
    required this.onHandQty,
    required this.unlabelledQty,
    required this.loadedQty,
    required this.attention,
    this.halfPallets = 0,
    this.totals = const {},
    this.returnsMtd = const [],
  });

  factory DplOemDashboard.fromJson(Map<String, dynamic> j) {
    final stock = j['stock'] is Map ? Map<String, dynamic>.from(j['stock']) : <String, dynamic>{};
    final att = j['attention'] is Map ? Map<String, dynamic>.from(j['attention']) : <String, dynamic>{};
    return DplOemDashboard(
      date: parseStringOr(j['date']),
      lanes: (j['lanes'] is List)
          ? (j['lanes'] as List).whereType<Map>().map((e) => DplLaneStats.fromJson(Map<String, dynamic>.from(e))).toList()
          : const [],
      onHandQty: parseIntOr(stock['on_hand_qty']),
      unlabelledQty: parseIntOr(stock['unlabelled_qty']),
      loadedQty: parseIntOr(stock['loaded_qty']),
      halfPallets: parseIntOr(stock['half_pallets']),
      totals: j['totals'] is Map ? (j['totals'] as Map).map((k, v) => MapEntry(k.toString(), parseIntOr(v))) : const {},
      attention: att.map((k, v) => MapEntry(k, parseIntOr(v))),
      returnsMtd: (j['returns_mtd'] is List)
          ? (j['returns_mtd'] as List).whereType<Map>().map((r) => (consignee: parseStringOr(r['consignee']), qty: parseIntOr(r['qty']))).toList()
          : const [],
    );
  }
}
