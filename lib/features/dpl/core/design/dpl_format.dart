import 'package:intl/intl.dart';

/// Date / time / duration formatting helpers for DPL screens.
///
/// All wall-clock times are rendered in IST (Asia/Kolkata, UTC+05:30)
/// regardless of what the device clock is set to, so a supervisor in
/// the plant and a manager travelling abroad see the same string. The
/// app does not ship a tzdata bundle, so we apply a fixed +05:30
/// offset rather than using `package:timezone` — backend stamps are
/// already canonical UTC so this is sufficient.
class DplFormat {
  const DplFormat._();

  static const Duration _istOffset = Duration(hours: 5, minutes: 30);

  /// IST hour at which the plant's business day rolls over (migration
  /// 050). Backend's "today" endpoints (`/supervisor/today`,
  /// `/dispatch/trips`, `/manager/alerts`, etc.) return yesterday's
  /// calendar date when called between 00:00 and 06:59 IST, because
  /// Shift C is still running on the previous business day.
  static const int _businessDayCutoverHour = 7;

  /// Converts any [DateTime] (UTC or local) to the equivalent wall
  /// clock instant in IST, returned as a NAIVE DateTime so subsequent
  /// `DateFormat` calls treat the components literally.
  static DateTime _toIst(DateTime dt) {
    final asUtc = dt.isUtc ? dt : dt.toUtc();
    return asUtc.add(_istOffset);
  }

  /// Plant business day for [now] under the IST 07:00 cutover rule.
  /// Returned as a date-only DateTime (time component zeroed) so it
  /// can be compared with `==` against other business-day values and
  /// fed straight into date-only API params.
  ///
  /// At 06:59 IST on June 18 → returns June 17 (Shift C still active
  /// on yesterday's business day).
  /// At 07:00 IST on June 18 → returns June 18.
  static DateTime businessDay([DateTime? now]) {
    final ist = _toIst(now ?? DateTime.now());
    final dayOnly = DateTime(ist.year, ist.month, ist.day);
    if (ist.hour < _businessDayCutoverHour) {
      return dayOnly.subtract(const Duration(days: 1));
    }
    return dayOnly;
  }

  /// IST calendar day for [now] — rolls over at midnight, NOT at the
  /// 07:00 business-day cutover. Returned as a date-only DateTime, same
  /// shape as [businessDay].
  ///
  /// Dispatch trips are dated by calendar day: `POST /dispatch/trips`
  /// rejects dates before the IST calendar day and the 04:00 expiry job
  /// cancels trips dated before it. Trip screens use this, and pass it
  /// explicitly to `GET /dispatch/trips`, whose server-side default is
  /// still the business day.
  ///
  /// At 01:00 IST on June 18 → returns June 18.
  static DateTime calendarDay([DateTime? now]) {
    final ist = _toIst(now ?? DateTime.now());
    return DateTime(ist.year, ist.month, ist.day);
  }

  /// True when [now] lies in the 00:00–06:59 IST window where the
  /// business day is one calendar day behind. UI uses this to decide
  /// whether to render the "Business Day" advisory banner.
  static bool isBeforeBusinessDayCutover([DateTime? now]) {
    final ist = _toIst(now ?? DateTime.now());
    return ist.hour < _businessDayCutoverHour;
  }

  /// "19 May 2026"
  static String date(DateTime dt) =>
      DateFormat('d MMM yyyy').format(_toIst(dt));

  /// "19 May"
  static String dateShort(DateTime dt) =>
      DateFormat('d MMM').format(_toIst(dt));

  /// "Tuesday, 19 May 2026"
  static String dateLong(DateTime dt) =>
      DateFormat('EEEE, d MMM yyyy').format(_toIst(dt));

  /// "9:15 AM"
  static String time(DateTime dt) =>
      DateFormat('h:mm a').format(_toIst(dt));

  /// "19 May 2026, 9:15 AM"
  static String dateTime(DateTime dt) =>
      DateFormat('d MMM yyyy, h:mm a').format(_toIst(dt));

  /// "19 May 2026, 9:15:42 AM"
  static String dateTimeWithSeconds(DateTime dt) =>
      DateFormat('d MMM yyyy, h:mm:ss a').format(_toIst(dt));

  /// Relative time like "2 hours ago" / "just now" / "in 3 minutes".
  static String relative(DateTime dt, {DateTime? now}) {
    final ref = now ?? DateTime.now();
    final diff = ref.difference(dt);
    final abs = diff.abs();
    String suffix(int n, String unit) => '$n $unit${n == 1 ? '' : 's'}';

    String label;
    if (abs.inSeconds < 30) {
      return 'just now';
    } else if (abs.inMinutes < 60) {
      label = suffix(abs.inMinutes, 'minute');
    } else if (abs.inHours < 24) {
      label = suffix(abs.inHours, 'hour');
    } else if (abs.inDays < 30) {
      label = suffix(abs.inDays, 'day');
    } else if (abs.inDays < 365) {
      label = suffix(abs.inDays ~/ 30, 'month');
    } else {
      label = suffix(abs.inDays ~/ 365, 'year');
    }
    return diff.isNegative ? 'in $label' : '$label ago';
  }

  /// "2h 27m" for long durations, "47 min" for short.
  static String duration(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h == 0) {
      return '$m min';
    }
    return '${h}h ${m}m';
  }

  /// "01:23:45" — used for live timers on the execution screen.
  static String timer(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${h.toString().padLeft(2, '0')}:$m:$s';
  }
}

/// One row in the parsed activity log shown on Plan Detail.
class ActivityLogEntry {
  /// Raw bracketed text minus the trailing timestamp, e.g.
  /// "Shift submitted".
  final String action;

  /// Parsed timestamp; null when the raw entry didn't include one.
  final DateTime? timestamp;

  /// Pre-formatted "19 May 2026, 12:13 PM" — empty when timestamp is null.
  final String formatted;

  /// Original raw token, kept for debugging / fallback rendering.
  final String raw;

  const ActivityLogEntry({
    required this.action,
    required this.timestamp,
    required this.formatted,
    required this.raw,
  });
}

/// Parses the loose "remarks" field on a production plan into a list
/// of structured activity entries.
///
/// Backend writes events into `remarks` as a stream of bracketed tokens
/// separated by spaces or newlines, e.g.
/// `[Plan created 2026-05-18T11:00:00.000Z] [Shift submitted 2026-05-19T06:43:24.905Z]`.
/// Any free text between brackets is captured as a trailing note.
class DplActivityLog {
  const DplActivityLog._();

  static final _entryPattern = RegExp(r'\[(.*?)\]', dotAll: true);
  static final _trailingIso = RegExp(
    r'\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?)\s*$',
  );

  static List<ActivityLogEntry> parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    final out = <ActivityLogEntry>[];
    for (final match in _entryPattern.allMatches(raw)) {
      final body = (match.group(1) ?? '').trim();
      if (body.isEmpty) continue;

      final tsMatch = _trailingIso.firstMatch(body);
      DateTime? ts;
      String action = body;
      if (tsMatch != null) {
        final iso = tsMatch.group(1)!;
        ts = DateTime.tryParse(iso);
        action = body.substring(0, tsMatch.start).trim();
      }

      out.add(ActivityLogEntry(
        action: action.isEmpty ? body : action,
        timestamp: ts,
        formatted: ts != null ? DplFormat.dateTime(ts) : '',
        raw: body,
      ));
    }
    return out;
  }
}
