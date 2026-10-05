import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/core/telemetry/telemetry.dart';

void main() {
  group('screen names carry no record ids', () {
    test('numbers, uuids and references become placeholders; queries are dropped', () {
      expect(Telemetry.routePattern('/dpl/manager'), '/dpl/manager');
      expect(Telemetry.routePattern('/dpl/manager/plans/123?tab=items'), '/dpl/manager/plans/:id');
      expect(Telemetry.routePattern('/dpl/trips/7f3c2a10-1b2c-4d5e-8f90-a1b2c3d4e5f6/journey'), '/dpl/trips/:id/journey');
      expect(Telemetry.routePattern('/dpl/slips/VST-DS-000123'), '/dpl/slips/:ref');
      expect(Telemetry.routePattern('/dpl/manager/reports/plan-vs-actual'), '/dpl/manager/reports/plan-vs-actual');
    });
  });

  group('business actions from API writes', () {
    test('the shop-floor journey is named', () {
      expect(Telemetry.actionFor('POST', '/manager/plans'), 'plan_created');
      expect(Telemetry.actionFor('POST', '/manager/plans/upload-excel'), 'plan_uploaded');
      expect(Telemetry.actionFor('POST', '/supervisor/plans/12/items/3/start'), 'item_started');
      expect(Telemetry.actionFor('POST', '/qa/stickers'), 'label_printed');
      expect(Telemetry.actionFor('POST', '/qa/stickers/direct'), 'label_printed');
      expect(Telemetry.actionFor('POST', '/qa/pallets/44/close'), 'pallet_closed');
      expect(Telemetry.actionFor('POST', '/dispatch/trips'), 'trip_created');
      expect(Telemetry.actionFor('POST', '/dispatch/slips'), 'dispatch_slip_created');
      expect(Telemetry.actionFor('post', '/dispatch/slips/9/pdi-approve'), 'slip_pdi_approved');
    });

    test('reads, other methods and unknown paths are not reported', () {
      expect(Telemetry.actionFor('GET', '/manager/plans'), isNull);
      expect(Telemetry.actionFor('PUT', '/manager/plans/5'), isNull);
      expect(Telemetry.actionFor('POST', '/auth/login'), isNull);
      expect(Telemetry.actionFor('POST', '/qa/stickers/void'), isNull);
    });
  });

  test('off without ET_APP_ID and ET_WRITE_KEY (the default build)', () {
    expect(Telemetry.enabled, isFalse);
    // Safe to call when off: nothing is initialised, nothing throws.
    Telemetry.screen('/dpl/manager');
    Telemetry.track('plan_created');
  });
}
