import '../../models/dpl_spd.dart';

/// Which wheel in [wheels] a scanned label belongs to, or null.
///
/// A wheel label comes in two shapes, and the server's wheel list is already
/// shaped to meet both:
///
///   * Ours — the QR holds `GA|plant|part|SERIAL|YYMMDD|shift|line`, and the
///     list carries SERIAL. Index 3, the same position every scanner in the
///     backend reads.
///   * The plant's old Maxion labels — the QR holds the printed line itself
///     (`19255/std1//13/06Oct26/12:54:33/A/13`), and for those wheels the list
///     carries exactly that text in place of a serial.
///
/// So a scan matches when the whole code, or its serial field, equals a
/// wheel's serial. Case-insensitive, because keyed-in serials are typed by
/// hand. Voided wheels never match: they cannot be packed.
DplWheel? matchScannedWheel(String raw, Iterable<DplWheel> wheels) {
  final code = raw.trim().toUpperCase();
  if (code.isEmpty) return null;

  final candidates = <String>{code};
  if (code.contains('|')) {
    final parts = code.split('|');
    if (parts.length > 3 && parts[3].trim().isNotEmpty) {
      candidates.add(parts[3].trim());
    }
  }

  for (final w in wheels) {
    if (w.isVoided) continue;
    if (candidates.contains(w.serialNo.trim().toUpperCase())) return w;
  }
  return null;
}
