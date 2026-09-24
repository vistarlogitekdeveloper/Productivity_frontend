import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/qa/services/batch_quantity.dart';

/// How many labels one press issues.
///
/// These numbers are what a button promises and a printer obeys. Getting them
/// wrong either prints labels for parts that do not exist, or sends the server
/// a request it refuses with a message no operator can act on.
void main() {
  group('BatchQuantity.resolve', () {
    test('without the grant the answer is always exactly one', () {
      // Every DPL plant. The screen shows no quantity field at all, so
      // whatever is in the controller is irrelevant.
      for (final typed in ['1', '50', '', 'abc', '-3']) {
        expect(
          BatchQuantity.resolve(typed: typed, remainingQty: 100, batch: false),
          1,
          reason: 'typed "$typed" must still issue one',
        );
      }
    });

    test('a mid-edit or nonsense field resolves to one, never to an error', () {
      // The button has to mean something at every keystroke, including the
      // moment the operator has selected-all and is about to retype.
      for (final typed in ['', '   ', 'abc', '-5', '0', '000']) {
        expect(
          BatchQuantity.resolve(typed: typed, remainingQty: 50, batch: true),
          1,
          reason: 'typed "$typed"',
        );
      }
    });

    test('an ordinary quantity passes through', () {
      expect(
        BatchQuantity.resolve(typed: '16', remainingQty: 50, batch: true),
        16,
      );
      expect(
        BatchQuantity.resolve(typed: ' 16 ', remainingQty: 50, batch: true),
        16,
        reason: 'surrounding whitespace must not defeat the parse',
      );
    });

    test('it clamps to what is actually left', () {
      expect(
        BatchQuantity.resolve(typed: '40', remainingQty: 12, batch: true),
        12,
      );
    });

    test('it ALSO clamps to the 500 the server accepts', () {
      // THE DEFECT THIS PINS. Clamping only to what was left was wrong
      // whenever a shift produced more than 500 pieces: the button offered to
      // print 600, and the server answered with a Joi validation message about
      // a `count` field the operator has never heard of.
      expect(
        BatchQuantity.resolve(typed: '600', remainingQty: 1080, batch: true),
        BatchQuantity.maxPerBatch,
      );
      expect(BatchQuantity.maxPerBatch, 500);
    });

    test('the tighter of the two limits wins', () {
      // 700 left but 500 per press -> 500.
      expect(
        BatchQuantity.resolve(typed: '99999', remainingQty: 700, batch: true),
        500,
      );
      // 300 left and 500 per press -> 300.
      expect(
        BatchQuantity.resolve(typed: '99999', remainingQty: 300, batch: true),
        300,
      );
    });

    test('nothing left still resolves to a printable-looking one', () {
      // The caller disables the button on canPrint; returning 0 here would
      // make it read "Issue & print 0 labels" for the frame before that.
      expect(
        BatchQuantity.resolve(typed: '10', remainingQty: 0, batch: true),
        1,
      );
    });
  });

  group('BatchQuantity.ceiling', () {
    test('is what is left, below the batch limit', () {
      expect(BatchQuantity.ceiling(12), 12);
      expect(BatchQuantity.ceiling(499), 499);
    });

    test('is the batch limit at or above it', () {
      expect(BatchQuantity.ceiling(500), 500);
      expect(BatchQuantity.ceiling(1080), 500);
    });

    test('never returns zero or negative', () {
      expect(BatchQuantity.ceiling(0), 1);
      expect(BatchQuantity.ceiling(-4), 1);
    });
  });

  group('BatchQuantity.presets', () {
    test('offers only quantities that can actually be printed', () {
      // Offering 50 when 12 remain is offering a refusal.
      expect(BatchQuantity.presets(12), [5, 10, 12]);
    });

    test('the ceiling itself is always the last option', () {
      expect(BatchQuantity.presets(30).last, 30);
      expect(BatchQuantity.presets(500).last, 500);
    });

    test('never repeats a value', () {
      // A common size equal to the ceiling would otherwise appear twice, which
      // reads as two different buttons doing different things.
      for (final ceiling in [5, 10, 16, 25, 50, 1, 7, 500]) {
        final p = BatchQuantity.presets(ceiling);
        expect(
          p.length,
          p.toSet().length,
          reason: 'ceiling $ceiling produced duplicates: $p',
        );
      }
    });

    test('is always ascending, so the row reads left to right', () {
      final p = BatchQuantity.presets(200);
      for (var i = 1; i < p.length; i++) {
        expect(p[i], greaterThan(p[i - 1]), reason: '$p');
      }
    });

    test('a ceiling of one offers exactly one option', () {
      expect(BatchQuantity.presets(1), [1]);
    });

    test('never offers more than the server accepts', () {
      for (final ceiling in [1, 12, 500]) {
        for (final preset in BatchQuantity.presets(ceiling)) {
          expect(preset, lessThanOrEqualTo(BatchQuantity.maxPerBatch));
          expect(preset, lessThanOrEqualTo(ceiling));
        }
      }
    });
  });
}
