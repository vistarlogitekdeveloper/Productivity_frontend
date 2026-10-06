import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_part.dart';

/// The pallet size the QA Print labels screen shows next to the item.
void main() {
  DplPart parse(Object? qty) => DplPart.fromJson({
        'id': 7,
        'customer_part_no': '19255',
        'description': 'Al Finish Wheel 9255',
        'packaging_qty': qty,
      });

  test('reads packaging_qty as the pallet size', () {
    expect(parse(16).packagingQty, 16);
    expect(parse('16').packagingQty, 16);
  });

  test('missing or non-positive means "not set", never 0 per pallet', () {
    expect(parse(null).packagingQty, isNull);
    expect(parse(0).packagingQty, isNull);
    expect(parse(-4).packagingQty, isNull);
  });

  test('is never sent back on a parts-master save', () {
    // It has its own editor; a parts save must not be able to overwrite it.
    expect(parse(16).toJsonForWrite().containsKey('packaging_qty'), isFalse);
  });

  test('survives copyWith', () {
    expect(parse(16).copyWith(description: 'x').packagingQty, 16);
  });
}
