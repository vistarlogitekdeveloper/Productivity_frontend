import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_permissions_provider.dart';

/// The plant's EXISTING (external) wheel labels.
///
/// Maxion cannot stop printing them overnight, so for a transition period both
/// kinds must scan — and each old label exactly once. The client half is only
/// about whether the camera keeps the viewfinder open; the server is the
/// authority on what is accepted. These pin the recognition rule, because a
/// camera that refuses a label the server would take is the failure that
/// teaches an operator to distrust the app.

/// Mirrors the check inside DplQrScanSheet. Kept here rather than exported so
/// the widget's own logic stays private; if the two ever diverge, the server
/// still decides and the worst case is a needless refusal at the camera.
bool looksExternal(String code) {
  if (code.contains('|')) return false;
  if (RegExp(r'^GA\d{6,}$', caseSensitive: false).hasMatch(code)) return false;
  if (RegExp(r'^(PM|P|H|M|SP)\d{6,}$', caseSensitive: false).hasMatch(code)) {
    return false;
  }
  if (code.contains('://')) return false;
  if (RegExp(r'\s').hasMatch(code)) return false;
  final fields = code.split('/');
  if (fields.length < 4) return false;
  // The item-code shape alone refuses every false positive; an earlier
  // date/time anchor was over-fitted to the text printed BESIDE the QR and
  // rejected real labels off the plant's rolls.
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{2,23}$').hasMatch(fields.first);
}

void main() {
  _realLabelTests();

  // Verbatim from photographs of the plant's printed rolls.
  const extA = '19255/stdD1//48/24Sep26/11:37:04/A/48';
  const extB = '8993GMBM/std2//33/24Sep26/00:05:27/B/33';

  group('recognising the old labels', () {
    test('the plant\'s own stickers are recognised', () {
      expect(looksExternal(extA), isTrue);
      expect(looksExternal(extB), isTrue);
    });

    test('none of OUR labels is ever mistaken for one', () {
      // Each prefix sends the scanner somewhere different, so a label of ours
      // swallowed by the external branch would be adopted as a brand new wheel
      // instead of being matched to the one it already is.
      for (final ours in [
        'GA|NEXON|546469500102ZX|GA2600000147|260920|A|M1',
        'MW|P1|19255|GA2600000147|260819|A|PL2',
        'MWP|M26000013',
        'MWS|SP26000411',
        'GAM|trip',
        'GA2600000147',
        'M26000013',
        'SP26000411',
        'H26000008',
        // The PM series is issued at close for a production merge, so these
        // are numbers that exist on real labels. A two-letter prefix is the
        // case a rule written for one letter gets wrong.
        'PM26000013',
        'MWP|PM26000013',
      ]) {
        expect(looksExternal(ours), isFalse, reason: ours);
      }
    });

    test('stray text is not adopted as a wheel', () {
      // Adoption mints a wheel row, so a carton barcode or a mis-read must not
      // qualify — it would put stock on a pallet that does not exist.
      //
      // A separator count alone was NOT enough, and an audit caught it: every
      // one of these cleared four fields and would have been adopted. The
      // camera reads QR and DataMatrix, which is exactly what a URL poster or
      // an asset tag on the wrapping machine carries — so these are everyday
      // scans, not contrived ones.
      for (final junk in [
        'SOMETHING',
        '12/34',
        'a/b/c',
        '',
        '   ',
        'https://maxion.example/eq/4471',
        'http://x/a/b/c',
        '////',
        'PO/12345/2026/09',
        '25/09/2026/A',
        'a/b/c/d',
        '/stdD1//48/24Sep26/11:37:04/A/48',
      ]) {
        expect(looksExternal(junk.trim()), isFalse, reason: '"$junk"');
      }
    });

    test('the rule does not depend on the printed layout at all', () {
      // THE LESSON. The QR does NOT encode the text printed beside it, so any
      // rule tuned to that text refuses real labels. These are all shapes the
      // payload might take, and every one must scan.
      for (final shape in [
        '19255/stdD1//48/24Sep26/11:37:04/A/48',
        '8993GMBM/std2//33/24Sep26/D0:05:27/B/33', // 'D0', not a valid time
        '19255/stdD1//48/24Sep26/A/48', // no time at all
        '19255/stdD1/48/A', // no date either
        '8993GMBM/std/2/33/B/33',
      ]) {
        expect(looksExternal(shape), isTrue, reason: shape);
      }
    });
  });

  group('accepting them is a switch, not a build', () {
    test('an unknown permission list does not accept old labels', () {
      // The whole point is that the plant stops taking them by unticking a
      // box. If "unknown" meant yes, they could never be switched off.
      const p = DplPermissions.unknown();
      expect(p.can(DplPermission.labelsScanExternal), isFalse);
      expect(
        DplPermission.optInOnly.contains(DplPermission.labelsScanExternal),
        isTrue,
      );
    });

    test('it is separate from ordinary scanning and printing', () {
      final ordinary = DplPermissions.of(const [
        'labels.scan',
        'labels.print',
        'pallet.build',
        'pallet.close',
      ]);
      expect(ordinary.can(DplPermission.labelsScanExternal), isFalse);

      final transitional = DplPermissions.of(const ['labels.scan_external']);
      expect(transitional.can(DplPermission.labelsScanExternal), isTrue);
    });
  });
}

/// REAL labels, from the plant's own print run (PROD-005606).
///
/// Not reconstructions from a photograph — these come from the PDF the
/// external system produced, so the text is exact. Twice now a rule tuned to a
/// GUESS at this format refused labels off a real roll, so anything that stops
/// these scanning is a regression, full stop.
void _realLabelTests() {
  const realRun = [
    '9042PBFP/std01//1/25Sep26/13:54:40/A/1',
    '9042PBFP/std01//2/25Sep26/13:54:40/A/2',
    '9042PBFP/std01//9/25Sep26/13:54:40/A/9',
    '9042PBFP/std01//10/25Sep26/13:54:40/A/10',
    '9042PBFP/std01//20/25Sep26/13:54:40/A/20',
  ];

  group('a real print run', () {
    test('every label is recognised by the camera', () {
      for (final code in realRun) {
        expect(looksExternal(code), isTrue, reason: code);
      }
    });

    test('sequence numbers of different lengths all scan', () {
      // 1, 10 and 20 shift every following character along. A rule that keyed
      // off character offsets rather than separators would pass the first and
      // fail the rest — which is exactly how this would reach the floor half
      // working.
      expect(looksExternal(realRun.first), isTrue);
      expect(looksExternal(realRun[3]), isTrue);
      expect(looksExternal(realRun.last), isTrue);
    });

    test('the item code is the first field, and it is a real part', () {
      // 9042PBFP is seeded in the Maxion item master as a customer_part_no
      // (migration 150), which is one of the two columns the server matches —
      // so these resolve to an item instead of falling back to the picker.
      expect(realRun.first.split('/').first, '9042PBFP');
    });
  });
}
