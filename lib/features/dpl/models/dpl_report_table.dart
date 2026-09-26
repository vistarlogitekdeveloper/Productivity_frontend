import '_json_helpers.dart';

/// One column of a tabular stock / dispatch report.
class DplReportColumn {
  final String key;
  final String label;
  final bool numeric;
  const DplReportColumn(this.key, this.label, {this.numeric = false});
}

/// A tabular report from `/reports/<key>` (backend migrations 159–163),
/// kept generic: every report is rows of fields plus totals, and the full
/// sheet is always one tap away as Excel. The column list is chosen per
/// report on the screen, so a new server field never breaks parsing.
class DplReportTable {
  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic> totals;
  final String? from;
  final String? to;

  /// Everything else the report returned (e.g. stock-by-location's
  /// `not_put_away`, the dispatch register's `by_part` / `by_day`).
  final Map<String, dynamic> extra;

  const DplReportTable({required this.rows, required this.totals, this.from, this.to, this.extra = const {}});

  /// [rowsKey] names the array in the payload (`items`, `lines`, `pallets`,
  /// `locations`, `groups`).
  factory DplReportTable.fromJson(Map<String, dynamic> j, String rowsKey) => DplReportTable(
        rows: (j[rowsKey] is List)
            ? (j[rowsKey] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
            : const [],
        totals: j['totals'] is Map ? Map<String, dynamic>.from(j['totals']) : const {},
        from: j['from']?.toString(),
        to: j['to']?.toString(),
        extra: Map<String, dynamic>.from(j)..remove(rowsKey)..remove('totals')..remove('from')..remove('to'),
      );

  String cell(Map<String, dynamic> row, DplReportColumn c) {
    final v = row[c.key];
    if (v == null) return '';
    if (c.numeric) {
      final d = parseDoubleOr(v);
      // Whole numbers stay whole; a percentage like 99.5 keeps its decimal.
      return d == d.roundToDouble() ? d.toInt().toString() : d.toStringAsFixed(1);
    }
    return v.toString();
  }
}
