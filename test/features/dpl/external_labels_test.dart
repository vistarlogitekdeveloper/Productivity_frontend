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
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{2,23}$').hasMatch(fields.first)) {
    return false;
  }
  final hasTime = RegExp(r'\d{2}:\d{2}:\d{2}').hasMatch(code);
  final hasDate = RegExp(r'\d{1,2}[A-Za-z]{3}\d{2}').hasMatch(code);
  return hasTime || hasDate;
}

void main() {
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

    test('a date alone is enough — the rule reads tokens, not positions', () {
      // The layout came off a photograph, so depending on any one field being
      // present would break the day a line prints its fields differently.
      expect(looksExternal('19255/stdD1//48/24Sep26/A/48'), isTrue);
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
