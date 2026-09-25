part of 'dpl_api_service.dart';

/// Endpoints for Maxion phases 1–4 and offline handhelds (backend migrations
/// 159–164; backend `src/modules/dpl/API.md` §7–12).
///
/// A `part` of dpl_api_service.dart so it shares `_send`, `_dio` and the
/// helpers, and keeps one error contract: nothing throws, every call returns
/// a [DplApiResponse], and a floor refusal carries `errorLocal` when the app
/// asked for Marathi or Hindi.
extension DplMaxionApi on DplApiService {
  Map<String, dynamic> _asMap(dynamic d) =>
      d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
  List<Map<String, dynamic>> _asList(dynamic d) =>
      d is List ? d.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];

  Future<DplApiResponse<Uint8List>> _bytes(String path, {Map<String, dynamic>? query, required String fallback}) async {
    try {
      final res = await _dio.get<List<int>>(path,
          queryParameters: query == null ? null : _cleanQuery(query),
          options: Options(responseType: ResponseType.bytes));
      return DplApiResponse.ok(Uint8List.fromList(res.data ?? const []));
    } on DioException catch (e) {
      // A byte response's error body arrives as bytes too; decode it so the
      // envelope's message and code survive.
      final raw = e.response?.data;
      if (raw is List<int>) {
        try {
          final decoded = jsonDecode(utf8.decode(raw));
          return DplErrorMapper.fromDio<Uint8List>(
            DioException(requestOptions: e.requestOptions, response: Response(requestOptions: e.requestOptions, statusCode: e.response?.statusCode, data: decoded), type: e.type),
            fallback: fallback,
          );
        } catch (_) {}
      }
      return DplErrorMapper.fromDio<Uint8List>(e, fallback: fallback);
    } catch (e) {
      return DplErrorMapper.fromObject<Uint8List>(e, fallback: fallback);
    }
  }

  // --- Reports (§7.4, §8.6, §10.4, §11.1) ------------------------------------

  /// A tabular report; [rowsKey] names the array in its payload.
  Future<DplApiResponse<DplReportTable>> getReportTable(String key, String rowsKey, {Map<String, dynamic>? query}) =>
      _send(() => _dio.get(DplPaths.report(key), queryParameters: query == null ? null : _cleanQuery(query)),
          fallback: 'Could not load the report.', fromJson: (d) => DplReportTable.fromJson(_asMap(d), rowsKey));

  /// The same report as the Excel file the server builds.
  Future<DplApiResponse<Uint8List>> getReportXlsx(String key, {Map<String, dynamic>? query}) =>
      _bytes(DplPaths.report(key), query: {...?query, 'format': 'xlsx'}, fallback: 'Could not download the report.');

  Future<DplApiResponse<DplOemDashboard>> getOemDashboard({DateTime? date}) =>
      _send(() => _dio.get(DplPaths.oemDashboard, queryParameters: date == null ? null : {'date': _ymd(date)}),
          fallback: 'Could not load the dashboard.', fromJson: (d) => DplOemDashboard.fromJson(_asMap(d)));

  Future<DplApiResponse<List<DplReportSubscription>>> listReportSubscriptions() =>
      _send(() => _dio.get(DplPaths.reportSubscriptions),
          fallback: 'Could not load scheduled emails.', fromJson: (d) => _asList(d).map(DplReportSubscription.fromJson).toList());

  Future<DplApiResponse<DplReportSubscription>> saveReportSubscription(String key, Map<String, dynamic> body) =>
      _send(() => _dio.put(DplPaths.reportSubscription(key), data: body),
          fallback: 'Could not save.', fromJson: (d) => DplReportSubscription.fromJson(_asMap(d)));

  Future<DplApiResponse<Map<String, dynamic>>> sendReportNow(String key, {DateTime? date}) =>
      _send(() => _dio.post(DplPaths.reportSendNow(key), data: {if (date != null) 'date': _ymd(date)}),
          fallback: 'Could not send the email.', fromJson: _asMap);

  // --- Trips: pallets, shipment, gate pass (§7.2, §8.2, §8.3) ---------------

  Future<DplApiResponse<DplTripScanProgress>> unloadPalletFromTrip({required int tripId, required int palletId}) =>
      _send(() => _dio.delete(DplPaths.tripUnloadPallet(tripId, palletId)),
          fallback: 'Could not unload the pallet.',
          fromJson: (d) => DplTripScanProgress.fromJson(_asMap(_asMap(d)['progress'])));

  Future<DplApiResponse<DplTripShipment>> getTripShipment(int tripId) =>
      _send(() => _dio.get(DplPaths.tripShipment(tripId)),
          fallback: 'Could not load the shipment details.', fromJson: (d) => DplTripShipment.fromJson(_asMap(d)));

  /// Partial update: only the keys in [changes] are sent; `null` clears one.
  Future<DplApiResponse<DplTripShipment>> updateTripShipment(int tripId, Map<String, dynamic> changes) =>
      _send(() => _dio.patch(DplPaths.tripShipment(tripId), data: changes),
          fallback: 'Could not save the shipment details.', fromJson: (d) => DplTripShipment.fromJson(_asMap(d)));

  Future<DplApiResponse<DplGatePass>> getGatePass(int tripId) =>
      _send(() => _dio.get(DplPaths.tripGatePass(tripId)),
          fallback: 'Could not build the gate pass.', fromJson: (d) => DplGatePass.fromJson(_asMap(d)));

  Future<DplApiResponse<Uint8List>> getGatePassPdf(int tripId) =>
      _bytes(DplPaths.tripGatePass(tripId), query: {'format': 'pdf'}, fallback: 'Could not download the gate pass.');

  Future<DplApiResponse<DplGatePassCheck>> verifyGatePass(String token) =>
      _send(() => _dio.post(DplPaths.gatePassVerify, data: {'token': token}),
          fallback: 'Could not check that gate pass.', fromJson: (d) => DplGatePassCheck.fromJson(_asMap(d)));

  // --- Masters and lanes (§8.1, §9) ------------------------------------------

  Future<DplApiResponse<List<DplTransporter>>> listTransporters({bool includeInactive = false}) =>
      _send(() => _dio.get(DplPaths.logisticsMaster('transporters'), queryParameters: {if (includeInactive) 'include_inactive': 'true'}),
          fallback: 'Could not load transporters.', fromJson: (d) => _asList(d).map(DplTransporter.fromJson).toList());

  Future<DplApiResponse<List<DplConsignee>>> listConsignees({bool includeInactive = false}) =>
      _send(() => _dio.get(DplPaths.logisticsMaster('consignees'), queryParameters: {if (includeInactive) 'include_inactive': 'true'}),
          fallback: 'Could not load consignees.', fromJson: (d) => _asList(d).map(DplConsignee.fromJson).toList());

  Future<DplApiResponse<Map<String, dynamic>>> saveLogisticsMaster(String kind, Map<String, dynamic> body, {int? id}) =>
      _send(() => id == null ? _dio.post(DplPaths.logisticsMaster(kind), data: body) : _dio.put(DplPaths.logisticsMasterById(kind, id), data: body),
          fallback: 'Could not save.', fromJson: _asMap);

  Future<DplApiResponse<List<DplLane>>> listLanes() =>
      _send(() => _dio.get(DplPaths.lanes),
          fallback: 'Could not load lanes.', fromJson: (d) => _asList(_asMap(d)['lanes']).map(DplLane.fromJson).toList());

  Future<DplApiResponse<List<DplLane>>> saveLane(Map<String, dynamic> body, {String? code}) =>
      _send(() => code == null ? _dio.post(DplPaths.lanes, data: body) : _dio.put(DplPaths.laneByCode(code), data: body),
          fallback: 'Could not save the lane.', fromJson: (d) => _asList(_asMap(d)['lanes']).map(DplLane.fromJson).toList());

  // --- Shipment reversal (§8.4) -----------------------------------------------

  Future<DplApiResponse<List<DplSlipReversal>>> listPendingReversals() =>
      _send(() => _dio.get(DplPaths.reversalsPending),
          fallback: 'Could not load reversals.', fromJson: (d) => _asList(d).map(DplSlipReversal.fromJson).toList());

  Future<DplApiResponse<DplSlipReversal>> requestReversal(int slipId, String reason) =>
      _send(() => _dio.post(DplPaths.slipReversal(slipId), data: {'reason': reason}),
          fallback: 'Could not request the reversal.', fromJson: (d) => DplSlipReversal.fromJson(_asMap(d)));

  Future<DplApiResponse<DplSlipReversal>> decideReversal(int slipId, {required bool approve, String? note}) =>
      _send(() => _dio.post(approve ? DplPaths.slipReversalApprove(slipId) : DplPaths.slipReversalReject(slipId), data: {'note': ?note}),
          fallback: 'Could not record the decision.', fromJson: (d) => DplSlipReversal.fromJson(_asMap(d)));

  // --- Customer returns (§8.5) ------------------------------------------------

  Future<DplApiResponse<List<DplCustomerReturn>>> listReturns({String? status}) =>
      _send(() => _dio.get(DplPaths.returns, queryParameters: {'status': ?status}),
          fallback: 'Could not load returns.', fromJson: (d) => _asList(_asMap(d)['returns']).map(DplCustomerReturn.fromJson).toList());

  /// Item search for the manual-line picker, open to whoever receives returns.
  Future<DplApiResponse<List<DplPart>>> searchReturnParts({String? q}) =>
      _send(() => _dio.get(DplPaths.returnParts, queryParameters: {if ((q ?? '').trim().isNotEmpty) 'q': q!.trim()}),
          fallback: 'Could not search items.', fromJson: (d) => _asList(d).map(DplPart.fromJson).toList());

  Future<DplApiResponse<DplCustomerReturn>> getReturn(int id) =>
      _send(() => _dio.get(DplPaths.returnById(id)),
          fallback: 'Could not load the return.', fromJson: (d) => DplCustomerReturn.fromJson(_asMap(d)));

  Future<DplApiResponse<DplCustomerReturn>> createReturn({required String reason, int? consigneeId, String? referenceNo, String? remarks}) =>
      _send(() => _dio.post(DplPaths.returns, data: {'reason': reason, 'consignee_id': ?consigneeId, 'reference_no': ?referenceNo, 'remarks': ?remarks}),
          fallback: 'Could not open the return.', fromJson: (d) => DplCustomerReturn.fromJson(_asMap(d)));

  Future<DplApiResponse<Map<String, dynamic>>> scanReturnedWheel(int returnId, String code, {String? note}) =>
      _send(() => _dio.post(DplPaths.returnScan(returnId), data: {'code': code, 'note': ?note}),
          fallback: 'Could not receive that wheel.', fromJson: _asMap);

  Future<DplApiResponse<Map<String, dynamic>>> addReturnManualLine(int returnId, {required int partId, required int qty, String? note}) =>
      _send(() => _dio.post(DplPaths.returnManualLines(returnId), data: {'part_id': partId, 'qty': qty, 'note': ?note}),
          fallback: 'Could not add the line.', fromJson: _asMap);

  Future<DplApiResponse<Map<String, dynamic>>> removeReturnLine(int returnId, int lineId) =>
      _send(() => _dio.delete(DplPaths.returnLine(returnId, lineId)), fallback: 'Could not remove the line.', fromJson: _asMap);

  Future<DplApiResponse<Map<String, dynamic>>> decideReturn(int returnId, {required String disposition, List<int>? lineIds, String? note}) =>
      _send(() => _dio.post(DplPaths.returnDisposition(returnId), data: {'disposition': disposition, 'line_ids': ?lineIds, 'note': ?note}),
          fallback: 'Could not record the decision.', fromJson: _asMap);

  Future<DplApiResponse<DplCustomerReturn>> closeReturn(int returnId) =>
      _send(() => _dio.post(DplPaths.returnClose(returnId)),
          fallback: 'Could not close the return.', fromJson: (d) => DplCustomerReturn.fromJson(_asMap(d)));

  // --- Stock control (§10) ----------------------------------------------------

  /// Preview (default) or commit an opening-stock sheet exported from Ekatm.
  Future<DplApiResponse<DplOpeningImport>> importOpeningStock({
    required Uint8List bytes,
    required String fileName,
    bool commit = false,
    bool acceptErrors = false,
    bool confirmAdditional = false,
  }) =>
      _send(
          () => _dio.post(DplPaths.stockOpening,
              queryParameters: {
                if (commit) 'commit': 'true',
                if (acceptErrors) 'accept_errors': 'true',
                if (confirmAdditional) 'confirm_additional': 'true',
              },
              data: FormData.fromMap({'file': MultipartFile.fromBytes(bytes, filename: fileName)})),
          fallback: 'Could not read that stock file.',
          fromJson: (d) => DplOpeningImport.fromJson(_asMap(d)));

  Future<DplApiResponse<List<DplStockLot>>> listStockLots({int? partId}) =>
      _send(() => _dio.get(DplPaths.stockLots, queryParameters: {'part_id': ?partId}),
          fallback: 'Could not load lots.', fromJson: (d) => _asList(d).map(DplStockLot.fromJson).toList());

  Future<DplApiResponse<List<({String code, String label})>>> listStockReasons() =>
      _send(() => _dio.get(DplPaths.stockReasons),
          fallback: 'Could not load reasons.',
          fromJson: (d) => _asList(d).map((r) => (code: parseStringOr(r['code']), label: parseStringOr(r['label']))).toList());

  Future<DplApiResponse<List<DplStockAdjustment>>> listStockAdjustments({String? status}) =>
      _send(() => _dio.get(DplPaths.stockAdjustments, queryParameters: {'status': ?status}),
          fallback: 'Could not load adjustments.', fromJson: (d) => _asList(d).map(DplStockAdjustment.fromJson).toList());

  Future<DplApiResponse<DplStockAdjustment>> requestStockAdjustment(Map<String, dynamic> body) =>
      _send(() => _dio.post(DplPaths.stockAdjustments, data: body),
          fallback: 'Could not raise the adjustment.', fromJson: (d) => DplStockAdjustment.fromJson(_asMap(d)));

  Future<DplApiResponse<DplStockAdjustment>> decideStockAdjustment(int id, {required bool approve, String? note}) =>
      _send(() => _dio.post(approve ? DplPaths.stockAdjustmentApprove(id) : DplPaths.stockAdjustmentReject(id), data: {'note': ?note}),
          fallback: 'Could not record the decision.', fromJson: (d) => DplStockAdjustment.fromJson(_asMap(d)));

  /// Racks a counter may pick (needs only stock.count).
  Future<DplApiResponse<List<DplLocation>>> listCountLocations() =>
      _send(() => _dio.get(DplPaths.stockCountLocations),
          fallback: 'Could not load racks.', fromJson: (d) => _asList(d).map(DplLocation.fromJson).toList());

  Future<DplApiResponse<List<Map<String, dynamic>>>> listRackCounts({String? status}) =>
      _send(() => _dio.get(DplPaths.stockCounts, queryParameters: {'status': ?status}),
          fallback: 'Could not load counts.', fromJson: _asList);

  Future<DplApiResponse<DplRackCount>> startRackCount({List<int>? locationIds, String? zone, String? note}) =>
      _send(() => _dio.post(DplPaths.stockCounts, data: {'location_ids': ?locationIds, 'zone': ?zone, 'note': ?note}),
          fallback: 'Could not start the count.', fromJson: (d) => DplRackCount.fromJson(_asMap(d)));

  Future<DplApiResponse<DplRackCount>> getRackCount(int id) =>
      _send(() => _dio.get(DplPaths.stockCount(id)),
          fallback: 'Could not load the count.', fromJson: (d) => DplRackCount.fromJson(_asMap(d)));

  Future<DplApiResponse<Map<String, dynamic>>> scanRackCount(int id, {required String code, required int locationId}) =>
      _send(() => _dio.post(DplPaths.stockCountAction(id, 'scan'), data: {'code': code, 'location_id': locationId}),
          fallback: 'Could not record that pallet.', fromJson: _asMap);

  /// [action] is submit, cancel, approve or reject.
  Future<DplApiResponse<DplRackCount>> rackCountAction(int id, String action, {String? note}) =>
      _send(() => _dio.post(DplPaths.stockCountAction(id, action), data: {'note': ?note}),
          fallback: 'Could not $action the count.', fromJson: (d) => DplRackCount.fromJson(_asMap(d)));

  // --- Offline handhelds (§12) ------------------------------------------------

  Future<DplApiResponse<List<int>>> reserveSyncNumbers(String deviceId, {int size = 50}) =>
      _send(() => _dio.post(DplPaths.syncNumberBlock, data: {'device_id': deviceId, 'size': size}),
          fallback: 'Could not reserve pallet numbers.',
          fromJson: (d) => (_asMap(d)['seq_values'] as List? ?? const []).map((e) => parseIntOr(e)).toList());

  Future<DplApiResponse<DplSyncPushResult>> pushSync(String deviceId, List<DplSyncTxn> txns, {String? deviceName}) =>
      _send(() => _dio.post(DplPaths.syncPush, data: {'device_id': deviceId, 'device_name': ?deviceName, 'transactions': txns.map((t) => t.toJson()).toList()}),
          fallback: 'Could not sync.', fromJson: (d) => DplSyncPushResult.fromJson(_asMap(d)));

  /// Why a handheld is blocked, if it is: `blocked_detail` {seq, type, code, message}.
  Future<DplApiResponse<Map<String, dynamic>>> getSyncStatus(String deviceId) =>
      _send(() => _dio.get(DplPaths.syncStatus, queryParameters: {'device_id': deviceId}),
          fallback: 'Could not read sync status.', fromJson: _asMap);

  Future<DplApiResponse<List<DplSyncConflict>>> listSyncConflicts() =>
      _send(() => _dio.get(DplPaths.syncConflicts),
          fallback: 'Could not load sync conflicts.', fromJson: (d) => _asList(d).map(DplSyncConflict.fromJson).toList());

  Future<DplApiResponse<DplSyncPushResult>> resolveSyncConflict(int id, String action) =>
      _send(() => _dio.post(DplPaths.syncResolve(id), data: {'action': action}),
          fallback: 'Could not resolve it.', fromJson: (d) => DplSyncPushResult.fromJson(_asMap(d)));

  Future<DplApiResponse<List<Map<String, dynamic>>>> listSyncDevices() =>
      _send(() => _dio.get(DplPaths.syncDevices), fallback: 'Could not load devices.', fromJson: _asList);
}
