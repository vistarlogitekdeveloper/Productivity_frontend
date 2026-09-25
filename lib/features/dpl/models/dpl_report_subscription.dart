import '_json_helpers.dart';

/// A report mailed on a schedule (backend migration 163).
class DplReportSubscription {
  final String reportKey;
  final String label;
  final bool configured;
  final List<String> recipients;
  final List<String> cc;
  final String sendAt; // HH:MM plant time
  final List<int> weekdays; // 1 = Monday … 7 = Sunday
  final bool isActive;
  final String? lastSentOn;
  final String? lastStatus;
  final String? lastError;

  const DplReportSubscription({
    required this.reportKey,
    required this.label,
    this.configured = true,
    this.recipients = const [],
    this.cc = const [],
    this.sendAt = '20:00',
    this.weekdays = const [1, 2, 3, 4, 5, 6, 7],
    this.isActive = false,
    this.lastSentOn,
    this.lastStatus,
    this.lastError,
  });

  factory DplReportSubscription.fromJson(Map<String, dynamic> j) {
    List<String> strings(dynamic v) => v is List ? v.map((e) => e.toString()).toList() : const [];
    return DplReportSubscription(
      reportKey: parseStringOr(j['report_key']),
      label: parseStringOr(j['label']),
      configured: j['configured'] != false,
      recipients: strings(j['recipients']),
      cc: strings(j['cc']),
      sendAt: parseStringOr(j['send_at'], '20:00'),
      weekdays: j['weekdays'] is List ? (j['weekdays'] as List).map((e) => parseIntOr(e)).toList() : const [1, 2, 3, 4, 5, 6, 7],
      isActive: j['is_active'] == true,
      lastSentOn: j['last_sent_on']?.toString(),
      lastStatus: j['last_status'] as String?,
      lastError: j['last_error'] as String?,
    );
  }
}
