import 'dart:math';

final Random _rnd = Random.secure();

/// Generate a RFC-4122 version-4 UUID (the dedup key the backend expects for
/// idempotent ingestion). Dependency-free so the SDK stays lean.
String uuidV4() {
  final b = List<int>.generate(16, (_) => _rnd.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 1
  final sb = StringBuffer();
  for (var i = 0; i < 16; i++) {
    sb.write(b[i].toRadixString(16).padLeft(2, '0'));
    if (i == 3 || i == 5 || i == 7 || i == 9) sb.write('-');
  }
  return sb.toString();
}
