import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:productivity_tracker/data/models/user_model.dart';
import 'package:productivity_tracker/features/auth/auth_provider.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_api_response.dart';
import 'package:productivity_tracker/features/dpl/core/dpl_api_service.dart';
import 'package:productivity_tracker/features/dpl/models/dpl_dispatch_slip.dart';
import 'package:productivity_tracker/features/dpl/summary/providers/dispatch_slips_provider.dart';
import 'package:productivity_tracker/features/dpl/summary/screens/dispatch_slips_inbox_screen.dart';

/// "Export to Excel" on the dispatch slips list: one press downloads every
/// slip the current tab and search match, from the server's xlsx endpoint.
class _Manager extends AuthController {
  @override
  FutureOr<UserModel?> build() =>
      UserModel(id: '1', username: 'mgr', name: 'Manager', role: 'dpl_manager');
}

void main() {
  testWidgets('the Excel button downloads the slips the list is filtered to',
      (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final asked = <RequestOptions>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://test.invalid'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        asked.add(o);
        h.resolve(Response(requestOptions: o, statusCode: 200, data: <int>[0x50, 0x4B]));
      }));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(_Manager.new),
        dplApiServiceProvider.overrideWithValue(DplApiService(dio)),
        dplDispatchSlipsProvider.overrideWith(
          (ref) async => DplApiResponse.ok(DplDispatchSlipPage.empty()),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: DispatchSlipsInboxScreen())),
    ));
    await tester.pump();

    // The list is on the Pending PDI tab with a search typed.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DispatchSlipsInboxScreen)),
    );
    container.read(dplDispatchSlipFiltersProvider.notifier)
      ..setStatus('pending_pdi')
      ..setQuery('NEXON');
    await tester.pump();

    expect(find.text('Excel'), findsOneWidget);
    await tester.tap(find.text('Excel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(asked, hasLength(1));
    expect(asked.single.path, '/dispatch/slips/export.xlsx');
    expect(asked.single.responseType, ResponseType.bytes);
    expect(asked.single.queryParameters, {'status': 'pending_pdi', 'q': 'NEXON'});
    // Saving the file is a platform call the test cannot make; whatever it
    // reports, the screen must not throw.
    await tester.pump(const Duration(seconds: 1));
  });
}
