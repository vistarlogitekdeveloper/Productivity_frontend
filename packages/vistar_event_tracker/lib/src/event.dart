import 'dart:convert';

/// Coarse event category. Wire values mirror the backend catalog
/// (`analytics.events.event_type`): action | screen_view | error | system.
enum EventType {
  action('action'),
  screenView('screen_view'),
  error('error'),
  system('system');

  const EventType(this.wire);
  final String wire;

  static EventType fromWire(String w) =>
      EventType.values.firstWhere((e) => e.wire == w, orElse: () => EventType.action);
}

/// One tracked event. The JSON shape matches the backend ingest contract
/// EXACTLY (a `.strict()` zod schema rejects unknown keys, and `app_id` is
/// supplied by the write-key header, never in the body):
///
///   event_id, event_name, event_type, anonymous_id?, user_id?, session_id?,
///   ts_client?, properties, context
class Event {
  Event({
    required this.eventId,
    required this.eventName,
    required this.eventType,
    this.anonymousId,
    this.userId,
    this.sessionId,
    this.tsClient,
    Map<String, dynamic>? properties,
    Map<String, dynamic>? context,
  })  : properties = properties ?? const {},
        context = context ?? const {};

  final String eventId;
  final String eventName;
  final EventType eventType;
  final String? anonymousId;
  final String? userId;
  final String? sessionId;
  final String? tsClient; // ISO-8601 with offset (UTC 'Z')
  final Map<String, dynamic> properties;
  final Map<String, dynamic> context;

  /// Wire JSON. Null optionals are omitted — the backend schema treats them as
  /// nullish, and omitting keeps the payload lean.
  Map<String, dynamic> toJson() => {
        'event_id': eventId,
        'event_name': eventName,
        'event_type': eventType.wire,
        if (anonymousId != null) 'anonymous_id': anonymousId,
        if (userId != null) 'user_id': userId,
        if (sessionId != null) 'session_id': sessionId,
        if (tsClient != null) 'ts_client': tsClient,
        'properties': properties,
        'context': context,
      };

  String encode() => jsonEncode(toJson());

  static Map<String, dynamic> decode(String s) => jsonDecode(s) as Map<String, dynamic>;
}
