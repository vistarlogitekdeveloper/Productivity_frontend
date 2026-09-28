import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/core/design/dpl_format.dart';

void main() {
  // IST = UTC+05:30, so 01:00 IST on 28 Sep is 19:30 UTC on 27 Sep.
  final oneAmIst = DateTime.utc(2026, 9, 27, 19, 30);
  final sevenAmIst = DateTime.utc(2026, 9, 28, 1, 30);
  final justBeforeMidnightIst = DateTime.utc(2026, 9, 28, 18, 29);

  group('DplFormat.calendarDay', () {
    test('rolls over at midnight IST, not at the 07:00 cutover', () {
      expect(DplFormat.calendarDay(oneAmIst), DateTime(2026, 9, 28));
      expect(DplFormat.businessDay(oneAmIst), DateTime(2026, 9, 27));
    });

    test('agrees with businessDay from 07:00 IST until midnight', () {
      expect(DplFormat.calendarDay(sevenAmIst), DateTime(2026, 9, 28));
      expect(DplFormat.businessDay(sevenAmIst), DateTime(2026, 9, 28));
      expect(DplFormat.calendarDay(justBeforeMidnightIst), DateTime(2026, 9, 28));
    });

    test('ignores the device timezone', () {
      // Same instant as oneAmIst, expressed in device-local time.
      expect(DplFormat.calendarDay(oneAmIst.toLocal()), DateTime(2026, 9, 28));
    });

    test('returns a date-only value', () {
      final d = DplFormat.calendarDay(oneAmIst);
      expect([d.hour, d.minute, d.second, d.millisecond], [0, 0, 0, 0]);
    });
  });
}
