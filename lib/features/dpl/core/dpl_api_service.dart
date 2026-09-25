import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/dpl_admin.dart';
import '../models/dpl_dashboard_summary.dart';
import '../models/dpl_downtime_event.dart';
import '../models/dpl_downtime_event_detail.dart';
import '../models/dpl_downtime_reason.dart';
import '../models/dpl_excel_preview.dart';
import '../models/dpl_machine.dart';
import '../models/dpl_manpower_log.dart';
import '../models/dpl_organization.dart';
import '../models/dpl_pallet.dart';
import '../models/dpl_wheel_trolley.dart';
import '../models/dpl_spd.dart';
import '../models/dpl_monthly_chart.dart';
import '../models/dpl_part.dart';
import '../models/dpl_production_plan.dart';
import '../models/dpl_production_summary.dart';
import '../models/dpl_production_plan_item.dart';
import '../models/dpl_reports.dart';
import '../models/dpl_shift.dart';
import '../models/dpl_shift_summary.dart';
import '../models/dpl_start_stop.dart';
import '../models/dpl_supervisor.dart';
import '../models/dpl_supervisor_plan_detail.dart';
import '../models/dpl_carry_candidate.dart';
import '../models/_json_helpers.dart';
import '../models/dpl_buffer_norm.dart';
import '../models/dpl_customer_snapshot.dart';
import '../models/dpl_location.dart';
import '../models/dpl_part_sticker.dart';
import '../models/dpl_trip_label_scan.dart';
import '../models/dpl_dispatch_plan_actual.dart';
import '../models/dpl_dispatch_plan_inputs.dart';
import '../models/dpl_consolidated_slip.dart';
import '../models/dpl_dispatch_slip.dart';
import '../models/dpl_dispatch_slips_bulk.dart';
import '../models/dpl_dispatch_trip.dart';
import '../models/dpl_trip_journey_event.dart';
import '../models/dpl_trip_location.dart';
import '../models/dpl_identity.dart';
import '../models/dpl_part_field.dart';
import '../models/dpl_plant.dart';
import '../models/dpl_item_pause.dart';
import '../models/dpl_supervisor_today.dart';
import '../models/dpl_trolley_photo.dart';
import 'dpl_api_client.dart';
import 'dpl_api_response.dart';
import 'dpl_constants.dart';
import 'dpl_error_mapper.dart';
import '../models/dpl_customer_return.dart';
import '../models/dpl_logistics.dart';
import '../models/dpl_oem_dashboard.dart';
import '../models/dpl_report_subscription.dart';
import '../models/dpl_report_table.dart';
import '../models/dpl_stock_control.dart';
import '../models/dpl_sync.dart';

part 'dpl_api_maxion.dart';

/// Single, central wrapper around every DPL endpoint.
///
/// All public methods return [DplApiResponse]. Raw exceptions are caught
/// and converted to `DplApiResponse.error(...)` so callers never need a
/// try/catch.
class DplApiService {
  final Dio _dio;

  DplApiService(this._dio);

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Unwraps the `{ success, data, error }` envelope and parses [data]
  /// through [fromJson]. Tolerates raw shapes too (some servers return
  /// arrays/objects without the envelope).
  Future<DplApiResponse<T>> _send<T>(
    Future<Response<dynamic>> Function() request, {
    required String fallback,
    T Function(dynamic data)? fromJson,
  }) async {
    try {
      final response = await request();
      final body = response.data;

      if (body is Map) {
        final map = Map<String, dynamic>.from(body);
        if (map.containsKey('success')) {
          final ok = map['success'] == true;
          if (!ok) {
            return DplApiResponse.error(
              map['error']?.toString() ?? fallback,
              code: map['code']?.toString(),
              statusCode: response.statusCode,
              errorLocal: map['message_local']?.toString(),
            );
          }
          final data = map['data'];
          if (fromJson == null) return DplApiResponse.ok(null as T?);
          return DplApiResponse.ok(fromJson(data));
        }
      }

      // No envelope — pass the raw body to fromJson.
      if (fromJson == null) return DplApiResponse.ok(null as T?);
      return DplApiResponse.ok(fromJson(body));
    } on DioException catch (e) {
      return DplErrorMapper.fromDio<T>(e, fallback: fallback);
    } catch (e) {
      return DplErrorMapper.fromObject<T>(e, fallback: fallback);
    }
  }

  String _ymd(DateTime d) =>
      DateFormat('yyyy-MM-dd').format(d);

  Map<String, dynamic> _cleanQuery(Map<String, dynamic> raw) {
    raw.removeWhere((_, v) => v == null);
    return raw;
  }

  // ---------------------------------------------------------------------------
  // 1) Auth
  // ---------------------------------------------------------------------------

  Future<DplApiResponse<DplLoginResult>> login(
    String email,
    String password, {
    int? organizationId,
  }) {
    return _send<DplLoginResult>(
      () => _dio.post(
        DplPaths.authLogin,
        data: {
          'email': email,
          'password': password,
          'organization_id': ?organizationId,
        },
      ),
      fallback: 'Login failed. Please try again.',
      fromJson: (data) => DplLoginResult.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : const {},
      ),
    );
  }

  /// Public list of tenants used to populate the org selector on the
  /// login screen. Backend must allow this without a JWT.
  Future<DplApiResponse<List<DplOrganization>>> fetchOrganizations() {
    return _send<List<DplOrganization>>(
      () => _dio.get(DplPaths.authOrganizations),
      fallback: 'Unable to load organizations.',
      fromJson: (data) {
        if (data is! List) return const <DplOrganization>[];
        return data
            .whereType<Map>()
            .map((m) =>
                DplOrganization.fromJson(Map<String, dynamic>.from(m)))
            .toList();
      },
    );
  }

  /// The signed-in user, re-read from the server.
  ///
  /// THE `user` UNWRAP IS THE POINT OF THIS METHOD, NOT A DETAIL.
  ///
  /// `/auth/me` answers `{ success, data: { user: {...} } }`, and `_send`
  /// hands `fromJson` the `data` object — so what arrives here is the
  /// `{ user: ... }` WRAPPER, not the user. Parsing the wrapper as a user
  /// found no `permissions` key, which `DplUserProfile` correctly reads as
  /// "this server predates permissions" — and the whole app then fell back to
  /// permissive. Every `DplPermissionsController.refresh()` silently wiped the
  /// real permission list, so an administrator's switch had no effect on the
  /// device and controls the plant had turned OFF kept appearing.
  ///
  /// Both shapes are accepted because `/login` answers `{ token, user }` and
  /// a future endpoint may answer the user directly; guessing wrong here is
  /// expensive and costs one `is Map` check to avoid.
  Future<DplApiResponse<DplUserProfile>> me() {
    return _send<DplUserProfile>(
      () => _dio.get(DplPaths.authMe),
      fallback: 'Unable to load profile.',
      fromJson: (data) {
        final map = data is Map ? Map<String, dynamic>.from(data) : const {};
        final nested = map['user'];
        return DplUserProfile.fromJson(
          nested is Map
              ? Map<String, dynamic>.from(nested)
              : Map<String, dynamic>.from(map),
        );
      },
    );
  }

  Future<DplApiResponse<void>> logout() {
    return _send<void>(
      () => _dio.post(DplPaths.authLogout),
      fallback: 'Logout failed.',
    );
  }

  Future<DplApiResponse<void>> changePassword(
    String oldPassword,
    String newPassword,
  ) {
    return _send<void>(
      () => _dio.post(
        DplPaths.authChangePassword,
        data: {
          'old_password': oldPassword,
          'new_password': newPassword,
        },
      ),
      fallback: 'Failed to change password.',
    );
  }

  // ---------------------------------------------------------------------------
  // 2) Dashboard
  // ---------------------------------------------------------------------------

  Future<DplApiResponse<DplDashboardSummary>> getDashboard(DateTime date) {
    return _send<DplDashboardSummary>(
      () => _dio.get(
        DplPaths.dashboard,
        queryParameters: {'date': _ymd(date)},
      ),
      fallback: 'Failed to load dashboard.',
      fromJson: (data) {
        if (data is Map) {
          return DplDashboardSummary.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        return DplDashboardSummary.empty(date);
      },
    );
  }

  Future<DplApiResponse<List<DplAlert>>> getAlerts() {
    return _send<List<DplAlert>>(
      () => _dio.get(DplPaths.alerts),
      fallback: 'Failed to load alerts.',
      fromJson: (data) {
        // Backend shape:
        //   {
        //     "date": "...",
        //     "plans_behind":     [ {machine_name, plan_qty, actual_qty, ...} ],
        //     "active_downtimes": [ {machine_name, reason_name, duration_minutes, ...} ],
        //     "totals": { "plans_behind": N, "active_downtimes": M }
        //   }
        // We flatten both buckets into a single list of [DplAlert].
        final alerts = <DplAlert>[];

        void appendBucket(
          dynamic raw,
          DplAlert Function(Map<String, dynamic>) build,
        ) {
          if (raw is! List) return;
          for (final entry in raw) {
            if (entry is Map) {
              alerts.add(build(Map<String, dynamic>.from(entry)));
            }
          }
        }

        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          appendBucket(map['plans_behind'] ?? map['plansBehind'],
              DplAlert.fromPlanBehind);
          appendBucket(map['active_downtimes'] ?? map['activeDowntimes'],
              DplAlert.fromActiveDowntime);
          // Generic shape fallback if the backend ever ships a flat list.
          appendBucket(map['items'] ?? map['alerts'], DplAlert.fromJson);
        } else if (data is List) {
          appendBucket(data, DplAlert.fromJson);
        }

        return alerts;
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 3) Masters — Machines
  // ---------------------------------------------------------------------------

  Future<DplApiResponse<List<DplMachine>>> getMachines() {
    return _send<List<DplMachine>>(
      () => _dio.get(DplPaths.machines),
      fallback: 'Failed to load machines.',
      fromJson: _listFrom<DplMachine>(DplMachine.fromJson),
    );
  }

  Future<DplApiResponse<DplMachine>> createMachine(DplMachine m) {
    return _send<DplMachine>(
      () => _dio.post(DplPaths.machines, data: m.toCreateJson()),
      fallback: 'Failed to create machine.',
      fromJson: _oneFrom<DplMachine>(DplMachine.fromJson),
    );
  }

  Future<DplApiResponse<DplMachine>> updateMachine(int id, DplMachine m) {
    return _send<DplMachine>(
      () => _dio.put(DplPaths.machineById(id), data: m.toUpdateJson()),
      fallback: 'Failed to update machine.',
      fromJson: _oneFrom<DplMachine>(DplMachine.fromJson),
    );
  }

  Future<DplApiResponse<void>> deleteMachine(int id) {
    return _send<void>(
      () => _dio.delete(DplPaths.machineById(id)),
      fallback: 'Failed to delete machine.',
    );
  }

  // ---------------------------------------------------------------------------
  // 4) Masters — Parts
  // ---------------------------------------------------------------------------

  Future<DplApiResponse<DplPagedResult<DplPart>>> getParts({
    String? q,
    String? machineName,
    int page = 1,
    int limit = 20,
  }) {
    return _send<DplPagedResult<DplPart>>(
      () => _dio.get(
        DplPaths.parts,
        queryParameters: _cleanQuery({
          if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
          if (machineName != null && machineName.trim().isNotEmpty)
            'machine_name': machineName.trim(),
          'page': page,
          'limit': limit,
        }),
      ),
      fallback: 'Failed to load parts.',
      fromJson: (data) {
        // Real backend shape:
        //   { "parts": [...], "pagination": {page, limit, total, totalPages} }
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);

          // Find the items list under any of the common keys.
          List<dynamic>? rawItems;
          for (final key in const ['parts', 'items', 'results', 'data']) {
            final v = map[key];
            if (v is List) {
              rawItems = v;
              break;
            }
          }

          if (rawItems != null) {
            final items = rawItems
                .whereType<Map>()
                .map((e) => DplPart.fromJson(Map<String, dynamic>.from(e)))
                .toList();

            // Pagination may be at root OR nested under `pagination`.
            Map<String, dynamic> p;
            final nested = map['pagination'];
            if (nested is Map) {
              p = Map<String, dynamic>.from(nested);
            } else {
              p = map;
            }

            int parseInt(dynamic v, int fallback) {
              if (v is int) return v;
              if (v is double) return v.toInt();
              return int.tryParse(v?.toString() ?? '') ?? fallback;
            }

            return DplPagedResult<DplPart>(
              items: items,
              page: parseInt(p['page'], page),
              limit: parseInt(p['limit'], limit),
              total: parseInt(p['total'], items.length),
            );
          }
        }
        if (data is List) {
          final items = data
              .whereType<Map>()
              .map((e) => DplPart.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          return DplPagedResult<DplPart>(
            items: items,
            page: page,
            limit: limit,
            total: items.length,
          );
        }
        return DplPagedResult<DplPart>.empty();
      },
    );
  }

  Future<DplApiResponse<DplPart>> createPart(DplPart p) {
    return _send<DplPart>(
      () => _dio.post(DplPaths.parts, data: p.toJsonForWrite()),
      fallback: 'Failed to create part.',
      fromJson: _oneFrom<DplPart>(DplPart.fromJson),
    );
  }

  Future<DplApiResponse<DplPart>> updatePart(int id, DplPart p) {
    return _send<DplPart>(
      () => _dio.put(DplPaths.partById(id), data: p.toJsonForWrite()),
      fallback: 'Failed to update part.',
      fromJson: _oneFrom<DplPart>(DplPart.fromJson),
    );
  }

  Future<DplApiResponse<void>> deletePart(int id) {
    return _send<void>(
      () => _dio.delete(DplPaths.partById(id)),
      fallback: 'Failed to delete part.',
    );
  }

  // ---------------------------------------------------------------------------
  // 5) Masters — Supervisors
  // ---------------------------------------------------------------------------

  Future<DplApiResponse<List<DplSupervisor>>> getSupervisors() {
    return _send<List<DplSupervisor>>(
      () => _dio.get(DplPaths.supervisors),
      fallback: 'Failed to load supervisors.',
      fromJson: _listFrom<DplSupervisor>(DplSupervisor.fromJson),
    );
  }

  // ---------------------------------------------------------------------------
  // 6) Masters — Downtime Reasons
  // ---------------------------------------------------------------------------

  Future<DplApiResponse<List<DplDowntimeReason>>> getDowntimeReasons() {
    return _send<List<DplDowntimeReason>>(
      () => _dio.get(DplPaths.downtimeReasons),
      fallback: 'Failed to load downtime reasons.',
      fromJson: _listFrom<DplDowntimeReason>(DplDowntimeReason.fromJson),
    );
  }

  Future<DplApiResponse<DplDowntimeReason>> createDowntimeReason(
    DplDowntimeReason r,
  ) {
    return _send<DplDowntimeReason>(
      () => _dio.post(DplPaths.downtimeReasons, data: r.toJsonForWrite()),
      fallback: 'Failed to create downtime reason.',
      fromJson: _oneFrom<DplDowntimeReason>(DplDowntimeReason.fromJson),
    );
  }

  Future<DplApiResponse<DplDowntimeReason>> updateDowntimeReason(
    int id,
    DplDowntimeReason r,
  ) {
    return _send<DplDowntimeReason>(
      () => _dio.put(
        DplPaths.downtimeReasonById(id),
        data: r.toJsonForWrite(),
      ),
      fallback: 'Failed to update downtime reason.',
      fromJson: _oneFrom<DplDowntimeReason>(DplDowntimeReason.fromJson),
    );
  }

  Future<DplApiResponse<void>> deleteDowntimeReason(int id) {
    return _send<void>(
      () => _dio.delete(DplPaths.downtimeReasonById(id)),
      fallback: 'Failed to delete downtime reason.',
    );
  }

  // ---------------------------------------------------------------------------
  // 7) Plans
  // ---------------------------------------------------------------------------

  /// Uploads an Excel file's [bytes] under the given [filename].
  ///
  /// We take bytes + name (not a `dart:io.File`) so this works identically
  /// on web (where file_picker returns bytes) and on mobile/desktop.
  Future<DplApiResponse<DplExcelPreview>> uploadExcel({
    required Uint8List bytes,
    required String filename,
  }) async {
    try {
      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(
          bytes,
          filename: filename,
        ),
      });
      return _send<DplExcelPreview>(
        () => _dio.post(DplPaths.plansUploadExcel, data: formData),
        fallback: 'Failed to upload Excel.',
        fromJson: (data) {
          if (data is Map) {
            return DplExcelPreview.fromJson(Map<String, dynamic>.from(data));
          }
          if (data is List) {
            // Backend returned the rows directly (no envelope).
            return DplExcelPreview.fromRows(data);
          }
          return const DplExcelPreview(machines: [], warnings: []);
        },
      );
    } catch (e) {
      return DplErrorMapper.fromObject<DplExcelPreview>(
        e,
        fallback: 'Failed to upload Excel.',
      );
    }
  }

  Future<DplApiResponse<List<DplProductionPlan>>> createPlans(
    DplCreatePlansRequest req,
  ) {
    return _send<List<DplProductionPlan>>(
      () => _dio.post(DplPaths.plans, data: req.toJson()),
      fallback: 'Failed to submit plan.',
      fromJson: (data) {
        if (data is List) {
          return data
              .whereType<Map>()
              .map((e) => DplProductionPlan.fromJson(
                    Map<String, dynamic>.from(e),
                  ))
              .toList();
        }
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final raw = m['plans'] ?? m['items'];
          if (raw is List) {
            return raw
                .whereType<Map>()
                .map((e) => DplProductionPlan.fromJson(
                      Map<String, dynamic>.from(e),
                    ))
                .toList();
          }
          // Single plan as response
          return [DplProductionPlan.fromJson(m)];
        }
        return const [];
      },
    );
  }

  Future<DplApiResponse<List<DplProductionPlan>>> listPlans({
    DateTime? date,
    DateTime? from,
    DateTime? to,
    int? machineId,
    int? supervisorUserId,
    String? status,
  }) {
    return _send<List<DplProductionPlan>>(
      () => _dio.get(
        DplPaths.plans,
        queryParameters: _cleanQuery({
          if (date != null) 'date': _ymd(date),
          if (from != null) 'from': _ymd(from),
          if (to != null) 'to': _ymd(to),
          'machine_id': ?machineId,
          'supervisor_user_id': ?supervisorUserId,
          if (status != null && status.isNotEmpty) 'status': status,
        }),
      ),
      fallback: 'Failed to load plans.',
      fromJson: _listFrom<DplProductionPlan>(DplProductionPlan.fromJson),
    );
  }

  Future<DplApiResponse<DplProductionPlan>> getPlan(int id) {
    return _send<DplProductionPlan>(
      () => _dio.get(DplPaths.planById(id)),
      fallback: 'Failed to load plan.',
      fromJson: _oneFrom<DplProductionPlan>(DplProductionPlan.fromJson),
    );
  }

  Future<DplApiResponse<DplProductionPlan>> updatePlan(
    int id,
    DplUpdatePlanRequest req,
  ) {
    return _send<DplProductionPlan>(
      () => _dio.put(DplPaths.planById(id), data: req.toJson()),
      fallback: 'Failed to update plan.',
      fromJson: _oneFrom<DplProductionPlan>(DplProductionPlan.fromJson),
    );
  }

  Future<DplApiResponse<void>> deletePlan(int id) {
    return _send<void>(
      () => _dio.delete(DplPaths.planById(id)),
      fallback: 'Failed to delete plan.',
    );
  }

  Future<DplApiResponse<DplProductionPlan>> lockPlan(int id) {
    return _send<DplProductionPlan>(
      () => _dio.post(DplPaths.planLock(id)),
      fallback: 'Failed to lock plan.',
      fromJson: _oneFrom<DplProductionPlan>(DplProductionPlan.fromJson),
    );
  }

  /// `POST /manager/plans/:id/change-status` — manager moves a plan to
  /// any of the 5 statuses. Both [status] and [reason] are mandatory.
  Future<DplApiResponse<DplProductionPlan>> changePlanStatus(
    int planId, {
    required String status,
    required String reason,
  }) {
    return _send<DplProductionPlan>(
      () => _dio.post(
        DplPaths.planChangeStatus(planId),
        data: {'status': status, 'reason': reason},
      ),
      fallback: 'Failed to change plan status.',
      fromJson: _oneFrom<DplProductionPlan>(DplProductionPlan.fromJson),
    );
  }

  /// `POST /manager/plans/:planId/items/:itemId/change-status` — manager
  /// overrides an item's status (pending / in_progress / completed).
  /// Both [status] and [reason] are mandatory; mirrors the plan-level
  /// change-status contract.
  Future<DplApiResponse<DplProductionPlanItem>> changePlanItemStatus(
    int planId,
    int itemId, {
    required String status,
    required String reason,
  }) {
    return _send<DplProductionPlanItem>(
      () => _dio.post(
        DplPaths.planItemChangeStatus(planId, itemId),
        data: {'status': status, 'reason': reason},
      ),
      fallback: 'Failed to change item status.',
      fromJson:
          _oneFrom<DplProductionPlanItem>(DplProductionPlanItem.fromJson),
    );
  }

  /// `GET /manager/plans/carry-forward-candidates` — items from past
  /// submitted plans that still have leftover qty and haven't been
  /// carried forward yet. Drives the Upload Plan screen's auto-fill
  /// section.
  ///
  /// [forDate] is sent as `YYYY-MM-DD`; the server defaults to today
  /// in the plant timezone when omitted.
  Future<DplApiResponse<List<DplCarryCandidate>>> getCarryForwardCandidates({
    required int machineId,
    DateTime? forDate,
  }) {
    return _send<List<DplCarryCandidate>>(
      () => _dio.get(
        DplPaths.carryForwardCandidates,
        queryParameters: _cleanQuery({
          'machine_id': machineId,
          if (forDate != null) 'for_date': _ymd(forDate),
        }),
      ),
      fallback: 'Failed to load carry-forward candidates.',
      fromJson: (data) {
        if (data is Map) {
          final raw = data['candidates'];
          if (raw is List) {
            return raw
                .whereType<Map>()
                .map((e) => DplCarryCandidate.fromJson(
                      Map<String, dynamic>.from(e),
                    ))
                .toList();
          }
        }
        if (data is List) {
          return data
              .whereType<Map>()
              .map((e) => DplCarryCandidate.fromJson(
                    Map<String, dynamic>.from(e),
                  ))
              .toList();
        }
        return const <DplCarryCandidate>[];
      },
    );
  }

  /// `POST /manager/plans/:planId/items/:itemId/carry-forward` — move
  /// the leftover quantity of a partially-complete item into a NEW
  /// item assigned to [shiftId]. The source item is closed (status =
  /// completed) unless [completeSource] is false.
  ///
  /// [planQty] defaults to `(item.planQty - item.actualQty)` on the
  /// server when omitted from the body.
  Future<DplApiResponse<DplProductionPlanItem>> carryForwardItem(
    int planId,
    int itemId, {
    required int shiftId,
    int? planQty,
    bool completeSource = true,
  }) {
    return _send<DplProductionPlanItem>(
      () => _dio.post(
        DplPaths.planItemCarryForward(planId, itemId),
        data: {
          'shift_id': shiftId,
          'plan_qty': ?planQty,
          'complete_source': completeSource,
        },
      ),
      fallback: 'Failed to carry item forward.',
      fromJson:
          _oneFrom<DplProductionPlanItem>(DplProductionPlanItem.fromJson),
    );
  }

  /// `GET /manager/plans/:id/pauses` — manager-side audit of every
  /// item pause on a plan.
  Future<DplApiResponse<List<DplItemPause>>> getManagerPlanPauses(
    int planId,
  ) {
    return _send<List<DplItemPause>>(
      () => _dio.get(DplPaths.managerPlanPauses(planId)),
      fallback: 'Failed to load pauses.',
      fromJson: _listFrom<DplItemPause>(DplItemPause.fromJson),
    );
  }

  /// `GET /manager/plans/:id/items/:itemId/pauses` — audit per item.
  Future<DplApiResponse<List<DplItemPause>>> getManagerItemPauses(
    int planId,
    int itemId,
  ) {
    return _send<List<DplItemPause>>(
      () => _dio.get(DplPaths.managerPlanItemPauses(planId, itemId)),
      fallback: 'Failed to load pauses.',
      fromJson: _listFrom<DplItemPause>(DplItemPause.fromJson),
    );
  }

  Future<DplApiResponse<DplProductionPlanItem>> addPlanItem(
    int planId,
    DplProductionPlanItem item,
  ) {
    return _send<DplProductionPlanItem>(
      () => _dio.post(
        DplPaths.planItems(planId),
        data: item.toCreateJson(),
      ),
      fallback: 'Failed to add item.',
      fromJson:
          _oneFrom<DplProductionPlanItem>(DplProductionPlanItem.fromJson),
    );
  }

  Future<DplApiResponse<DplProductionPlanItem>> updatePlanItem(
    int planId,
    int itemId,
    DplProductionPlanItem item,
  ) {
    return _send<DplProductionPlanItem>(
      () => _dio.put(
        DplPaths.planItemById(planId, itemId),
        data: item.toUpdateJson(),
      ),
      fallback: 'Failed to update item.',
      fromJson:
          _oneFrom<DplProductionPlanItem>(DplProductionPlanItem.fromJson),
    );
  }

  Future<DplApiResponse<void>> deletePlanItem(int planId, int itemId) {
    return _send<void>(
      () => _dio.delete(DplPaths.planItemById(planId, itemId)),
      fallback: 'Failed to delete item.',
    );
  }

  // ---------------------------------------------------------------------------
  // 8) Reports
  // ---------------------------------------------------------------------------

  Future<DplApiResponse<DplPlanVsActualReport>> reportPlanVsActual({
    DateTime? from,
    DateTime? to,
    int? machineId,
    int? shiftId,
    List<String>? groupBy,
  }) {
    return _send<DplPlanVsActualReport>(
      () => _dio.get(
        DplPaths.reportPlanVsActual,
        queryParameters: _cleanQuery({
          if (from != null) 'from': _ymd(from),
          if (to != null) 'to': _ymd(to),
          'machine_id': ?machineId,
          'shift_id': ?shiftId,
          if (groupBy != null && groupBy.isNotEmpty)
            'group_by': groupBy.join(','),
        }),
      ),
      fallback: 'Failed to load report.',
      fromJson: (data) {
        if (data is Map) {
          return DplPlanVsActualReport.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        if (data is List) {
          return DplPlanVsActualReport.fromJson({'rows': data});
        }
        return DplPlanVsActualReport.empty();
      },
    );
  }

  /// `GET /manager/reports/downtime/events` — flat list of every closed
  /// downtime occurrence in the requested window, enriched with machine,
  /// shift, supervisor, reason + category, and remarks. Mirrors the
  /// per-event "Details" sheet of the Excel export. Sorted newest-first
  /// by the backend. Same filter shape as [reportDowntime].
  Future<DplApiResponse<List<DplDowntimeEventDetail>>> listDowntimeEvents({
    DateTime? from,
    DateTime? to,
    int? machineId,
    int? shiftId,
  }) {
    return _send<List<DplDowntimeEventDetail>>(
      () => _dio.get(
        DplPaths.reportDowntimeEvents,
        queryParameters: _cleanQuery({
          if (from != null) 'from': _ymd(from),
          if (to != null) 'to': _ymd(to),
          'machine_id': ?machineId,
          'shift_id': ?shiftId,
        }),
      ),
      fallback: 'Failed to load downtime events.',
      fromJson: (data) {
        List<dynamic>? raw;
        if (data is List) {
          raw = data;
        } else if (data is Map) {
          for (final key in const ['events', 'items', 'data', 'rows']) {
            final v = data[key];
            if (v is List) {
              raw = v;
              break;
            }
          }
        }
        if (raw == null) return const <DplDowntimeEventDetail>[];
        return raw
            .whereType<Map>()
            .map((e) =>
                DplDowntimeEventDetail.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      },
    );
  }

  Future<DplApiResponse<DplDowntimeReport>> reportDowntime({
    DateTime? from,
    DateTime? to,
    int? machineId,
    int? shiftId,
    List<String>? groupBy,
  }) {
    return _send<DplDowntimeReport>(
      () => _dio.get(
        DplPaths.reportDowntime,
        queryParameters: _cleanQuery({
          if (from != null) 'from': _ymd(from),
          if (to != null) 'to': _ymd(to),
          'machine_id': ?machineId,
          'shift_id': ?shiftId,
          if (groupBy != null && groupBy.isNotEmpty)
            'group_by': groupBy.join(','),
        }),
      ),
      fallback: 'Failed to load downtime report.',
      fromJson: (data) {
        if (data is Map) {
          return DplDowntimeReport.fromJson(Map<String, dynamic>.from(data));
        }
        if (data is List) {
          return DplDowntimeReport.fromJson({'rows': data});
        }
        return DplDowntimeReport.empty();
      },
    );
  }

  Future<DplApiResponse<DplSupervisorPerformanceReport>>
      reportSupervisorPerformance({
    DateTime? from,
    DateTime? to,
    int? machineId,
  }) {
    return _send<DplSupervisorPerformanceReport>(
      () => _dio.get(
        DplPaths.reportSupervisorPerformance,
        queryParameters: _cleanQuery({
          if (from != null) 'from': _ymd(from),
          if (to != null) 'to': _ymd(to),
          'machine_id': ?machineId,
        }),
      ),
      fallback: 'Failed to load supervisor performance.',
      fromJson: (data) {
        if (data is Map) {
          return DplSupervisorPerformanceReport.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        if (data is List) {
          return DplSupervisorPerformanceReport.fromJson({'rows': data});
        }
        return DplSupervisorPerformanceReport.empty();
      },
    );
  }

  Future<DplApiResponse<DplPartWiseReport>> reportPartWise({
    DateTime? from,
    DateTime? to,
    int? machineId,
  }) {
    return _send<DplPartWiseReport>(
      () => _dio.get(
        DplPaths.reportPartWise,
        queryParameters: _cleanQuery({
          if (from != null) 'from': _ymd(from),
          if (to != null) 'to': _ymd(to),
          'machine_id': ?machineId,
        }),
      ),
      fallback: 'Failed to load part-wise report.',
      fromJson: (data) {
        if (data is Map) {
          return DplPartWiseReport.fromJson(Map<String, dynamic>.from(data));
        }
        if (data is List) {
          return DplPartWiseReport.fromJson({'rows': data});
        }
        return DplPartWiseReport.empty();
      },
    );
  }

  /// Downloads a report as bytes. The caller is responsible for saving /
  /// sharing the file (use `saveReportBytes` from the existing reports
  /// feature, which is what this app already does).
  Future<DplApiResponse<Uint8List>> exportReportBytes({
    required String type,
    required String format,
    DateTime? from,
    DateTime? to,
    int? machineId,
  }) async {
    try {
      final response = await _dio.get<List<int>>(
        DplPaths.reportExport,
        queryParameters: _cleanQuery({
          'type': type,
          'format': format,
          if (from != null) 'from': _ymd(from),
          if (to != null) 'to': _ymd(to),
          'machine_id': ?machineId,
        }),
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data == null) {
        return DplApiResponse.error('Empty file received from server.');
      }
      return DplApiResponse.ok(Uint8List.fromList(data));
    } on DioException catch (e) {
      return DplErrorMapper.fromDio<Uint8List>(
        e,
        fallback: 'Failed to export report.',
      );
    } catch (e) {
      return DplErrorMapper.fromObject<Uint8List>(
        e,
        fallback: 'Failed to export report.',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 9) Shifts master
  // ---------------------------------------------------------------------------

  Future<DplApiResponse<List<DplShift>>> getShifts({
    bool includeInactive = false,
  }) {
    return _send<List<DplShift>>(
      () => _dio.get(
        DplPaths.shifts,
        queryParameters: _cleanQuery({
          if (includeInactive) 'include_inactive': 'true',
        }),
      ),
      fallback: 'Failed to load shifts.',
      fromJson: _listFrom<DplShift>(DplShift.fromJson),
    );
  }

  Future<DplApiResponse<DplShift>> createShift(DplShift s) {
    return _send<DplShift>(
      () => _dio.post(DplPaths.shifts, data: s.toCreateJson()),
      fallback: 'Failed to create shift.',
      fromJson: _oneFrom<DplShift>(DplShift.fromJson),
    );
  }

  Future<DplApiResponse<DplShift>> updateShift(int id, DplShift s) {
    return _send<DplShift>(
      () => _dio.put(DplPaths.shiftById(id), data: s.toUpdateJson()),
      fallback: 'Failed to update shift.',
      fromJson: _oneFrom<DplShift>(DplShift.fromJson),
    );
  }

  Future<DplApiResponse<void>> deleteShift(int id) {
    return _send<void>(
      () => _dio.delete(DplPaths.shiftById(id)),
      fallback: 'Failed to delete shift.',
    );
  }

  // ---------------------------------------------------------------------------
  // 10) Manpower master
  // ---------------------------------------------------------------------------

  Future<DplApiResponse<List<DplManpowerLog>>> getManpower({
    DateTime? from,
    DateTime? to,
    int? shiftId,
    int? machineId,
  }) {
    return _send<List<DplManpowerLog>>(
      () => _dio.get(
        DplPaths.manpower,
        queryParameters: _cleanQuery({
          if (from != null) 'from': _ymd(from),
          if (to != null) 'to': _ymd(to),
          'shift_id': ?shiftId,
          'machine_id': ?machineId,
        }),
      ),
      fallback: 'Failed to load manpower.',
      fromJson: _listFrom<DplManpowerLog>(DplManpowerLog.fromJson),
    );
  }

  Future<DplApiResponse<DplManpowerLog>> createManpower(DplManpowerLog m) {
    return _send<DplManpowerLog>(
      () => _dio.post(DplPaths.manpower, data: m.toCreateJson()),
      fallback: 'Failed to create manpower entry.',
      fromJson: _oneFrom<DplManpowerLog>(DplManpowerLog.fromJson),
    );
  }

  Future<DplApiResponse<DplManpowerLog>> updateManpower(
    int id,
    int headcount,
  ) {
    return _send<DplManpowerLog>(
      () => _dio.put(
        DplPaths.manpowerById(id),
        data: {'headcount': headcount},
      ),
      fallback: 'Failed to update headcount.',
      fromJson: _oneFrom<DplManpowerLog>(DplManpowerLog.fromJson),
    );
  }

  Future<DplApiResponse<void>> deleteManpower(int id) {
    return _send<void>(
      () => _dio.delete(DplPaths.manpowerById(id)),
      fallback: 'Failed to delete manpower entry.',
    );
  }

  /// Supervisor side — idempotent bulk upsert of today's manpower entries.
  Future<DplApiResponse<List<DplManpowerLog>>> supervisorPostManpowerToday(
    List<DplManpowerLog> entries,
  ) {
    return _send<List<DplManpowerLog>>(
      () => _dio.post(
        DplPaths.supervisorManpowerToday,
        data: entries.map((e) => e.toCreateJson()).toList(),
      ),
      fallback: 'Failed to save manpower.',
      fromJson: _listFrom<DplManpowerLog>(DplManpowerLog.fromJson),
    );
  }

  // ---------------------------------------------------------------------------
  // 11) Monthly DPL chart (composite report)
  // ---------------------------------------------------------------------------

  Future<DplApiResponse<DplMonthlyChart>> reportDplChart({
    required DateTime from,
    required DateTime to,
  }) {
    return _send<DplMonthlyChart>(
      () => _dio.get(
        DplPaths.reportDplChart,
        queryParameters: {'from': _ymd(from), 'to': _ymd(to)},
      ),
      fallback: 'Failed to load monthly chart.',
      fromJson: (data) {
        if (data is Map) {
          return DplMonthlyChart.fromJson(Map<String, dynamic>.from(data));
        }
        return DplMonthlyChart.empty(from, to);
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 12) Identity verification (selfie gate)
  // ---------------------------------------------------------------------------

  /// `GET /supervisor/identity/status` — is the supervisor currently
  /// verified, and until when.
  Future<DplApiResponse<DplIdentityStatus>> getIdentityStatus() {
    return _send<DplIdentityStatus>(
      () => _dio.get(DplPaths.supervisorIdentityStatus),
      fallback: 'Failed to load identity status.',
      fromJson: (data) {
        if (data is Map) {
          return DplIdentityStatus.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        // Defensive default — treat as "not verified" when the shape
        // is unexpected. Forces the gate to prompt for a fresh selfie.
        return const DplIdentityStatus(
          required: true,
          verified: false,
          verifiedForCurrentShift: false,
        );
      },
    );
  }

  /// `POST /supervisor/identity/verify` — multipart upload of a selfie.
  ///
  /// [context] must be one of `DplIdentityContext.*` values. [planId]
  /// and [planItemId] are optional but recommended so the audit row
  /// records exactly what the supervisor was about to do.
  Future<DplApiResponse<DplIdentityVerification>> verifyIdentity({
    required Uint8List bytes,
    required String filename,
    required String context,
    int? planId,
    int? planItemId,
  }) async {
    try {
      final form = FormData.fromMap({
        'photo': MultipartFile.fromBytes(bytes, filename: filename),
        'context': context,
        'plan_id': ?planId,
        'plan_item_id': ?planItemId,
      });
      return _send<DplIdentityVerification>(
        () => _dio.post(DplPaths.supervisorIdentityVerify, data: form),
        fallback: 'Failed to verify identity.',
        fromJson: (data) {
          if (data is Map) {
            return DplIdentityVerification.fromJson(
              Map<String, dynamic>.from(data),
            );
          }
          throw const FormatException('Expected object response.');
        },
      );
    } catch (e) {
      return DplErrorMapper.fromObject<DplIdentityVerification>(
        e,
        fallback: 'Failed to verify identity.',
      );
    }
  }

  /// `GET /supervisor/identity/:id/photo` — raw image bytes. Supervisor
  /// can only read their own.
  Future<DplApiResponse<Uint8List>> getSupervisorIdentityPhoto(int id) async {
    try {
      final response = await _dio.get<List<int>>(
        DplPaths.supervisorIdentityPhoto(id),
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data == null) {
        return DplApiResponse.error('Empty photo response.');
      }
      return DplApiResponse.ok(Uint8List.fromList(data));
    } on DioException catch (e) {
      return DplErrorMapper.fromDio<Uint8List>(
        e,
        fallback: 'Failed to load photo.',
      );
    } catch (e) {
      return DplErrorMapper.fromObject<Uint8List>(
        e,
        fallback: 'Failed to load photo.',
      );
    }
  }

  /// `GET /manager/identity-verifications` — paginated audit log.
  Future<DplApiResponse<DplPagedResult<DplIdentityVerification>>>
      listIdentityVerifications({
    int? supervisorId,
    int? shiftId,
    DateTime? from,
    DateTime? to,
    String? context,
    bool? flagged,
    int page = 1,
    int limit = 20,
  }) {
    return _send<DplPagedResult<DplIdentityVerification>>(
      () => _dio.get(
        DplPaths.managerIdentityVerifications,
        queryParameters: _cleanQuery({
          'supervisor_id': ?supervisorId,
          'shift_id': ?shiftId,
          if (from != null) 'from': _ymd(from),
          if (to != null) 'to': _ymd(to),
          if (context != null && context.isNotEmpty) 'context': context,
          'flagged': ?flagged,
          'page': page,
          'limit': limit,
        }),
      ),
      fallback: 'Failed to load audit log.',
      fromJson: (data) {
        int parseInt(dynamic v, int fb) {
          if (v is int) return v;
          if (v is double) return v.toInt();
          return int.tryParse(v?.toString() ?? '') ?? fb;
        }

        List<DplIdentityVerification> parseList(List raw) => raw
            .whereType<Map>()
            .map((e) => DplIdentityVerification.fromJson(
                  Map<String, dynamic>.from(e),
                ))
            .toList();

        // Server may return a bare array, or a map with items + pagination.
        if (data is List) {
          final items = parseList(data);
          return DplPagedResult<DplIdentityVerification>(
            items: items,
            page: page,
            limit: limit,
            total: items.length,
          );
        }
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          List<dynamic>? raw;
          for (final key in const [
            'items',
            'identity_verifications',
            'identityVerifications',
            'verifications',
            'data',
            'rows',
            'results',
          ]) {
            final v = map[key];
            if (v is List) {
              raw = v;
              break;
            }
          }
          if (raw != null) {
            final items = parseList(raw);
            final nested = map['pagination'];
            final p =
                nested is Map ? Map<String, dynamic>.from(nested) : map;
            return DplPagedResult<DplIdentityVerification>(
              items: items,
              page: parseInt(p['page'], page),
              limit: parseInt(p['limit'], limit),
              total: parseInt(p['total'], items.length),
            );
          }
        }
        return DplPagedResult<DplIdentityVerification>.empty();
      },
    );
  }

  /// `GET /manager/identity-verifications/:id/photo` — manager view of a
  /// specific supervisor's verification photo.
  Future<DplApiResponse<Uint8List>> getManagerIdentityPhoto(int id) async {
    try {
      final response = await _dio.get<List<int>>(
        DplPaths.managerIdentityPhoto(id),
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data == null) {
        return DplApiResponse.error('Empty photo response.');
      }
      return DplApiResponse.ok(Uint8List.fromList(data));
    } on DioException catch (e) {
      return DplErrorMapper.fromDio<Uint8List>(
        e,
        fallback: 'Failed to load photo.',
      );
    } catch (e) {
      return DplErrorMapper.fromObject<Uint8List>(
        e,
        fallback: 'Failed to load photo.',
      );
    }
  }

  /// `POST /manager/identity-verifications/:id/flag` — manager flags a
  /// verification as suspicious.
  Future<DplApiResponse<DplIdentityVerification>> flagIdentityVerification(
    int id,
    String reason,
  ) {
    return _send<DplIdentityVerification>(
      () => _dio.post(
        DplPaths.managerIdentityFlag(id),
        data: {'reason': reason},
      ),
      fallback: 'Failed to flag verification.',
      fromJson: (data) {
        if (data is Map) {
          return DplIdentityVerification.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        throw const FormatException('Expected object response.');
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 13) Supervisor (Phase 2)
  // ---------------------------------------------------------------------------

  /// `GET /supervisor/today` — supervisor's plans for current shift date.
  Future<DplApiResponse<SupervisorTodayResponse>> supervisorToday() {
    return _send<SupervisorTodayResponse>(
      () => _dio.get(DplPaths.supervisorToday),
      fallback: 'Failed to load today\'s plans.',
      fromJson: (data) {
        if (data is Map) {
          return SupervisorTodayResponse.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        return SupervisorTodayResponse.empty(DateTime.now());
      },
    );
  }

  /// `GET /supervisor/plans/:id` — full plan + active downtime + history.
  Future<DplApiResponse<DplSupervisorPlanDetail>> supervisorGetPlan(int id) {
    return _send<DplSupervisorPlanDetail>(
      () => _dio.get(DplPaths.supervisorPlan(id)),
      fallback: 'Failed to load plan.',
      fromJson: (data) {
        if (data is Map) {
          return DplSupervisorPlanDetail.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        throw const FormatException('Expected object response for plan.');
      },
    );
  }

  /// `POST /supervisor/plans/:planId/items/:itemId/start` — begin production.
  Future<DplApiResponse<StartItemResponse>> startItem(
    int planId,
    int itemId,
  ) {
    return _send<StartItemResponse>(
      () => _dio.post(DplPaths.supervisorItemStart(planId, itemId)),
      fallback: 'Failed to start item.',
      fromJson: (data) {
        if (data is Map) {
          return StartItemResponse.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        throw const FormatException('Expected object response for start.');
      },
    );
  }

  /// `POST /supervisor/plans/:planId/items/:itemId/stop` — finish production.
  ///
  /// [trolleyPhotoId] is required by the backend when the trolley-photo
  /// gate is enabled (`DPL_TROLLEY_PHOTO_REQUIRED=true`). Upload the
  /// photo via [uploadTrolleyPhoto] first, then pass the returned `id`.
  Future<DplApiResponse<StopItemResponse>> stopItem(
    int planId,
    int itemId, {
    required int actualQty,
    String? remarks,
    int? trolleyPhotoId,
  }) {
    return _send<StopItemResponse>(
      () => _dio.post(
        DplPaths.supervisorItemStop(planId, itemId),
        data: {
          'actual_qty': actualQty,
          if (remarks != null && remarks.trim().isNotEmpty)
            'remarks': remarks.trim(),
          'trolley_photo_id': ?trolleyPhotoId,
        },
      ),
      fallback: 'Failed to stop item.',
      fromJson: (data) {
        if (data is Map) {
          return StopItemResponse.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        throw const FormatException('Expected object response for stop.');
      },
    );
  }

  /// `PATCH /supervisor/plans/:planId/items/:itemId/actual` — debounced
  /// in-flight quantity updates while production is running.
  Future<DplApiResponse<void>> updateActualQty(
    int planId,
    int itemId,
    int actualQty,
  ) {
    return _send<void>(
      () => _dio.patch(
        DplPaths.supervisorItemActual(planId, itemId),
        data: {'actual_qty': actualQty},
      ),
      fallback: 'Failed to update actual quantity.',
    );
  }

  /// `POST /supervisor/plans/:planId/downtime/start` — open a downtime.
  ///
  /// [machineId] is required by the backend even though [planId] is in
  /// the URL.
  Future<DplApiResponse<DplDowntimeEvent>> startDowntime({
    required int planId,
    required int machineId,
    required int reasonId,
    int? planItemId,
    String? remarks,
  }) {
    return _send<DplDowntimeEvent>(
      () => _dio.post(
        DplPaths.supervisorDowntimeStart(planId),
        data: {
          'machine_id': machineId,
          'reason_id': reasonId,
          'plan_item_id': ?planItemId,
          if (remarks != null && remarks.trim().isNotEmpty)
            'remarks': remarks.trim(),
        },
      ),
      fallback: 'Failed to start downtime.',
      fromJson: (data) {
        if (data is Map) {
          return DplDowntimeEvent.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        throw const FormatException('Expected object response for downtime.');
      },
    );
  }

  /// `POST /supervisor/downtime/:downtimeId/resume` — close an active downtime.
  Future<DplApiResponse<DplDowntimeEvent>> resumeDowntime(int downtimeId) {
    return _send<DplDowntimeEvent>(
      () => _dio.post(DplPaths.supervisorDowntimeResume(downtimeId)),
      fallback: 'Failed to resume from downtime.',
      fromJson: (data) {
        if (data is Map) {
          return DplDowntimeEvent.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        throw const FormatException('Expected object response for resume.');
      },
    );
  }

  /// `GET /supervisor/plans/:planId/downtimes` — downtime history for a plan.
  Future<DplApiResponse<List<DplDowntimeEvent>>> listPlanDowntimes(int planId) {
    return _send<List<DplDowntimeEvent>>(
      () => _dio.get(DplPaths.supervisorPlanDowntimes(planId)),
      fallback: 'Failed to load downtimes.',
      fromJson: _listFrom<DplDowntimeEvent>(DplDowntimeEvent.fromJson),
    );
  }

  // ---------------------------------------------------------------------------
  // Item pauses — parallel to machine downtimes, scoped to one plan item.
  // ---------------------------------------------------------------------------

  /// `POST /supervisor/plans/:planId/items/:itemId/pause` — opens a
  /// pause on a single in-progress item. [reasonText] is required;
  /// [reasonId] optionally links to a downtime-reason master row.
  Future<DplApiResponse<DplItemPause>> pauseItem(
    int planId,
    int itemId, {
    required String reasonText,
    int? reasonId,
    DateTime? expectedResumeAt,
  }) {
    return _send<DplItemPause>(
      () => _dio.post(
        DplPaths.supervisorItemPause(planId, itemId),
        data: {
          'reason_text': reasonText,
          'reason_id': ?reasonId,
          if (expectedResumeAt != null)
            'expected_resume_at':
                expectedResumeAt.toUtc().toIso8601String(),
        },
      ),
      fallback: 'Failed to pause item.',
      fromJson: _oneFrom<DplItemPause>(DplItemPause.fromJson),
    );
  }

  /// `POST /supervisor/plans/:planId/items/:itemId/resume` — closes the
  /// current pause on an item. Returns the canonical duration and the
  /// item's running total of paused minutes.
  Future<DplApiResponse<DplItemResumeResult>> resumeItem(
    int planId,
    int itemId,
  ) {
    return _send<DplItemResumeResult>(
      () => _dio.post(DplPaths.supervisorItemResume(planId, itemId)),
      fallback: 'Failed to resume item.',
      fromJson: _oneFrom<DplItemResumeResult>(DplItemResumeResult.fromJson),
    );
  }

  /// `GET /supervisor/plans/:planId/pauses` — all pauses for a plan.
  Future<DplApiResponse<List<DplItemPause>>> getSupervisorPlanPauses(
    int planId,
  ) {
    return _send<List<DplItemPause>>(
      () => _dio.get(DplPaths.supervisorPlanPauses(planId)),
      fallback: 'Failed to load pauses.',
      fromJson: _listFrom<DplItemPause>(DplItemPause.fromJson),
    );
  }

  /// `GET /supervisor/plans/:planId/items/:itemId/pauses` — pauses for a
  /// single item.
  Future<DplApiResponse<List<DplItemPause>>> getSupervisorItemPauses(
    int planId,
    int itemId,
  ) {
    return _send<List<DplItemPause>>(
      () => _dio.get(DplPaths.supervisorItemPauses(planId, itemId)),
      fallback: 'Failed to load pauses.',
      fromJson: _listFrom<DplItemPause>(DplItemPause.fromJson),
    );
  }

  /// `GET /supervisor/shift/summary?date=` — end-of-shift roll-up.
  Future<DplApiResponse<DplShiftSummary>> shiftSummary(DateTime date) {
    return _send<DplShiftSummary>(
      () => _dio.get(
        DplPaths.supervisorShiftSummary,
        queryParameters: {'date': _ymd(date)},
      ),
      fallback: 'Failed to load shift summary.',
      fromJson: (data) {
        if (data is Map) {
          return DplShiftSummary.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        return DplShiftSummary.empty(date);
      },
    );
  }

  /// `POST /supervisor/shift/submit` — lock today's production.
  Future<DplApiResponse<DplShiftSubmitResult>> submitShift(
    DateTime date, {
    String? remarks,
  }) {
    return _send<DplShiftSubmitResult>(
      () => _dio.post(
        DplPaths.supervisorShiftSubmit,
        data: {
          'date': _ymd(date),
          if (remarks != null && remarks.trim().isNotEmpty)
            'remarks': remarks.trim(),
        },
      ),
      fallback: 'Failed to submit shift.',
      fromJson: (data) {
        if (data is Map) {
          return DplShiftSubmitResult.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        throw const FormatException('Expected object response for submit.');
      },
    );
  }

  /// `GET /supervisor/downtime-reasons` — reasons available to the
  /// supervisor (may include only active ones; backend-defined).
  Future<DplApiResponse<List<DplDowntimeReason>>>
      supervisorDowntimeReasons() {
    return _send<List<DplDowntimeReason>>(
      () => _dio.get(DplPaths.supervisorDowntimeReasons),
      fallback: 'Failed to load downtime reasons.',
      fromJson: _listFrom<DplDowntimeReason>(DplDowntimeReason.fromJson),
    );
  }

  // ---------------------------------------------------------------------------
  // 14) Trolley photo (gate before STOP)
  // ---------------------------------------------------------------------------

  /// `POST /supervisor/plans/:planId/items/:itemId/trolley-photo` —
  /// multipart upload of the photo a supervisor must capture before
  /// stopping a running item. Returns the persisted photo row; pass
  /// its `id` to [stopItem] within the server's freshness window
  /// (default 15 minutes).
  Future<DplApiResponse<DplTrolleyPhoto>> uploadTrolleyPhoto({
    required int planId,
    required int itemId,
    required Uint8List bytes,
    required String filename,
    String? remarks,
  }) async {
    try {
      final form = FormData.fromMap({
        'photo': MultipartFile.fromBytes(bytes, filename: filename),
        if (remarks != null && remarks.trim().isNotEmpty)
          'remarks': remarks.trim(),
      });
      return _send<DplTrolleyPhoto>(
        () => _dio.post(
          DplPaths.supervisorItemTrolleyPhoto(planId, itemId),
          data: form,
        ),
        fallback: 'Failed to upload trolley photo.',
        fromJson: (data) {
          if (data is Map) {
            return DplTrolleyPhoto.fromJson(Map<String, dynamic>.from(data));
          }
          throw const FormatException(
            'Expected object response for trolley photo.',
          );
        },
      );
    } catch (e) {
      return DplErrorMapper.fromObject<DplTrolleyPhoto>(
        e,
        fallback: 'Failed to upload trolley photo.',
      );
    }
  }

  /// `GET /supervisor/trolley-photos/:id/image` — raw image bytes. The
  /// supervisor who uploaded the photo (and managers) can read it.
  Future<DplApiResponse<Uint8List>> getSupervisorTrolleyPhotoBytes(
    int id,
  ) async {
    try {
      final response = await _dio.get<List<int>>(
        DplPaths.supervisorTrolleyPhotoImage(id),
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data == null) {
        return DplApiResponse.error('Empty trolley photo response.');
      }
      return DplApiResponse.ok(Uint8List.fromList(data));
    } on DioException catch (e) {
      return DplErrorMapper.fromDio<Uint8List>(
        e,
        fallback: 'Failed to load trolley photo.',
      );
    } catch (e) {
      return DplErrorMapper.fromObject<Uint8List>(
        e,
        fallback: 'Failed to load trolley photo.',
      );
    }
  }

  /// `GET /manager/trolley-photos` — paginated manager-side audit
  /// log of every trolley photo captured at STOP time.
  Future<DplApiResponse<DplPagedResult<DplTrolleyPhoto>>>
      listManagerTrolleyPhotos({
    int? planId,
    int? planItemId,
    int? supervisorId,
    int? machineId,
    DateTime? from,
    DateTime? to,
    int page = 1,
    int limit = 20,
  }) {
    return _send<DplPagedResult<DplTrolleyPhoto>>(
      () => _dio.get(
        DplPaths.managerTrolleyPhotos,
        queryParameters: _cleanQuery({
          'plan_id': ?planId,
          'plan_item_id': ?planItemId,
          'supervisor_id': ?supervisorId,
          'machine_id': ?machineId,
          if (from != null) 'from': _ymd(from),
          if (to != null) 'to': _ymd(to),
          'page': page,
          'limit': limit,
        }),
      ),
      fallback: 'Failed to load trolley photo audit.',
      fromJson: (data) {
        int parseInt(dynamic v, int fb) {
          if (v is int) return v;
          if (v is double) return v.toInt();
          return int.tryParse(v?.toString() ?? '') ?? fb;
        }

        List<DplTrolleyPhoto> parseList(List raw) => raw
            .whereType<Map>()
            .map((e) =>
                DplTrolleyPhoto.fromJson(Map<String, dynamic>.from(e)))
            .toList();

        if (data is List) {
          final items = parseList(data);
          return DplPagedResult<DplTrolleyPhoto>(
            items: items,
            page: page,
            limit: limit,
            total: items.length,
          );
        }
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          List<dynamic>? raw;
          for (final key in const [
            'photos',
            'trolley_photos',
            'trolleyPhotos',
            'items',
            'data',
            'rows',
            'results',
          ]) {
            final v = map[key];
            if (v is List) {
              raw = v;
              break;
            }
          }
          if (raw != null) {
            final items = parseList(raw);
            final nested = map['pagination'];
            final p =
                nested is Map ? Map<String, dynamic>.from(nested) : map;
            return DplPagedResult<DplTrolleyPhoto>(
              items: items,
              page: parseInt(p['page'], page),
              limit: parseInt(p['limit'], limit),
              total: parseInt(p['total'], items.length),
            );
          }
        }
        return DplPagedResult<DplTrolleyPhoto>.empty();
      },
    );
  }

  /// `GET /manager/active-downtimes` — every currently open downtime
  /// across all plans, sorted newest-first. Drives the manager-side
  /// red sticky banner.
  Future<DplApiResponse<List<ActiveDowntime>>> listManagerActiveDowntimes({
    int? machineId,
  }) {
    return _send<List<ActiveDowntime>>(
      () => _dio.get(
        DplPaths.managerActiveDowntimes,
        queryParameters: _cleanQuery({
          'machine_id': ?machineId,
        }),
      ),
      fallback: 'Failed to load active downtimes.',
      fromJson: (data) {
        List<dynamic>? raw;
        if (data is List) {
          raw = data;
        } else if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          for (final key in const [
            'downtimes',
            'active_downtimes',
            'activeDowntimes',
            'items',
            'data',
            'rows',
          ]) {
            final v = map[key];
            if (v is List) {
              raw = v;
              break;
            }
          }
        }
        if (raw == null) return const <ActiveDowntime>[];
        return raw
            .whereType<Map>()
            .map((e) => ActiveDowntime.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      },
    );
  }

  /// `POST /manager/downtime/:downtimeId/close` — manager-scoped
  /// recovery action that force-closes an orphaned active downtime
  /// (e.g. a supervisor logged off without resuming, leaving the red
  /// banner stuck). [reason] is optional context that gets persisted on
  /// the closed event. [organizationId] is sent in the body because the
  /// backend's audit-log writer can't derive it from the JWT here and
  /// otherwise 500s with `DplAuditLog.organization_id cannot be null`.
  /// Returns the now-closed event so callers can double-check
  /// `end_time` / `status` if they need to.
  Future<DplApiResponse<DplDowntimeEvent>> managerCloseDowntime(
    int downtimeId, {
    String? reason,
    int? organizationId,
  }) {
    return _send<DplDowntimeEvent>(
      () => _dio.post(
        DplPaths.managerDowntimeClose(downtimeId),
        data: {
          if (reason != null && reason.trim().isNotEmpty)
            'reason': reason.trim(),
          'organization_id': ?organizationId,
        },
      ),
      fallback: 'Failed to close downtime.',
      fromJson: (data) {
        if (data is Map) {
          return DplDowntimeEvent.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        throw const FormatException(
          'Expected object response for close downtime.',
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Production summary — aggregate of `total_actual_qty` per (machine,
  // part) bucket. Shared between Manager and the downstream Dispatch /
  // QA / PDI viewers; the backend gates access by JWT role.
  // ---------------------------------------------------------------------------

  /// `GET /manager/production-summary` — paginated, searchable,
  /// filterable rollup of every (machine, part) bucket the active
  /// organization has ever planned for.
  ///
  /// All filter / sort args are optional; passing none returns the
  /// first page of every bucket sorted by `last_produced_at desc`.
  Future<DplApiResponse<DplProductionSummaryPage>> listProductionSummary({
    String? plantCode,
    int? machineId,
    int? partId,
    String? q,
    DateTime? from,
    DateTime? to,
    bool? onlyProduced,
    String? sort,
    String? order,
    int? page,
    int? limit,
  }) {
    return _send<DplProductionSummaryPage>(
      () => _dio.get(
        DplPaths.productionSummary,
        queryParameters: _cleanQuery({
          if (plantCode != null && plantCode.isNotEmpty)
            'plant_code': plantCode,
          'machine_id': ?machineId,
          'part_id': ?partId,
          if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
          if (from != null) 'from': _ymd(from),
          if (to != null) 'to': _ymd(to),
          if (onlyProduced == true) 'only_produced': 'true',
          if (sort != null && sort.isNotEmpty) 'sort': sort,
          if (order != null && order.isNotEmpty) 'order': order,
          'page': ?page,
          'limit': ?limit,
        }),
      ),
      fallback: 'Failed to load production summary.',
      fromJson: (data) {
        if (data is Map) {
          return DplProductionSummaryPage.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        if (data is List) {
          // Bare-array shape — no pagination / totals envelope.
          final items = data
              .whereType<Map>()
              .map((e) => DplProductionSummary.fromJson(
                    Map<String, dynamic>.from(e),
                  ))
              .toList();
          return DplProductionSummaryPage(
            items: items,
            page: 1,
            limit: items.length,
            total: items.length,
            totalPages: items.isEmpty ? 0 : 1,
            totals: const DplProductionSummaryTotals(),
          );
        }
        return DplProductionSummaryPage.empty();
      },
    );
  }

  /// `GET /manager/production-summary/one?machine_id=&part_id=` —
  /// fetches a single bucket for a (machine, part) pair the user picked
  /// from a dropdown. Returns `null` when the backend responds 404.
  Future<DplApiResponse<DplProductionSummary?>> getProductionSummaryOne({
    required int machineId,
    required int partId,
  }) {
    return _send<DplProductionSummary?>(
      () => _dio.get(
        DplPaths.productionSummaryOne,
        queryParameters: _cleanQuery({
          'machine_id': machineId,
          'part_id': partId,
        }),
      ),
      fallback: 'Failed to load production summary entry.',
      fromJson: (data) {
        if (data is Map) {
          return DplProductionSummary.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        return null;
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Plants — hardcoded 3-plant mapping (Nexon EV / TML PV / MG Motors).
  // Backend serves a fixed array from a config file; promote to a DB
  // table later if admins ever need to edit the mapping.
  // ---------------------------------------------------------------------------

  /// `GET /plants` — returns the three plants with the machines each
  /// owns. Cached on the FE side because the list is effectively
  /// static for v1.
  Future<DplApiResponse<List<DplPlant>>> listPlants() {
    return _send<List<DplPlant>>(
      () => _dio.get(DplPaths.plants),
      fallback: 'Failed to load plants.',
      fromJson: (data) {
        if (data is List) {
          return data
              .whereType<Map>()
              .map((e) => DplPlant.fromJson(Map<String, dynamic>.from(e)))
              .toList(growable: false);
        }
        return const <DplPlant>[];
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Dispatch slips — Dispatch → QA → PDI three-step approval pipeline.
  // The slip carries an HMAC-signed QR payload on PDI approval that gate
  // staff can scan from the printed paper. Role gating is server-side.
  // ---------------------------------------------------------------------------

  /// `POST /dispatch/slips` — Dispatch creates a new slip request for
  /// [qty] units of [partId] off [machineId]. Backend enforces
  /// `qty <= total_actual − sum(non-rejected slips)` and returns
  /// `INSUFFICIENT_QTY` if violated.
  /// `POST /dispatch/slips` — multi-item slip creation.
  ///
  /// As of PR 3 the slip body carries `plant_code`, optional
  /// `vehicle_no`, and a non-empty `items[]` array of
  /// `(machine_id, part_id, qty)` triplets. Server validates that every
  /// item's machine belongs to the chosen plant, sums duplicate
  /// (machine, part) entries before the availability check, signs the
  /// QR payload at insert time, and returns the hydrated slip.
  ///
  /// Errors:
  ///   * 400 `INVALID_PLANT_CODE` — unknown plant
  ///   * 400 `INVALID_PLANT_MACHINE` — item's machine isn't in plant
  ///   * 400 `EMPTY_ITEMS` — items[] is empty
  ///   * 409 `INSUFFICIENT_QTY` — item.qty > bucket.available
  Future<DplApiResponse<DplDispatchSlip>> createDispatchSlip({
    required String plantCode,
    required List<DispatchSlipItemRequest> items,
    String? vehicleNo,
    String? notes,
  }) {
    return _send<DplDispatchSlip>(
      () => _dio.post(
        DplPaths.dispatchSlips,
        data: {
          'plant_code': plantCode,
          if (vehicleNo != null && vehicleNo.trim().isNotEmpty)
            'vehicle_no': vehicleNo.trim(),
          if (notes != null && notes.trim().isNotEmpty)
            'notes': notes.trim(),
          'items': items.map((i) => i.toJson()).toList(growable: false),
        },
      ),
      fallback: 'Failed to create dispatch slip.',
      fromJson: _oneDispatchSlip,
    );
  }

  /// `POST /dispatch/slips` — trip-driven path (migration 048).
  ///
  /// Backend detects this shape via the presence of `trip_id` +
  /// `trip_plan_ids[]` and routes through `createSlipFromTrip`:
  ///   * resolves plant + items from the trip plans
  ///   * flips the picked plans to `slip_created`
  ///   * recomputes the trip status (`partial` / `fulfilled`)
  /// All in a single transaction; rejects when plan ids belong to a
  /// different trip or are no longer `open`.
  Future<DplApiResponse<DplDispatchSlip>> createDispatchSlipFromTrip({
    required int tripId,
    required List<int> tripPlanIds,
    String? vehicleNo,
    String? notes,
  }) {
    return _send<DplDispatchSlip>(
      () => _dio.post(
        DplPaths.dispatchSlips,
        data: {
          'trip_id': tripId,
          'trip_plan_ids': tripPlanIds,
          if (vehicleNo != null && vehicleNo.trim().isNotEmpty)
            'vehicle_no': vehicleNo.trim(),
          if (notes != null && notes.trim().isNotEmpty)
            'notes': notes.trim(),
        },
      ),
      fallback: 'Failed to send slip for PDI.',
      fromJson: _oneDispatchSlip,
    );
  }

  /// `GET /dispatch/slips` — paginated list, server-side role-filtered.
  /// QA inbox: `?status=pending_qa`. PDI inbox: `?status=pending_pdi`.
  /// Dispatch defaults to their own slips across every status.
  ///
  /// [respectFilters] — when `true`, the backend's `totals` envelope
  /// honors `machine_id` / `part_id` / `q` / `from` / `to` (intersected
  /// with role scope) instead of returning the org-wide badge counts.
  /// Default `false` preserves the inbox-tab badge behavior. The
  /// rollup banner on the Plan Trip screen opts in.
  Future<DplApiResponse<DplDispatchSlipPage>> listDispatchSlips({
    String? status,
    int? machineId,
    int? partId,
    String? q,
    DateTime? from,
    DateTime? to,
    int? page,
    int? limit,
    bool respectFilters = false,
  }) {
    return _send<DplDispatchSlipPage>(
      () => _dio.get(
        DplPaths.dispatchSlips,
        queryParameters: _cleanQuery({
          if (status != null && status.isNotEmpty) 'status': status,
          'machine_id': ?machineId,
          'part_id': ?partId,
          if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
          if (from != null) 'from': _ymd(from),
          if (to != null) 'to': _ymd(to),
          'page': ?page,
          'limit': ?limit,
          if (respectFilters) 'respect_filters': 'true',
        }),
      ),
      fallback: 'Failed to load dispatch slips.',
      fromJson: (data) {
        if (data is Map) {
          return DplDispatchSlipPage.fromJson(Map<String, dynamic>.from(data));
        }
        if (data is List) {
          final items = data
              .whereType<Map>()
              .map((e) => DplDispatchSlip.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          return DplDispatchSlipPage(
            items: items,
            page: 1,
            limit: items.length,
            total: items.length,
            totalPages: items.isEmpty ? 0 : 1,
            totals: const DplDispatchSlipTotals(),
          );
        }
        return DplDispatchSlipPage.empty();
      },
    );
  }

  /// `GET /dispatch/slips/:id` — full slip, used by the printable detail
  /// screen so it can render the QR + signatures fresh.
  Future<DplApiResponse<DplDispatchSlip>> getDispatchSlip(int id) {
    return _send<DplDispatchSlip>(
      () => _dio.get(DplPaths.dispatchSlipById(id)),
      fallback: 'Failed to load dispatch slip.',
      fromJson: _oneDispatchSlip,
    );
  }

  /// `POST /dispatch/slips/:id/qa-approve` — QA signs off; status moves
  /// to `pending_pdi`. Server rejects with `INVALID_STATUS` if the slip
  /// isn't currently `pending_qa`.
  Future<DplApiResponse<DplDispatchSlip>> qaApproveDispatchSlip(
    int id, {
    String? remarks,
  }) {
    return _send<DplDispatchSlip>(
      () => _dio.post(
        DplPaths.dispatchSlipQaApprove(id),
        data: {
          if (remarks != null && remarks.trim().isNotEmpty)
            'remarks': remarks.trim(),
        },
      ),
      fallback: 'Failed to QA-approve slip.',
      fromJson: _oneDispatchSlip,
    );
  }

  Future<DplApiResponse<DplDispatchSlip>> qaRejectDispatchSlip(
    int id, {
    required String reason,
  }) {
    return _send<DplDispatchSlip>(
      () => _dio.post(
        DplPaths.dispatchSlipQaReject(id),
        data: {'reason': reason.trim()},
      ),
      fallback: 'Failed to reject slip.',
      fromJson: _oneDispatchSlip,
    );
  }

  /// `POST /dispatch/slips/:id/pdi-approve` — final gate; response carries
  /// the populated `qr_payload`. Backend will return `SAME_USER_FORBIDDEN`
  /// if the same user QA-approved this slip.
  Future<DplApiResponse<DplDispatchSlip>> pdiApproveDispatchSlip(
    int id, {
    String? remarks,
  }) {
    return _send<DplDispatchSlip>(
      () => _dio.post(
        DplPaths.dispatchSlipPdiApprove(id),
        data: {
          if (remarks != null && remarks.trim().isNotEmpty)
            'remarks': remarks.trim(),
        },
      ),
      fallback: 'Failed to PDI-approve slip.',
      fromJson: _oneDispatchSlip,
    );
  }

  Future<DplApiResponse<DplDispatchSlip>> pdiRejectDispatchSlip(
    int id, {
    required String reason,
  }) {
    return _send<DplDispatchSlip>(
      () => _dio.post(
        DplPaths.dispatchSlipPdiReject(id),
        data: {'reason': reason.trim()},
      ),
      fallback: 'Failed to reject slip.',
      fromJson: _oneDispatchSlip,
    );
  }

  /// `POST /dispatch/slips/:id/mark-dispatched` — Dispatch (or Manager)
  /// confirms the goods have physically left. Permanently decreases the
  /// available-for-dispatch qty on the parent (machine, part) bucket.
  Future<DplApiResponse<DplDispatchSlip>> markDispatchSlipDispatched(int id) {
    return _send<DplDispatchSlip>(
      () => _dio.post(DplPaths.dispatchSlipMarkDispatched(id)),
      fallback: 'Failed to mark slip dispatched.',
      fromJson: _oneDispatchSlip,
    );
  }

  /// `POST /dispatch/slips/:id/email` — multipart upload of the
  /// printed-slip PDF. Server emails it to the configured Dispatch
  /// recipient (dispatch.san@sprautotech.com), with Balasaheb + the
  /// Flutter developer CC'd by default. Pass [extraTo] / [extraCc] to
  /// append per-send recipients without losing the defaults.
  ///
  /// Result shapes:
  ///   * `{ sent: true,  message_id, to, cc }` — provider accepted
  ///   * `{ sent: false, skipped: true, reason }` — SMTP not configured
  ///     on this deploy. Slip is still persisted; only the email step
  ///     was no-op'd. UI should surface this as a warning, not an error.
  ///
  /// PDF payload cap is 5 MB; the server also validates the magic-byte
  /// header so corrupt or non-PDF uploads are rejected with 400.
  ///
  /// [slipIds] marks a batch (trip) send: the attached PDF carries every
  /// slip in the list, so the server should build the email details
  /// table from ALL of them rather than from the single path [id]. When
  /// omitted (or a single id) the server falls back to the path slip —
  /// preserving the old single-slip behavior. The path [id] should be
  /// the first/anchor slip and is expected to appear in [slipIds].
  Future<DplApiResponse<DplDispatchSlipEmailResult>> sendDispatchSlipEmail(
    int id, {
    required Uint8List pdfBytes,
    required String filename,
    List<String>? extraTo,
    List<String>? extraCc,
    String? subjectSuffix,
    List<int>? slipIds,
  }) async {
    try {
      final form = FormData.fromMap({
        'pdf': MultipartFile.fromBytes(
          pdfBytes,
          filename: filename,
          contentType: DioMediaType('application', 'pdf'),
        ),
        if (extraTo != null && extraTo.isNotEmpty)
          'extra_to': extraTo.join(','),
        if (extraCc != null && extraCc.isNotEmpty)
          'extra_cc': extraCc.join(','),
        if (subjectSuffix != null && subjectSuffix.trim().isNotEmpty)
          'subject_suffix': subjectSuffix.trim(),
        if (slipIds != null && slipIds.isNotEmpty)
          'slip_ids': slipIds.join(','),
      });
      return _send<DplDispatchSlipEmailResult>(
        () => _dio.post(DplPaths.dispatchSlipEmail(id), data: form),
        fallback: 'Failed to email the dispatch slip.',
        fromJson: (data) {
          if (data is Map) {
            return DplDispatchSlipEmailResult.fromJson(
              Map<String, dynamic>.from(data),
            );
          }
          throw const FormatException('Expected object response.');
        },
      );
    } catch (e) {
      return DplErrorMapper.fromObject<DplDispatchSlipEmailResult>(
        e,
        fallback: 'Failed to email the dispatch slip.',
      );
    }
  }

  /// `GET /dispatch/slips/verify?token=…` — public verifier consumed by
  /// gate staff scanning the printed QR. No Authorization header is
  /// required by the backend, but we send the JWT anyway when present;
  /// the route ignores it.
  Future<DplApiResponse<DplDispatchSlipVerification>> verifyDispatchSlip(
    String token,
  ) {
    return _send<DplDispatchSlipVerification>(
      () => _dio.get(
        DplPaths.dispatchSlipVerify,
        queryParameters: {'token': token},
      ),
      fallback: 'Failed to verify slip.',
      fromJson: (data) {
        if (data is Map) {
          return DplDispatchSlipVerification.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        return const DplDispatchSlipVerification(verified: false);
      },
    );
  }

  /// Shared fromJson for every single-slip endpoint. Tolerates both the
  /// envelope-stripped shape (`{ id: ... }`) and a `{ slip: { id: ... } }`
  /// wrapper.
  DplDispatchSlip _oneDispatchSlip(dynamic data) {
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      final inner = map['slip'];
      if (inner is Map) {
        return DplDispatchSlip.fromJson(Map<String, dynamic>.from(inner));
      }
      return DplDispatchSlip.fromJson(map);
    }
    throw const FormatException('Expected object response for dispatch slip.');
  }

  /// `GET /manager/trolley-photos/:id/image` — manager view of the
  /// raw image bytes.
  Future<DplApiResponse<Uint8List>> getManagerTrolleyPhotoBytes(
    int id,
  ) async {
    try {
      final response = await _dio.get<List<int>>(
        DplPaths.managerTrolleyPhotoImage(id),
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data == null) {
        return DplApiResponse.error('Empty trolley photo response.');
      }
      return DplApiResponse.ok(Uint8List.fromList(data));
    } on DioException catch (e) {
      return DplErrorMapper.fromDio<Uint8List>(
        e,
        fallback: 'Failed to load trolley photo.',
      );
    } catch (e) {
      return DplErrorMapper.fromObject<Uint8List>(
        e,
        fallback: 'Failed to load trolley photo.',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // List/one helpers
  // ---------------------------------------------------------------------------

  /// Converts the [data] payload of a single-object endpoint into [T].
  ///
  /// Many DPL endpoints wrap the object under a singular key (for example
  /// `{plan: {...}}`, `{item: {...}}`, `{machine: {...}}`). We unwrap the
  /// first matching key transparently so callers don't need to know.
  T Function(dynamic) _oneFrom<T>(T Function(Map<String, dynamic>) fromMap) {
    const wrapperKeys = <String>[
      'plan',
      'item',
      'machine',
      'part',
      'supervisor',
      'reason',
      'downtime_reason',
      'downtimeReason',
      'user',
      'record',
    ];

    return (data) {
      if (data is Map) {
        final map = Map<String, dynamic>.from(data);
        for (final key in wrapperKeys) {
          final inner = map[key];
          if (inner is Map) {
            return fromMap(Map<String, dynamic>.from(inner));
          }
        }
        return fromMap(map);
      }
      throw const FormatException('Expected object response.');
    };
  }

  List<T> Function(dynamic) _listFrom<T>(
    T Function(Map<String, dynamic>) fromMap,
  ) {
    // Common backend wrapping keys we accept transparently.
    const candidateKeys = <String>[
      'items',
      'results',
      'data',
      'rows',
      'records',
      'machines',
      'supervisors',
      'parts',
      'plans',
      'reasons',
      'downtime_reasons',
      'downtimeReasons',
      'users',
      'shifts',
      'manpower',
      'manpower_logs',
      'manpowerLogs',
      'downtimes',
      'alerts',
      'pauses',
      'verifications',
    ];

    return (data) {
      List<dynamic> list;
      if (data is List) {
        list = data;
      } else if (data is Map) {
        list = const <dynamic>[];
        for (final key in candidateKeys) {
          final v = data[key];
          if (v is List) {
            list = v;
            break;
          }
        }
      } else {
        list = const <dynamic>[];
      }

      return list
          .whereType<Map>()
          .map((e) => fromMap(Map<String, dynamic>.from(e)))
          .toList();
    };
  }

  // ---------------------------------------------------------------------------
  // Auto Dispatch Plan (migration 045) — JIT buffer-replenishment calculator.
  // 6 endpoints powering the new "Today's Dispatch Plan" feature. Existing
  // endpoints are read-only / never modified by this group of methods.
  // ---------------------------------------------------------------------------

  /// `GET /manager/buffer-norms?plant_code=...` — Manager only.
  ///
  /// Returns the per-plant per-part norm rows (`buffer_target`,
  /// `trolley_capacity`, `trips_per_day`) plus a `parts_without_norms`
  /// list so the admin screen can highlight what's still missing.
  Future<DplApiResponse<DplBufferNormsPage>> listBufferNorms({
    required String plantCode,
  }) {
    return _send<DplBufferNormsPage>(
      () => _dio.get(
        DplPaths.bufferNorms,
        queryParameters: {'plant_code': plantCode},
      ),
      fallback: 'Failed to load buffer norms.',
      fromJson: (data) {
        if (data is Map) {
          return DplBufferNormsPage.fromJson(Map<String, dynamic>.from(data));
        }
        throw const FormatException('Expected object response.');
      },
    );
  }

  /// `PUT /manager/buffer-norms` — Manager only. Bulk upsert.
  ///
  /// Sends every row the admin screen currently has — backend resolves
  /// inserts vs updates by the unique (organization, plant, part) key.
  Future<DplApiResponse<int>> upsertBufferNorms({
    required String plantCode,
    required List<DplBufferNormUpsertRequest> norms,
  }) {
    return _send<int>(
      () => _dio.put(
        DplPaths.bufferNorms,
        data: {
          'plant_code': plantCode,
          'norms': [for (final n in norms) n.toJson()],
        },
      ),
      fallback: 'Failed to save buffer norms.',
      fromJson: (data) {
        if (data is Map) {
          return parseIntOr(data['upserted_count'] ?? data['upsertedCount']);
        }
        throw const FormatException('Expected object response.');
      },
    );
  }

  /// `GET /manager/customer-snapshots?plant_code=...&date=...` —
  /// Manager + Dispatch.
  Future<DplApiResponse<DplCustomerSnapshotsPage>> listCustomerSnapshots({
    required String plantCode,
    required DateTime date,
  }) {
    final dateStr =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    return _send<DplCustomerSnapshotsPage>(
      () => _dio.get(
        DplPaths.customerSnapshots,
        queryParameters: {'plant_code': plantCode, 'date': dateStr},
      ),
      fallback: 'Failed to load customer snapshot.',
      fromJson: (data) {
        if (data is Map) {
          return DplCustomerSnapshotsPage.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        throw const FormatException('Expected object response.');
      },
    );
  }

  /// `POST /manager/customer-snapshots` — Manager + Dispatch.
  /// Bulk upsert. `date` is sent as ISO `YYYY-MM-DD`.
  Future<DplApiResponse<int>> upsertCustomerSnapshots({
    required String plantCode,
    required DateTime snapshotDate,
    required List<DplCustomerSnapshotUpsertRequest> entries,
  }) {
    final dateStr =
        '${snapshotDate.year.toString().padLeft(4, '0')}-'
        '${snapshotDate.month.toString().padLeft(2, '0')}-'
        '${snapshotDate.day.toString().padLeft(2, '0')}';
    return _send<int>(
      () => _dio.post(
        DplPaths.customerSnapshots,
        data: {
          'plant_code': plantCode,
          'snapshot_date': dateStr,
          'entries': [for (final e in entries) e.toJson()],
        },
      ),
      fallback: 'Failed to save customer snapshot.',
      fromJson: (data) {
        if (data is Map) {
          return parseIntOr(data['upserted_count'] ?? data['upsertedCount']);
        }
        throw const FormatException('Expected object response.');
      },
    );
  }

  /// `GET /manager/dispatch-plan/inputs?plant_code=...&date=...` —
  /// Manager + Dispatch. The single calculator-feeder endpoint.
  ///
  /// Field names map 1:1 to `DispatchCalcInput`'s named parameters,
  /// so the response rows go straight into `toCalcInput()` and feed
  /// `DplDispatchCalculator.calculateBatch(...)` without an adapter.
  Future<DplApiResponse<DplDispatchPlanInputsPage>> getDispatchPlanInputs({
    required String plantCode,
    required DateTime date,
  }) {
    final dateStr =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    return _send<DplDispatchPlanInputsPage>(
      () => _dio.get(
        DplPaths.dispatchPlanInputs,
        queryParameters: {'plant_code': plantCode, 'date': dateStr},
      ),
      fallback: 'Failed to load dispatch plan inputs.',
      fromJson: (data) {
        if (data is Map) {
          return DplDispatchPlanInputsPage.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        throw const FormatException('Expected object response.');
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Simple Dispatch Planning — 3 per-part master fields, edited at
  // different cadences. All three endpoints share the same response
  // shape so we use one parameterized method pair driven by the
  // `DplPartFieldKind` enum.
  //
  // dispatch = (stocking_norm + customer_today_plan) - customer_opening_stock
  // ---------------------------------------------------------------------------

  /// `GET /manager/{kind-path}` — Manager only. Lists the per-part
  /// values for [kind]. Pass `withNull=true` to include parts that
  /// don't yet have this field configured (default: only configured
  /// rows).
  Future<DplApiResponse<DplPartFieldPage>> listPartField(
    DplPartFieldKind kind, {
    bool withNull = false,
  }) {
    return _send<DplPartFieldPage>(
      () => _dio.get(
        _pathForPartField(kind),
        queryParameters: withNull ? {'with_null': 'true'} : null,
      ),
      fallback: 'Failed to load ${kind.label.toLowerCase()}.',
      fromJson: (data) {
        if (data is Map) {
          return DplPartFieldPage.fromJson(
            Map<String, dynamic>.from(data),
            kind,
          );
        }
        throw const FormatException('Expected object response.');
      },
    );
  }

  /// `PUT /manager/{kind-path}` — Manager only. Bulk upsert.
  /// Atomic — either all entries apply or none. Pass `value: null`
  /// to explicitly clear a row's value back to NULL.
  Future<DplApiResponse<DplPartFieldUpsertResult>> updatePartField(
    DplPartFieldKind kind,
    List<DplPartFieldUpsertRequest> entries,
  ) {
    return _send<DplPartFieldUpsertResult>(
      () => _dio.put(
        _pathForPartField(kind),
        data: {
          'entries': [for (final e in entries) e.toJson(kind)],
        },
      ),
      fallback: 'Failed to save ${kind.label.toLowerCase()}.',
      fromJson: (data) {
        if (data is Map) {
          return DplPartFieldUpsertResult.fromJson(
            Map<String, dynamic>.from(data),
            kind,
          );
        }
        throw const FormatException('Expected object response.');
      },
    );
  }

  static String _pathForPartField(DplPartFieldKind kind) {
    switch (kind) {
      case DplPartFieldKind.stockingNorm:
        return DplPaths.stockingNorms;
      case DplPartFieldKind.customerOpeningStock:
        return DplPaths.customerOpeningStocks;
      case DplPartFieldKind.customerTodayPlan:
        return DplPaths.customerTodaysPlans;
      case DplPartFieldKind.packagingQty:
        return DplPaths.packagingQtys;
      case DplPartFieldKind.gaOpeningStock:
        return DplPaths.gaOpeningStocks;
    }
  }

  // ---------------------------------------------------------------------------
  // Dispatch trips (migration 048) — manager submits trips, dispatchers
  // cut slips from them.
  // ---------------------------------------------------------------------------

  /// `POST /dispatch/trips` — Manager. Creates one trip with 1–6
  /// plans. Backend assigns `trip_number` per (plant, IST-date) and
  /// returns the full trip object with the new ids.
  Future<DplApiResponse<DplTrip>> createTrip(
    DplTripCreateRequest body,
  ) {
    return _send<DplTrip>(
      () => _dio.post(DplPaths.dispatchTrips, data: body.toJson()),
      fallback: 'Failed to submit trip.',
      fromJson: (data) {
        if (data is Map) {
          // The response wraps the trip under `trip` per the brief.
          final map = Map<String, dynamic>.from(data);
          final raw = map['trip'] is Map
              ? Map<String, dynamic>.from(map['trip'] as Map)
              : map;
          return DplTrip.fromJson(raw);
        }
        throw const FormatException('Expected object response.');
      },
    );
  }

  /// `GET /dispatch/trips/next-number?plant_code=<code>&date=<YYYY-MM-DD>`
  /// — preview the `trip_number` the backend will assign for the next
  /// trip on the given plant + IST business day. [date] defaults
  /// server-side to today when omitted; pass it explicitly when the
  /// manager is planning for a future day (mig. 052).
  ///
  /// No allocation, no lock — the actual POST may end up ±1 if another
  /// user submits in the same window. UI should treat this as
  /// advisory, not authoritative.
  Future<DplApiResponse<int>> peekNextTripNumber({
    required String plantCode,
    DateTime? date,
  }) {
    return _send<int>(
      () => _dio.get(
        DplPaths.dispatchTripsNextNumber,
        queryParameters: _cleanQuery({
          'plant_code': plantCode,
          if (date != null) 'date': _ymd(date),
        }),
      ),
      fallback: 'Failed to fetch next trip number.',
      fromJson: (data) {
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          final n = map['next_number'];
          if (n is int) return n;
          if (n is num) return n.toInt();
          if (n is String) {
            final parsed = int.tryParse(n.trim());
            if (parsed != null) return parsed;
          }
        }
        throw const FormatException('Expected { next_number: int }.');
      },
    );
  }

  /// `GET /dispatch/trips` — Manager, Dispatch, Admin, Supervisor.
  /// Filterable by status (comma-separated), plant_code, date.
  /// Defaults the status filter to `open,partial` so dashboards land
  /// on the actionable subset.
  ///
  /// [submittedBy] accepts either `'me'` (filter to the calling user)
  /// or a numeric user id as a string. Server returns 400
  /// VALIDATION_ERROR on any other value.
  Future<DplApiResponse<DplTripListResponse>> listTrips({
    List<String>? statuses,
    String? plantCode,
    DateTime? date,
    String? submittedBy,
    int limit = 50,
    int offset = 0,
  }) {
    return _send<DplTripListResponse>(
      () => _dio.get(
        DplPaths.dispatchTrips,
        queryParameters: _cleanQuery({
          'status': (statuses ?? const ['open', 'partial']).join(','),
          'plant_code': plantCode,
          'date': date == null ? null : _ymd(date),
          'submitted_by': submittedBy,
          'limit': limit,
          'offset': offset,
        }),
      ),
      fallback: 'Failed to load trips.',
      fromJson: (data) {
        if (data is Map) {
          return DplTripListResponse.fromJson(Map<String, dynamic>.from(data));
        }
        if (data is List) {
          // Tolerate a bare list shape just in case.
          return DplTripListResponse(
            trips: data
                .whereType<Map>()
                .map((t) => DplTrip.fromJson(Map<String, dynamic>.from(t)))
                .toList(growable: false),
            total: data.length,
            limit: data.length,
            offset: 0,
          );
        }
        throw const FormatException('Expected list response.');
      },
    );
  }

  /// `GET /dispatch/trips/:id` — full detail including plans.
  Future<DplApiResponse<DplTrip>> getTrip(int id) {
    return _send<DplTrip>(
      () => _dio.get(DplPaths.dispatchTripById(id)),
      fallback: 'Failed to load trip.',
      fromJson: (data) {
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          final raw = map['trip'] is Map
              ? Map<String, dynamic>.from(map['trip'] as Map)
              : map;
          return DplTrip.fromJson(raw);
        }
        throw const FormatException('Expected object response.');
      },
    );
  }

  /// `POST /dispatch/trips/:id/cancel` — manager (own) or admin /
  /// supervisor (any). `reason` is required by the backend.
  Future<DplApiResponse<DplTrip>> cancelTrip(
    int id, {
    required String reason,
  }) {
    return _send<DplTrip>(
      () => _dio.post(
        DplPaths.dispatchTripCancel(id),
        data: {'reason': reason},
      ),
      fallback: 'Failed to cancel trip.',
      fromJson: (data) {
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          final raw = map['trip'] is Map
              ? Map<String, dynamic>.from(map['trip'] as Map)
              : map;
          return DplTrip.fromJson(raw);
        }
        throw const FormatException('Expected object response.');
      },
    );
  }

  /// `PATCH /dispatch/trips/:tripId/plans/:planId` — Dispatch role.
  /// Decrease-only qty edit. Backend rejects with 409 if the plan is
  /// no longer `open` or 422 if `qty` is greater than the current
  /// value. [varianceNote] is required when reducing.
  Future<DplApiResponse<DplTripPlan>> patchTripPlanQty(
    int tripId,
    int planId, {
    required int qty,
    String? varianceNote,
  }) {
    return _send<DplTripPlan>(
      () => _dio.patch(
        DplPaths.dispatchTripPlan(tripId, planId),
        data: {
          'qty': qty,
          if (varianceNote != null && varianceNote.isNotEmpty)
            'variance_note': varianceNote,
        },
      ),
      fallback: 'Failed to update qty.',
      fromJson: (data) {
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          final raw = map['plan'] is Map
              ? Map<String, dynamic>.from(map['plan'] as Map)
              : map;
          return DplTripPlan.fromJson(raw);
        }
        throw const FormatException('Expected object response.');
      },
    );
  }

  /// `GET /dispatch/reports/plan-vs-actual` — Dispatch + Manager.
  ///
  /// Returns the per-(plant, machine, part) breakdown of planned vs actual
  /// dispatch for Today / MTD / Till-date. Plan = Σ trip plan qty (by trip
  /// date); Actual = Σ dispatched-slip item qty (by dispatch date). The FE
  /// filters / sorts / re-aggregates client-side, so no query params are
  /// required — the endpoint returns the whole org breakdown.
  Future<DplApiResponse<DplDispatchPlanActualReport>>
      getDispatchPlanVsActual() {
    return _send<DplDispatchPlanActualReport>(
      () => _dio.get(DplPaths.dispatchPlanVsActual),
      fallback: 'Failed to load the dispatch plan-vs-actual report.',
      fromJson: (data) {
        if (data is Map) {
          return DplDispatchPlanActualReport.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        if (data is List) {
          return DplDispatchPlanActualReport.fromJson({'breakdown': data});
        }
        return const DplDispatchPlanActualReport();
      },
    );
  }

  /// `POST /dispatch/trips/:id/send-for-pdi` — Dispatch DEO role.
  ///
  /// Stamps a PER-SLIP invoice on each slip in [slipInvoices], records
  /// the DEO actor + timestamp (+ optional [remarks]), and transitions
  /// those `pending_deo` slips to `pending_pdi` in one transaction.
  /// Slips not listed stay `pending_deo` for a later batch. Returns the
  /// updated slips so the caller can re-render + email this batch.
  ///
  /// Errors to expect:
  ///   * `VALIDATION_ERROR` (400) — empty list, duplicate `slip_id`, a
  ///     `slip_id` not on the trip, or a blank/invalid `invoice_no`.
  ///   * `INVALID_STATUS` (409) — a listed slip is no longer pending_deo
  ///     (another DEO moved it).
  ///   * `NO_PENDING_SLIPS` (409) — the trip has no pending_deo slips.
  Future<DplApiResponse<List<DplDispatchSlip>>> sendTripForPdi(
    int tripId, {
    required List<DeoSlipInvoice> slipInvoices,
    String? remarks,
  }) {
    return _send<List<DplDispatchSlip>>(
      () => _dio.post(
        DplPaths.dispatchTripSendForPdi(tripId),
        data: {
          'slip_invoices': [for (final si in slipInvoices) si.toJson()],
          if (remarks != null && remarks.trim().isNotEmpty)
            'remarks': remarks.trim(),
        },
      ),
      fallback: 'Failed to send the trip for PDI.',
      fromJson: (data) {
        // Tolerate a few response shapes: a bare list, `{slips:[…]}`,
        // `{items:[…]}`, `{data:[…]}`, or a single `{slip:{…}}`.
        List? rawList;
        if (data is List) {
          rawList = data;
        } else if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final candidate = m['slips'] ?? m['items'] ?? m['data'];
          if (candidate is List) {
            rawList = candidate;
          } else if (m['slip'] is Map) {
            rawList = [m['slip']];
          }
        }
        if (rawList == null) return const <DplDispatchSlip>[];
        return rawList
            .whereType<Map>()
            .map((e) =>
                DplDispatchSlip.fromJson(Map<String, dynamic>.from(e)))
            .toList(growable: false);
      },
    );
  }

  /// `POST /dispatch/slips/bulk` — Manager + Dispatch.
  ///
  /// Atomic — every slip in [slips] is committed in a single DB
  /// transaction. Either all succeed or none persist (server-side).
  /// Used by the "Create Dispatch Slips" CTA on the Today's Plan
  /// screen after the calculator output is reviewed.
  ///
  /// Errors:
  ///   * 400 `EMPTY_SLIPS` — `slips[]` is empty
  ///   * 400 `INVALID_PLANT_CODE` — unknown plant
  ///   * 400 `INVALID_PLANT_MACHINE` — an item's machine_id isn't in the plant
  ///   * 409 `INSUFFICIENT_QTY` — at least one slip's qty > bucket.available
  Future<DplApiResponse<DispatchSlipBulkResult>> createDispatchSlipsBulk({
    required String plantCode,
    required List<DispatchSlipBulkItem> slips,
  }) {
    return _send<DispatchSlipBulkResult>(
      () => _dio.post(
        DplPaths.dispatchSlipsBulk,
        data: {
          'plant_code': plantCode,
          'slips': [for (final s in slips) s.toJson()],
        },
      ),
      fallback: 'Failed to create dispatch slips.',
      fromJson: (data) {
        if (data is Map) {
          return DispatchSlipBulkResult.fromJson(
            Map<String, dynamic>.from(data),
          );
        }
        throw const FormatException('Expected object response.');
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Dispatch trips — consolidated slip + gate/dock journey (gate cutover).
  //
  // These endpoints back the post-DEO leg of a trip: a single consolidated
  // slip payload that gates + drivers scan, and the sequential journey
  // events (gate-out, tata-gate-in, tata-dock-in/out, tata-gate-out) that
  // move the trip through security, the Tata plant, and back out. Driver
  // assignment (`PATCH .../driver`) is manager-side; `driver/my-trips` is
  // the driver-role inbox for whatever's currently on their plate.
  // ---------------------------------------------------------------------------

  /// `GET /dispatch/trips/:id/consolidated-slip` — one aggregated payload
  /// that rolls every slip on a trip into the single-page printable /
  /// emailable view scanned at the security gate. Any role that can see
  /// the trip can read this.
  Future<DplApiResponse<DplConsolidatedSlip>> getConsolidatedSlip(int tripId) {
    return _send<DplConsolidatedSlip>(
      () => _dio.get(DplPaths.tripConsolidatedSlip(tripId)),
      fallback: 'Failed to load consolidated slip.',
      fromJson: (data) {
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          final inner = map['consolidated_slip'] ?? map['slip'];
          if (inner is Map) {
            return DplConsolidatedSlip.fromJson(
              Map<String, dynamic>.from(inner),
            );
          }
          return DplConsolidatedSlip.fromJson(map);
        }
        throw const FormatException(
          'Expected object response for consolidated slip.',
        );
      },
    );
  }

  /// `GET /dispatch/trips/:id/journey` — ordered feed of every journey
  /// event (gate-out → tata-gate-in → tata-dock-in/out → tata-gate-out)
  /// recorded against the trip. Server sorts oldest-first so callers can
  /// render a timeline without post-processing.
  Future<DplApiResponse<List<DplTripJourneyEvent>>> listTripJourney(
    int tripId,
  ) {
    return _send<List<DplTripJourneyEvent>>(
      () => _dio.get(DplPaths.tripJourney(tripId)),
      fallback: 'Failed to load trip journey.',
      fromJson: (data) {
        List<dynamic>? raw;
        if (data is List) {
          raw = data;
        } else if (data is Map) {
          for (final key in const [
            'events',
            'journey',
            'items',
            'data',
            'rows',
          ]) {
            final v = data[key];
            if (v is List) {
              raw = v;
              break;
            }
          }
        }
        if (raw == null) return const <DplTripJourneyEvent>[];
        return raw
            .whereType<Map>()
            .map((e) =>
                DplTripJourneyEvent.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      },
    );
  }

  /// `POST /dispatch/trips/:id/locations` — Driver. Flushes a batch of
  /// GPS fixes captured while the trip was in flight.
  ///
  /// Batched on purpose: the plant→TATA run has dead zones, so the
  /// tracker queues locally and hands over everything it accumulated in
  /// one request when signal returns. The server is expected to be
  /// idempotent on `(trip_id, recorded_at)` — the queue only clears
  /// after a 2xx, so a response lost in transit replays the same rows.
  ///
  /// Resolves to the number of fixes the server accepted.
  Future<DplApiResponse<int>> postTripLocations(
    int tripId,
    List<DplTripLocation> fixes,
  ) {
    return _send<int>(
      () => _dio.post(
        DplPaths.tripLocations(tripId),
        data: {'locations': [for (final f in fixes) f.toJson()]},
      ),
      fallback: 'Failed to upload location.',
      fromJson: (data) {
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          final n = parseIntOrNull(map['accepted'] ?? map['count']);
          if (n != null) return n;
        }
        if (data is List) return data.length;
        // Accepted, but the server didn't say how many — assume all of
        // them so the caller clears its queue instead of replaying.
        return fixes.length;
      },
    );
  }

  /// `GET /dispatch/trips/:id/locations` — Dispatch / manager. Breadcrumb
  /// trail for the track map, oldest-first.
  ///
  /// [since] asks for fixes recorded strictly after that instant so the
  /// map can poll incrementally instead of refetching the whole trail.
  Future<DplApiResponse<DplTripTrack>> getTripTrack(
    int tripId, {
    DateTime? since,
    int? limit,
  }) {
    return _send<DplTripTrack>(
      () => _dio.get(
        DplPaths.tripLocations(tripId),
        queryParameters: _cleanQuery({
          'since': since?.toUtc().toIso8601String(),
          'limit': limit,
        }),
      ),
      fallback: 'Failed to load trip track.',
      fromJson: (data) {
        if (data is List) {
          return DplTripTrack.fromPointList(data, tripId: tripId);
        }
        if (data is Map) {
          return DplTripTrack.fromJson(
            Map<String, dynamic>.from(data),
            tripId: tripId,
          );
        }
        // No body / null data is a legitimate "nothing recorded yet"
        // rather than a parse failure — render the empty state.
        return DplTripTrack(tripId: tripId);
      },
    );
  }

  /// `PATCH /dispatch/trips/:id/driver` — Manager. Assigns / reassigns
  /// the app user who'll drive this trip. Backend enforces that
  /// [driverUserId] resolves to a `dpl_driver` role.
  Future<DplApiResponse<DplTrip>> assignTripDriver(
    int tripId, {
    required int driverUserId,
  }) {
    return _send<DplTrip>(
      () => _dio.patch(
        DplPaths.tripDriver(tripId),
        data: {'driver_user_id': driverUserId},
      ),
      fallback: 'Failed to assign driver.',
      fromJson: (data) {
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          final raw = map['trip'] is Map
              ? Map<String, dynamic>.from(map['trip'] as Map)
              : map;
          return DplTrip.fromJson(raw);
        }
        throw const FormatException('Expected object response.');
      },
    );
  }

  /// `POST /dispatch/trips/:id/gate-out` — role: `dpl_security`.
  ///
  /// Security scans the consolidated-slip QR ([qrToken]) at the gate to
  /// release the truck. Returns the persisted journey event so the caller
  /// can update the timeline in place.
  Future<DplApiResponse<DplTripJourneyEvent>> gateOutTrip(
    int tripId, {
    required String qrToken,
  }) {
    return _send<DplTripJourneyEvent>(
      () => _dio.post(
        DplPaths.tripGateOut(tripId),
        data: {'qr_token': qrToken},
      ),
      fallback: 'Failed to gate-out trip.',
      fromJson: _oneJourneyEvent,
    );
  }

  /// `POST /dispatch/trips/:id/gate-in` — role: `dpl_security`.
  ///
  /// Return scan at the origin plant — the truck came back from TATA
  /// and the guard scans the same trip QR one more time. BE enforces
  /// that `tata_gate_out` is on record; this is the terminal event.
  Future<DplApiResponse<DplTripJourneyEvent>> gateInTrip(
    int tripId, {
    required String qrToken,
  }) {
    return _send<DplTripJourneyEvent>(
      () => _dio.post(
        DplPaths.tripGateIn(tripId),
        data: {'qr_token': qrToken},
      ),
      fallback: 'Failed to record gate-in (return).',
      fromJson: _oneJourneyEvent,
    );
  }

  /// `POST /dispatch/trips/:id/tata-gate-in` — role: `dpl_driver`.
  ///
  /// Driver arrives at the Tata plant gate and records the LECI details.
  /// Two paths:
  ///   * **Scan** — [leciBarcode] + [leciTruckNo] parsed from the scanned
  ///     barcode ([leciNo] / [leciRfid] optional). Sent as JSON.
  ///   * **Photo fallback** — when the barcode won't scan, the driver
  ///     snaps the LECI paper and types the truck no. Pass
  ///     [leciPhotoBytes] (+ [leciPhotoFilename]) with an empty
  ///     [leciBarcode]; the request switches to multipart so the image
  ///     rides along on the same gate-in call and the backend stores it.
  Future<DplApiResponse<DplTripJourneyEvent>> tataGateInTrip(
    int tripId, {
    required String leciBarcode,
    // leci_truck_no is optional (softened 2026-07-25). When empty the
    // backend records tata_gate_in with verified=false and skips the
    // plate cross-check.
    String? leciTruckNo,
    String? leciNo,
    String? leciRfid,
    Uint8List? leciPhotoBytes,
    String leciPhotoFilename = 'leci.jpg',
  }) {
    final hasPhoto = leciPhotoBytes != null && leciPhotoBytes.isNotEmpty;
    final truckNo = (leciTruckNo ?? '').trim();

    final fields = <String, dynamic>{
      'leci_barcode': leciBarcode,
      if (truckNo.isNotEmpty) 'leci_truck_no': truckNo,
      if (leciNo != null && leciNo.trim().isNotEmpty) 'leci_no': leciNo.trim(),
      if (leciRfid != null && leciRfid.trim().isNotEmpty)
        'leci_rfid': leciRfid.trim(),
    };

    return _send<DplTripJourneyEvent>(
      () => _dio.post(
        DplPaths.tripTataGateIn(tripId),
        data: hasPhoto
            ? FormData.fromMap({
                ...fields,
                'leci_photo': MultipartFile.fromBytes(
                  leciPhotoBytes,
                  filename: leciPhotoFilename,
                  // The backend's image upload filter only accepts
                  // image/jpeg|png|webp; without an explicit content-type
                  // Dio sends application/octet-stream and the part is
                  // rejected. Derive it from the file extension.
                  contentType: _leciPhotoMediaType(leciPhotoFilename),
                ),
              })
            : fields,
      ),
      fallback: 'Failed to record Tata gate-in.',
      fromJson: _oneJourneyEvent,
    );
  }

  /// Maps a LECI-photo filename to the image media type the backend
  /// accepts. Defaults to JPEG (the camera-capture case).
  DioMediaType _leciPhotoMediaType(String filename) {
    final ext = filename.toLowerCase().split('.').last;
    switch (ext) {
      case 'png':
        return DioMediaType('image', 'png');
      case 'webp':
        return DioMediaType('image', 'webp');
      case 'jpg':
      case 'jpeg':
      default:
        return DioMediaType('image', 'jpeg');
    }
  }

  /// `POST /dispatch/trips/:id/tata-dock-in` — role: `dpl_qre`.
  ///
  /// QRE scans the consolidated-slip QR ([qrToken]) at the dock to
  /// receive the truck.
  Future<DplApiResponse<DplTripJourneyEvent>> tataDockInTrip(
    int tripId, {
    required String qrToken,
  }) {
    return _send<DplTripJourneyEvent>(
      () => _dio.post(
        DplPaths.tripTataDockIn(tripId),
        data: {'qr_token': qrToken},
      ),
      fallback: 'Failed to record Tata dock-in.',
      fromJson: _oneJourneyEvent,
    );
  }

  /// `POST /dispatch/trips/:id/tata-dock-out` — role: `dpl_qre`.
  ///
  /// Unload complete; QRE records how many empty trolleys are being
  /// returned in [emptyTrolleyCount], optionally with [remarks].
  Future<DplApiResponse<DplTripJourneyEvent>> tataDockOutTrip(
    int tripId, {
    required int emptyTrolleyCount,
    String? remarks,
  }) {
    return _send<DplTripJourneyEvent>(
      () => _dio.post(
        DplPaths.tripTataDockOut(tripId),
        data: {
          'empty_trolley_count': emptyTrolleyCount,
          if (remarks != null && remarks.trim().isNotEmpty)
            'remarks': remarks.trim(),
        },
      ),
      fallback: 'Failed to record Tata dock-out.',
      fromJson: _oneJourneyEvent,
    );
  }

  /// `POST /dispatch/trips/:id/tata-gate-out` — role: `dpl_driver`.
  ///
  /// Driver leaves the Tata plant; closes the on-plant leg of the trip.
  Future<DplApiResponse<DplTripJourneyEvent>> tataGateOutTrip(int tripId) {
    return _send<DplTripJourneyEvent>(
      () => _dio.post(DplPaths.tripTataGateOut(tripId)),
      fallback: 'Failed to record Tata gate-out.',
      fromJson: _oneJourneyEvent,
    );
  }

  /// `GET /driver/my-trips` — role: `dpl_driver`. Trips currently
  /// assigned to the calling driver. Backend scopes the list to the
  /// driver's actionable subset (not yet fully gated out).
  Future<DplApiResponse<List<DplTrip>>> getMyDriverTrips() {
    return _send<List<DplTrip>>(
      () => _dio.get(DplPaths.driverMyTrips),
      fallback: 'Failed to load my trips.',
      fromJson: (data) {
        List<dynamic>? raw;
        if (data is List) {
          raw = data;
        } else if (data is Map) {
          for (final key in const [
            'trips',
            'items',
            'data',
            'rows',
            'results',
          ]) {
            final v = data[key];
            if (v is List) {
              raw = v;
              break;
            }
          }
        }
        if (raw == null) return const <DplTrip>[];
        return raw
            .whereType<Map>()
            .map((e) => DplTrip.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      },
    );
  }

  /// Shared fromJson for every single-journey-event endpoint. Tolerates
  /// both the envelope-stripped shape and an `{ event: { ... } }` wrapper.
  DplTripJourneyEvent _oneJourneyEvent(dynamic data) {
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      for (final key in const ['event', 'journey_event', 'journeyEvent']) {
        final inner = map[key];
        if (inner is Map) {
          return DplTripJourneyEvent.fromJson(
            Map<String, dynamic>.from(inner),
          );
        }
      }
      return DplTripJourneyEvent.fromJson(map);
    }
    throw const FormatException(
      'Expected object response for journey event.',
    );
  }

  /// `GET /dispatch/drivers` — roles: dispatch / deo / manager. Returns
  /// every active `dpl_driver` in the caller's org for the Assign-Driver
  /// bottom sheet.
  Future<DplApiResponse<List<DplDriverUser>>> listDrivers() {
    return _send<List<DplDriverUser>>(
      () => _dio.get(DplPaths.dispatchDrivers),
      fallback: 'Failed to load drivers.',
      fromJson: (data) => _parseListEnvelope(data)
          .map(DplDriverUser.fromJson)
          .toList(),
    );
  }

  /// `GET /security/pending-gate-out` — role: `dpl_security`.
  /// Trips fully dispatched, waiting for the guard's gate-out scan.
  Future<DplApiResponse<List<DplTrip>>> getSecurityPendingGateOut() {
    return _send<List<DplTrip>>(
      () => _dio.get(DplPaths.securityPendingGateOut),
      fallback: 'Failed to load pending gate-out list.',
      fromJson: (data) => _parseListEnvelope(data)
          .map(DplTrip.fromJson)
          .toList(),
    );
  }

  /// `GET /qre/pending-dock-in` — role: `dpl_qre`.
  /// Trips that reached the TATA gate but haven't docked in yet.
  Future<DplApiResponse<List<DplTrip>>> getQrePendingDockIn() {
    return _send<List<DplTrip>>(
      () => _dio.get(DplPaths.qrePendingDockIn),
      fallback: 'Failed to load pending dock-in list.',
      fromJson: (data) => _parseListEnvelope(data)
          .map(DplTrip.fromJson)
          .toList(),
    );
  }

  /// Shared list-envelope parser — accepts either a bare List or an
  /// object wrapping the list under one of the standard keys.
  List<Map<String, dynamic>> _parseListEnvelope(dynamic data) {
    List<dynamic>? raw;
    if (data is List) {
      raw = data;
    } else if (data is Map) {
      for (final key in const ['trips', 'items', 'data', 'rows', 'drivers', 'results']) {
        final v = data[key];
        if (v is List) {
          raw = v;
          break;
        }
      }
    }
    if (raw == null) return const <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // QA finished-goods stickers (backend migration 144)
  //
  // Scan the Grupo Antolin raw-material label -> resolve its substrate part no
  // to the customer part reference(s) it maps to -> QA picks one -> the SERVER
  // issues serials, capped at the plan item's recorded actual_qty.
  //
  // Serials are never minted client-side. Two handhelds doing that produce
  // colliding labels on physical parts, and the quantity cap is only real if
  // it is a row count taken under a lock on the server.
  //
  // Note QA's plan browsing reuses getPlans / getPlan / getDashboard above —
  // `dpl_qa` was added to those endpoints' read-only guard rather than given a
  // parallel controller, so the QA view cannot drift from the Manager view.
  // ---------------------------------------------------------------------------

  /// `GET /qa/current-shift` — which shift is running right now.
  ///
  /// Returns `null` inside [DplShift] when the clock falls in a gap between
  /// configured shifts. Callers must handle that rather than assume a shift
  /// is always live.
  Future<DplApiResponse<DplShift?>> getQaCurrentShift() {
    return _send<DplShift?>(
      () => _dio.get(DplPaths.qaCurrentShift),
      fallback: 'Failed to read the current shift.',
      fromJson: (data) {
        if (data is Map) {
          final raw = data['shift'];
          if (raw is Map) {
            return DplShift.fromJson(Map<String, dynamic>.from(raw));
          }
        }
        return null;
      },
    );
  }

  /// `POST /qa/scan/resolve` — scanned payload -> candidate customer parts.
  ///
  /// Pass [rawPayload] from the scanner, or [substratePartNo] when the
  /// operator keyed the number printed under a damaged symbol.
  ///
  /// A 404 carries code `SUBSTRATE_NOT_FOUND`; its `data.candidates` lists what
  /// the decoder actually read, which is what the UI shows instead of a dead
  /// end. `_send` surfaces that as `DplApiResponse.error` with the code, so
  /// callers branch on `res.code == 'SUBSTRATE_NOT_FOUND'`.
  Future<DplApiResponse<DplScanResolution>> resolveQaScan({
    String? rawPayload,
    String? substratePartNo,
  }) {
    return _send<DplScanResolution>(
      () => _dio.post(
        DplPaths.qaScanResolve,
        data: _cleanQuery({
          'raw_payload': (rawPayload ?? '').trim().isEmpty ? null : rawPayload,
          'substrate_part_no':
              (substratePartNo ?? '').trim().isEmpty ? null : substratePartNo,
        }),
      ),
      fallback: 'Failed to resolve the scanned label.',
      // Hand-rolled rather than _oneFrom: the response carries `parts` next to
      // sibling metadata (`candidates`, `matched_on`) that the generic
      // unwrappers would discard.
      fromJson: (data) => DplScanResolution.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// `GET /qa/plan-items/:id/stickers/summary` — actual vs printed vs left.
  Future<DplApiResponse<DplStickerSummary>> getQaStickerSummary(int planItemId) {
    return _send<DplStickerSummary>(
      () => _dio.get(DplPaths.qaStickerSummary(planItemId)),
      fallback: 'Failed to read the sticker count for this item.',
      fromJson: (data) => DplStickerSummary.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// `POST /qa/plan-items/:id/stickers` — issue [count] serials.
  ///
  /// On success the response carries the issued stickers; render the PDF from
  /// those, never from locally generated values.
  ///
  /// A 409 with code `STICKER_LIMIT_EXCEEDED` is the quantity cap firing and
  /// its message names how many are actually left. `SUBSTRATE_PART_MISMATCH`
  /// means the picked part is not mapped to the scanned substrate;
  /// `NO_ACTUAL_QTY` means the supervisor has not recorded production yet.
  Future<DplApiResponse<DplStickerIssueResult>> issueQaStickers({
    required int planItemId,
    required int partId,
    required int count,
    String? substratePartNo,
    String? rawPayload,
  }) {
    return _send<DplStickerIssueResult>(
      () => _dio.post(
        DplPaths.qaIssueStickers(planItemId),
        data: _cleanQuery({
          'part_id': partId,
          'count': count,
          'substrate_part_no':
              (substratePartNo ?? '').trim().isEmpty ? null : substratePartNo,
          'raw_payload': (rawPayload ?? '').trim().isEmpty ? null : rawPayload,
        }),
      ),
      fallback: 'Failed to issue stickers.',
      fromJson: (data) => DplStickerIssueResult.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// `POST /qa/stickers/direct` — labels with no production plan behind them.
  ///
  /// Maxion SSR v3.0 §5.2. There is deliberately NO actual-quantity cap on
  /// this path: the operator says how many, and that many exist. The server
  /// gates it on `labels.print_batch` for the caller's organization and
  /// answers `DIRECT_PRINT_NOT_ALLOWED` when the plant has not been granted
  /// it, so a plant on the default keeps the plan-item cap unchanged.
  Future<DplApiResponse<DplStickerIssueResult>> issueDirectQaStickers({
    required int partId,
    required int count,
    int? machineId,
  }) {
    return _send<DplStickerIssueResult>(
      () => _dio.post(
        DplPaths.qaStickersDirect,
        data: _cleanQuery({
          'part_id': partId,
          'machine_id': machineId,
          'count': count,
        }),
      ),
      fallback: 'Failed to print the labels.',
      fromJson: (data) => DplStickerIssueResult.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// `GET /qa/machines` — every active machine, for the direct-print picker.
  ///
  /// Distinct from the plan-driven Production tab, which shows only machines
  /// that have a plan for the chosen date and shift. Direct printing has no
  /// plan, so it lists them all.
  Future<DplApiResponse<List<DplMachine>>> getQaMachines() {
    return _send<List<DplMachine>>(
      () => _dio.get(DplPaths.qaMachines),
      fallback: 'Failed to load machines.',
      fromJson: (data) => _parseListEnvelope(
        data is Map ? data['machines'] ?? data : data,
      ).map(DplMachine.fromJson).toList(),
    );
  }

  /// `GET /qa/parts?q=` — searchable part list for the direct-print picker.
  Future<DplApiResponse<List<DplPart>>> getQaParts({String? q}) {
    return _send<List<DplPart>>(
      () => _dio.get(
        DplPaths.qaParts,
        queryParameters: _cleanQuery({
          'q': (q ?? '').trim().isEmpty ? null : q!.trim(),
        }),
      ),
      fallback: 'Failed to load parts.',
      fromJson: (data) => _parseListEnvelope(
        data is Map ? data['parts'] ?? data : data,
      ).map(DplPart.fromJson).toList(),
    );
  }

  // ---------------------------------------------------------------------------
  // Pallet build and close (backend migration 151, Maxion SSR Module 4)
  //
  // The operator opens a pallet, scans printed wheel labels onto it, then
  // closes it. The SYSTEM decides full (P), half (H) or merged (PM) and issues
  // the number — SSR §4, "The app decides P, H or PM by itself".
  // ---------------------------------------------------------------------------

  /// The pallet this operator currently has open, or null.
  ///
  /// Called on screen load so an open pallet survives a battery change, an app
  /// restart or a shift handover, which SSR Module 4 asks for by name.
  Future<DplApiResponse<DplPallet?>> getOpenPallet() {
    return _send<DplPallet?>(
      () => _dio.get(DplPaths.qaPalletOpen),
      fallback: 'Failed to read the open pallet.',
      fromJson: (data) {
        final raw = data is Map ? data['pallet'] : null;
        if (raw is! Map) return null;
        return DplPallet.fromJson(Map<String, dynamic>.from(raw));
      },
    );
  }

  /// Start a pallet. [fromHalfPalletId] brings a stored half pallet back and
  /// fills it up; the result closes as PM.
  Future<DplApiResponse<DplPallet>> openPallet({
    required int partId,
    int? machineId,
    int? fromHalfPalletId,
  }) {
    return _send<DplPallet>(
      () => _dio.post(
        DplPaths.qaPallets,
        data: _cleanQuery({
          'part_id': partId,
          'machine_id': machineId,
          'from_half_pallet_id': fromHalfPalletId,
        }),
      ),
      fallback: 'Failed to open the pallet.',
      fromJson: _palletFromEnvelope,
    );
  }

  /// Put one wheel on the pallet.
  ///
  /// [code] is either the full QR payload or a serial keyed in by hand when
  /// the label is scuffed. Refusals are precise — `WRONG_PART`,
  /// `ALREADY_ON_ANOTHER_PALLET`, `PALLET_FULL` — because the operator is
  /// holding the wheel and needs to know what to do with it.
  Future<DplApiResponse<DplPallet>> scanWheelOntoPallet({
    required int palletId,
    required String code,
  }) {
    return _send<DplPallet>(
      () => _dio.post(DplPaths.qaPalletScan(palletId), data: {'code': code}),
      fallback: 'Failed to scan that wheel.',
      fromJson: _palletFromEnvelope,
    );
  }

  /// Take one wheel back off after a mis-scan.
  Future<DplApiResponse<DplPallet>> undoPalletScan({
    required int palletId,
    required String serial,
  }) {
    return _send<DplPallet>(
      () => _dio.delete(DplPaths.qaPalletUndoScan(palletId, serial)),
      fallback: 'Failed to remove that wheel.',
      fromJson: _palletFromEnvelope,
    );
  }

  /// Close it. The type and number come back from the server.
  Future<DplApiResponse<DplPallet>> closePallet({
    required int palletId,
    String? reason,
  }) {
    return _send<DplPallet>(
      () => _dio.post(
        DplPaths.qaPalletClose(palletId),
        data: _cleanQuery({
          'reason': (reason ?? '').trim().isEmpty ? null : reason!.trim(),
        }),
      ),
      fallback: 'Failed to close the pallet.',
      fromJson: _palletFromEnvelope,
    );
  }

  /// Abandon an open pallet.
  ///
  /// Releases every wheel back to unpacked and issues no number. This is
  /// the only way out of a pallet opened for the wrong item, since only
  /// one can be open per operator at a time.
  Future<DplApiResponse<void>> discardPallet(int palletId) {
    return _send<void>(
      () => _dio.delete(DplPaths.qaPalletById(palletId)),
      fallback: 'Failed to discard the pallet.',
    );
  }

  /// Stored half pallets, oldest first — SSR Module 5's order of suggestion.
  Future<DplApiResponse<List<DplPallet>>> getHalfPallets({int? partId}) {
    return _send<List<DplPallet>>(
      () => _dio.get(
        DplPaths.qaPalletsHalf,
        queryParameters: _cleanQuery({'part_id': partId}),
      ),
      fallback: 'Failed to load stored half pallets.',
      fromJson: (data) => _parseListEnvelope(
        data is Map ? data['pallets'] ?? data : data,
      ).map(DplPallet.fromJson).toList(),
    );
  }

  /// Turn a scanned pallet label into the pallet, where it is, and where it
  /// should go — Maxion SSR Module 6.
  ///
  /// Accepts the QR payload (`MWP|PM26000012`) or the number printed under it,
  /// because §5 prints the payload in plain text "so a damaged code can still
  /// be keyed in". A WHEEL label is refused by name rather than resolving to
  /// nothing — scanning a wheel here is a real mistake worth saying out loud.
  Future<DplApiResponse<DplPalletResolution>> resolvePalletForPutaway(
    String code,
  ) {
    return _send<DplPalletResolution>(
      () => _dio.get(
        DplPaths.warehousePalletResolve,
        queryParameters: {'code': code.trim()},
      ),
      fallback: 'Could not read that pallet label.',
      fromJson: (data) => DplPalletResolution.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// Record which rack a closed pallet is standing on.
  ///
  /// Capacity, the row lock and releasing a previous placement all happen
  /// server-side; a refusal here names the reason (`LOCATION_FULL`,
  /// `PALLET_NOT_CLOSED`, `ALREADY_ASSIGNED`) and should be shown verbatim.
  Future<DplApiResponse<DplPallet>> putPalletAway({
    required int palletId,
    required int locationId,
    String? remarks,
  }) {
    return _send<DplPallet>(
      () => _dio.post(
        DplPaths.warehousePalletPutaway(palletId),
        data: {
          'location_id': locationId,
          if (remarks != null && remarks.trim().isNotEmpty)
            'remarks': remarks.trim(),
        },
      ),
      fallback: 'Failed to record the location.',
      fromJson: _palletFromEnvelope,
    );
  }

  /// The pallet register — every pallet built, filtered and paginated.
  ///
  /// Returns the page AND the unfiltered-by-page total, because "showing 50 of
  /// 2,310" is the difference between a list the storeman trusts and one they
  /// assume is everything.
  Future<DplApiResponse<DplPalletPage>> listPallets(DplPalletFilter filter) {
    return _send<DplPalletPage>(
      () => _dio.get(
        DplPaths.qaPallets,
        queryParameters: _cleanQuery(filter.toQuery()),
      ),
      fallback: 'Failed to load the pallet register.',
      fromJson: (data) => DplPalletPage.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// Everything the 100 x 75 mm master pallet label prints.
  ///
  /// Refuses with `PALLET_NOT_CLOSED` while the pallet is still open — an
  /// open pallet has no number yet, and a label without a number is a label
  /// nobody can scan back.
  Future<DplApiResponse<DplPalletSticker>> getPalletLabel(int palletId) {
    return _send<DplPalletSticker>(
      () => _dio.get(DplPaths.qaPalletLabel(palletId)),
      fallback: 'Failed to load the pallet label.',
      fromJson: (data) => DplPalletSticker.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SPD conversion (Maxion SSR §8, Module 12)
  // ---------------------------------------------------------------------------

  /// Which item a scanned WHEEL label belongs to.
  ///
  /// Read-only: it creates nothing, so an operator who scans and then changes
  /// their mind leaves no orphan wheel behind.
  Future<DplApiResponse<DplWheelResolution>> resolveWheel(String code) {
    return _send<DplWheelResolution>(
      () => _dio.get(
        DplPaths.qaWheelResolve,
        queryParameters: {'code': code.trim()},
      ),
      fallback: 'Could not read that wheel label.',
      fromJson: (data) => DplWheelResolution.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// The wheels physically on a pallet, for the SPD picker.
  ///
  /// A separate call from the pallet itself because the pallet label
  /// deliberately never carries this list (open point C-04) — but choosing
  /// which wheels leave is impossible without seeing them.
  Future<DplApiResponse<DplPalletWheels>> getPalletWheels(int palletId) {
    return _send<DplPalletWheels>(
      () => _dio.get(DplPaths.qaPalletWheels(palletId)),
      fallback: 'Failed to load the wheels on this pallet.',
      fromJson: (data) => DplPalletWheels.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// Turn the named wheels into individual SPD packs.
  ///
  /// One pack per wheel, each with its own number and `MWS|` label. Whatever
  /// is left stays on the pallet, which becomes a half pallet and is
  /// relabelled — the response says which labels to print.
  Future<DplApiResponse<DplSpdResult>> convertToSpd({
    required int palletId,
    required List<int> stickerIds,
  }) {
    return _send<DplSpdResult>(
      () => _dio.post(
        DplPaths.qaPalletSpd(palletId),
        data: {'sticker_ids': stickerIds},
      ),
      fallback: 'Failed to convert those wheels.',
      fromJson: (data) => DplSpdResult.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// The SPD pack register.
  Future<DplApiResponse<DplSpdPage>> listSpdPacks({
    String? search,
    int? partId,
    String? status,
    int limit = 50,
    int offset = 0,
  }) {
    return _send<DplSpdPage>(
      () => _dio.get(
        DplPaths.qaSpdPacks,
        queryParameters: _cleanQuery({
          'search': (search ?? '').trim().isEmpty ? null : search!.trim(),
          'part_id': partId,
          'status': (status ?? '').isEmpty ? null : status,
          'limit': limit,
          'offset': offset,
        }),
      ),
      fallback: 'Failed to load SPD packs.',
      fromJson: (data) => DplSpdPage.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// Move named wheels between two pallets — the drag-and-drop merge.
  ///
  /// [moves] says where each moved wheel ENDS UP, so wheels can go both ways
  /// in one operation and there is no "which is the target" to get wrong. Send
  /// only the wheels that actually changed side; the server refuses an
  /// instruction where nothing moved.
  Future<DplApiResponse<DplRedistributeResult>> redistributeWheels({
    required int palletAId,
    required int palletBId,
    required Map<int, int> moves,
  }) {
    return _send<DplRedistributeResult>(
      () => _dio.post(
        DplPaths.qaPalletsRedistribute,
        data: {
          'pallet_ids': [palletAId, palletBId],
          'moves': [
            for (final e in moves.entries)
              {'sticker_id': e.key, 'to_pallet_id': e.value},
          ],
        },
      ),
      fallback: 'Failed to move those wheels.',
      fromJson: (data) => DplRedistributeResult.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// Fill [targetPalletId] from [sourcePalletId], stopping at the target's
  /// standard quantity — SSR Module 5.
  ///
  /// Two half pallets that add up to more than one pallet-worth become a FULL
  /// pallet and a smaller half pallet, not one over-full pallet. The response's
  /// `reprint` names which labels are now stale.
  Future<DplApiResponse<DplMergeResult>> mergePallets({
    required int targetPalletId,
    required int sourcePalletId,
  }) {
    return _send<DplMergeResult>(
      () => _dio.post(
        DplPaths.qaPalletsMerge,
        data: {
          'target_pallet_id': targetPalletId,
          'source_pallet_id': sourcePalletId,
        },
      ),
      fallback: 'Failed to merge the pallets.',
      fromJson: (data) => DplMergeResult.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  // --- The wheel trolley (backend migration 157) ---
  //
  // On the WAREHOUSE prefix, not /qa. Parking is a pack-point job and merging
  // a warehouse one, and which role does each differs by plant — the QA router
  // is role-locked before any permission is read, so an endpoint there could
  // never be granted to a storeman however the administrator sets the grid.

  /// The carts still in use, oldest first.
  Future<DplApiResponse<List<DplWheelTrolley>>> getTrolleys({
    bool includeRetired = false,
  }) {
    return _send<List<DplWheelTrolley>>(
      () => _dio.get(
        DplPaths.warehouseTrolleys,
        queryParameters: _cleanQuery({
          'include_retired': includeRetired ? 'true' : null,
        }),
      ),
      fallback: 'Failed to load the trolleys.',
      fromJson: (data) => _parseListEnvelope(
        data is Map ? data['trolleys'] ?? data : data,
      ).map(DplWheelTrolley.fromJson).toList(),
    );
  }

  Future<DplApiResponse<DplWheelTrolley>> createTrolley({String name = ''}) {
    return _send<DplWheelTrolley>(
      () => _dio.post(
        DplPaths.warehouseTrolleys,
        data: _cleanQuery({'name': name.trim().isEmpty ? null : name.trim()}),
      ),
      fallback: 'Failed to create the trolley.',
      fromJson: (data) => DplWheelTrolley.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// Park one wheel on a cart.
  ///
  /// [trolleyId] may be null: a plant with exactly one active cart never has
  /// to say which, and a plant with none gets its first created rather than
  /// being blocked on master data nobody told them to enter.
  ///
  /// [partId] is needed only for an OLD label nobody has scanned before —
  /// there is no pallet to take the item from and nothing to guess with, and
  /// a wrong item makes every merge suggestion for two items wrong.
  Future<DplApiResponse<DplTrolleyParkResult>> parkWheelOnTrolley({
    int? trolleyId,
    required String code,
    int? partId,
  }) {
    return _send<DplTrolleyParkResult>(
      () => _dio.post(
        DplPaths.warehouseTrolleyPark,
        data: _cleanQuery({
          'trolley_id': trolleyId,
          'code': code,
          'part_id': partId,
        }),
      ),
      fallback: 'Failed to park that wheel.',
      fromJson: (data) => DplTrolleyParkResult.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// Take one wheel back off. The operator parked the wrong one.
  Future<DplApiResponse<DplWheelTrolley>> unparkWheelFromTrolley({
    required int trolleyId,
    required String code,
  }) {
    return _send<DplWheelTrolley>(
      () => _dio.post(
        DplPaths.warehouseTrolleyUnpark,
        data: {'trolley_id': trolleyId, 'code': code},
      ),
      fallback: 'Failed to take that wheel off.',
      fromJson: _trolleyFromEnvelope,
    );
  }

  Future<DplApiResponse<DplTrolleyContents>> getTrolleyWheels(
    int trolleyId, {
    int? partId,
  }) {
    return _send<DplTrolleyContents>(
      () => _dio.get(
        DplPaths.warehouseTrolleyWheels(trolleyId),
        queryParameters: _cleanQuery({'part_id': partId}),
      ),
      fallback: 'Failed to load what is on the trolley.',
      fromJson: (data) => DplTrolleyContents.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// What this cart should fill, and with how many.
  ///
  /// A SUGGESTION. It takes no lock and writes nothing, so leaving the screen
  /// open cannot stop the floor, and the merge re-derives every fact under a
  /// real lock — a stale plan produces an honest refusal, never a wrong write.
  Future<DplApiResponse<DplTrolleyPlan>> getTrolleyPlan(int trolleyId) {
    return _send<DplTrolleyPlan>(
      () => _dio.get(DplPaths.warehouseTrolleyPlan(trolleyId)),
      fallback: 'Failed to work out what this trolley can fill.',
      fromJson: (data) => DplTrolleyPlan.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// Move named wheels off a cart onto a closed pallet.
  ///
  /// All-or-nothing on the server: an operator who scanned twelve wheels and
  /// had six land cannot tell which six without reading an audit log.
  Future<DplApiResponse<DplTrolleyMergeResult>> mergeTrolleyIntoPallet({
    required int palletId,
    required int trolleyId,
    required List<int> stickerIds,
  }) {
    return _send<DplTrolleyMergeResult>(
      () => _dio.post(
        DplPaths.warehouseTrolleyMerge,
        data: {
          'pallet_id': palletId,
          'trolley_id': trolleyId,
          'sticker_ids': stickerIds,
        },
      ),
      fallback: 'Failed to move those wheels onto the pallet.',
      fromJson: (data) => DplTrolleyMergeResult.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// Release everything on a cart back to unpacked.
  Future<DplApiResponse<DplWheelTrolley>> emptyTrolley(int trolleyId) {
    return _send<DplWheelTrolley>(
      () => _dio.post(DplPaths.warehouseTrolleyEmpty(trolleyId)),
      fallback: 'Failed to empty the trolley.',
      fromJson: _trolleyFromEnvelope,
    );
  }

  /// Park, unpark and empty all answer `{ trolley: {...} }`; create answers
  /// the trolley directly. Tolerating both here keeps three call sites from
  /// each repeating the same guess.
  DplWheelTrolley _trolleyFromEnvelope(dynamic data) {
    if (data is Map) {
      final nested = data['trolley'];
      if (nested is Map) {
        return DplWheelTrolley.fromJson(Map<String, dynamic>.from(nested));
      }
      return DplWheelTrolley.fromJson(Map<String, dynamic>.from(data));
    }
    return const DplWheelTrolley();
  }

  /// Combine stored half pallets of the same item, with no new production.
  Future<DplApiResponse<DplPallet>> combineHalfPallets(List<int> palletIds) {
    return _send<DplPallet>(
      () => _dio.post(
        DplPaths.qaPalletsCombine,
        data: {'pallet_ids': palletIds},
      ),
      fallback: 'Failed to combine the pallets.',
      fromJson: _palletFromEnvelope,
    );
  }

  /// Scan and undo answer `{ pallet: {...} }` nested under a result; open,
  /// close and combine answer `{ pallet: {...} }` directly. Tolerating both
  /// here keeps five call sites from each repeating the same guess.
  DplPallet _palletFromEnvelope(dynamic data) {
    if (data is Map) {
      final nested = data['pallet'];
      if (nested is Map) return DplPallet.fromJson(Map<String, dynamic>.from(nested));
      return DplPallet.fromJson(Map<String, dynamic>.from(data));
    }
    return const DplPallet();
  }

  /// `POST /qa/stickers/void` — retire spoiled labels.
  ///
  /// Frees the quantity so a replacement can be printed; the serials
  /// themselves are never reused.
  Future<DplApiResponse<int>> voidQaStickers({
    required List<int> stickerIds,
    String? reason,
  }) {
    return _send<int>(
      () => _dio.post(
        DplPaths.qaStickersVoid,
        data: _cleanQuery({
          'sticker_ids': stickerIds,
          'reason': (reason ?? '').trim().isEmpty ? null : reason,
        }),
      ),
      fallback: 'Failed to void the stickers.',
      fromJson: (data) =>
          data is Map ? parseIntOr(data['voided']) : 0,
    );
  }

  /// `GET /qa/stickers` — traceability / reprint lookup.
  Future<DplApiResponse<List<DplPartSticker>>> getQaStickers({
    int? planItemId,
    String? batchId,
    String? serialNo,
    int page = 1,
    int limit = 50,
  }) {
    return _send<List<DplPartSticker>>(
      () => _dio.get(
        DplPaths.qaStickers,
        queryParameters: _cleanQuery({
          'plan_item_id': planItemId,
          'batch_id': (batchId ?? '').trim().isEmpty ? null : batchId,
          'serial_no': (serialNo ?? '').trim().isEmpty ? null : serialNo,
          'page': page,
          'limit': limit,
        }),
      ),
      fallback: 'Failed to load the sticker log.',
      fromJson: (data) => _parseListEnvelope(
        data is Map ? data['stickers'] ?? data : data,
      ).map(DplPartSticker.fromJson).toList(),
    );
  }

  // ---------------------------------------------------------------------------
  // Storage locations (backend migration 146)
  //
  // Master is manager-maintained; the assignment is QA's. Capacity is enforced
  // server-side under a row lock on the location, so the `free_qty` these
  // methods return is for display and for keeping the picker honest — never
  // for deciding whether an assignment is allowed.
  // ---------------------------------------------------------------------------

  /// Location master, newest search first. Used by both the manager's master
  /// screen and QA's picker; QA never passes [includeInactive].
  Future<DplApiResponse<List<DplLocation>>> getLocations({
    String? q,
    int page = 1,
    int limit = 50,
    bool includeInactive = false,
    bool asManager = false,
    // Reads the SAME master through the warehouse router instead of the QA
    // one. Needed because a putaway operator may hold `pallet.putaway` without
    // being dpl_qa, and the QA router would refuse them on role before the
    // permission was ever consulted.
    bool asWarehouse = false,
  }) {
    return _send<List<DplLocation>>(
      () => _dio.get(
        asManager
            ? DplPaths.managerLocations
            : asWarehouse
                ? DplPaths.warehouseLocations
                : DplPaths.qaLocations,
        queryParameters: _cleanQuery({
          'q': (q ?? '').trim().isEmpty ? null : q!.trim(),
          'page': page,
          'limit': limit,
          // `_cleanQuery` strips nulls but not `false`, so only send it when
          // it is actually true — the backend treats the string 'true'.
          if (includeInactive) 'include_inactive': 'true',
        }),
      ),
      fallback: 'Failed to load storage locations.',
      fromJson: (data) => _parseListEnvelope(
        data is Map ? data['locations'] ?? data : data,
      ).map(DplLocation.fromJson).toList(),
    );
  }

  Future<DplApiResponse<DplLocation>> createLocation(DplLocation location) {
    return _send<DplLocation>(
      () => _dio.post(DplPaths.managerLocations, data: location.toJsonForWrite()),
      fallback: 'Failed to create the location.',
      fromJson: (data) => DplLocation.fromJson(
        data is Map && data['location'] is Map
            ? Map<String, dynamic>.from(data['location'] as Map)
            : Map<String, dynamic>.from(data as Map),
      ),
    );
  }

  Future<DplApiResponse<DplLocation>> updateLocation(
    int id,
    DplLocation location,
  ) {
    return _send<DplLocation>(
      () => _dio.put(
        DplPaths.managerLocationById(id),
        data: location.toJsonForWrite(),
      ),
      fallback: 'Failed to update the location.',
      fromJson: (data) => DplLocation.fromJson(
        data is Map && data['location'] is Map
            ? Map<String, dynamic>.from(data['location'] as Map)
            : Map<String, dynamic>.from(data as Map),
      ),
    );
  }

  /// Soft delete. Refused with `LOCATION_NOT_EMPTY` while stock sits on it.
  Future<DplApiResponse<void>> deleteLocation(int id) {
    return _send<void>(
      () => _dio.delete(DplPaths.managerLocationById(id)),
      fallback: 'Failed to remove the location.',
    );
  }

  /// Where a plan item's output is stored, or `null` when nowhere.
  Future<DplApiResponse<DplLocationAssignment?>> getPlanItemLocation(
    int planItemId,
  ) {
    return _send<DplLocationAssignment?>(
      () => _dio.get(DplPaths.qaPlanItemLocation(planItemId)),
      fallback: 'Failed to read the storage location.',
      fromJson: (data) {
        if (data is Map) {
          final raw = data['assignment'];
          if (raw is Map) {
            return DplLocationAssignment.fromJson(
              Map<String, dynamic>.from(raw),
            );
          }
        }
        return null;
      },
    );
  }

  /// Store a plan item's produced batch at [locationId].
  ///
  /// [qty] omitted means "everything this item produced". Expect 409s with
  /// `LOCATION_FULL` (message names the remaining room), `LABELS_INCOMPLETE`,
  /// `QTY_EXCEEDS_PRODUCED` or `ALREADY_ASSIGNED`.
  Future<DplApiResponse<DplLocationAssignment>> assignPlanItemLocation({
    required int planItemId,
    required int locationId,
    int? qty,
    String? remarks,
  }) {
    return _send<DplLocationAssignment>(
      () => _dio.post(
        DplPaths.qaPlanItemLocation(planItemId),
        data: _cleanQuery({
          'location_id': locationId,
          'qty': qty,
          'remarks': (remarks ?? '').trim().isEmpty ? null : remarks!.trim(),
        }),
      ),
      fallback: 'Failed to assign the location.',
      fromJson: (data) => DplLocationAssignment.fromJson(
        data is Map && data['assignment'] is Map
            ? Map<String, dynamic>.from(data['assignment'] as Map)
            : Map<String, dynamic>.from(data as Map),
      ),
    );
  }

  /// `GET /dispatch/trips/label-availability`
  ///
  /// Returns `{partId: DplLabelStock}`. All four figures travel, not just the
  /// allowance, so the screen can distinguish "nothing printed" from "printed
  /// but every piece is already on another trip" — a zero allowance means
  /// something different in each case.
  ///
  /// A part ABSENT from the response has nothing printed and nothing planned,
  /// which is a hard zero rather than unknown.
  ///
  /// Advisory only: `POST /dispatch/trips` re-checks under an advisory lock,
  /// because two managers planning the same part at once would otherwise both
  /// read this number and both pass.
  Future<DplApiResponse<Map<int, DplLabelStock>>> getLabelAvailability({
    List<int>? partIds,
  }) {
    return _send<Map<int, DplLabelStock>>(
      () => _dio.get(
        DplPaths.dispatchTripsLabelAvailability,
        queryParameters: _cleanQuery({
          'part_ids': (partIds == null || partIds.isEmpty)
              ? null
              : partIds.join(','),
        }),
      ),
      fallback: 'Failed to load labelled stock.',
      fromJson: (data) {
        final rows = _parseListEnvelope(
          data is Map ? data['parts'] ?? data : data,
        );
        return {
          for (final r in rows)
            parseIntOr(r['part_id'] ?? r['partId']): DplLabelStock.fromJson(r),
        };
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Scanning printed labels onto a trip (backend migration 147)
  //
  // The dispatcher scans every printed label before a trip can be sent to the
  // DEO. The client disables its Send button on this progress, but the server
  // re-derives the same figure when the slip is cut — a client cannot be the
  // authority on whether pieces are physically on a trolley.
  // ---------------------------------------------------------------------------

  /// `GET /dispatch/trips/:id/label-scans` — per-plan scan progress.
  Future<DplApiResponse<DplTripScanProgress>> getTripLabelScans(int tripId) {
    return _send<DplTripScanProgress>(
      () => _dio.get(DplPaths.tripLabelScans(tripId)),
      fallback: 'Failed to load scan progress.',
      fromJson: (data) => DplTripScanProgress.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// `POST /dispatch/trips/:id/label-scans` — scan one label onto the trip.
  ///
  /// [code] takes the full QR payload or a bare serial keyed in from a damaged
  /// label. Returns the refreshed progress so the caller never needs a second
  /// round trip to re-evaluate its Send gate.
  ///
  /// Expect 409s: `ALREADY_SCANNED_HERE` (harmless double-tap),
  /// `ALREADY_ON_ANOTHER_TRIP`, `PART_NOT_ON_TRIP`, `PLAN_ALREADY_FULL`,
  /// `STICKER_VOIDED`; and 404 `STICKER_NOT_FOUND`.
  Future<DplApiResponse<DplTripScanProgress>> scanLabelToTrip({
    required int tripId,
    required String code,
  }) {
    return _send<DplTripScanProgress>(
      () => _dio.post(
        DplPaths.tripLabelScans(tripId),
        data: {'code': code},
      ),
      fallback: 'Failed to scan that label.',
      fromJson: (data) {
        final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
        final progress = map['progress'];
        return DplTripScanProgress.fromJson(
          progress is Map ? Map<String, dynamic>.from(progress) : map,
        );
      },
    );
  }

  /// `DELETE /dispatch/trips/:id/label-scans/:serial` — undo a mis-scan.
  Future<DplApiResponse<DplTripScanProgress>> undoTripLabelScan({
    required int tripId,
    required String serial,
  }) {
    return _send<DplTripScanProgress>(
      () => _dio.delete(
        DplPaths.tripLabelScanUndo(tripId, Uri.encodeComponent(serial)),
      ),
      fallback: 'Failed to undo that scan.',
      fromJson: (data) {
        final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
        final progress = map['progress'];
        return DplTripScanProgress.fromJson(
          progress is Map ? Map<String, dynamic>.from(progress) : map,
        );
      },
    );
  }

  /// `GET /dispatch/trips/:id/plans/:planId/master-sticker`
  ///
  /// Everything the aggregate label prints, built from the pieces actually
  /// scanned. 409 `NOTHING_SCANNED` when the plan has no scans yet.
  Future<DplApiResponse<DplMasterSticker>> getMasterSticker({
    required int tripId,
    required int planId,
  }) {
    return _send<DplMasterSticker>(
      () => _dio.get(DplPaths.tripMasterSticker(tripId, planId)),
      fallback: 'Failed to build the master sticker.',
      fromJson: (data) => DplMasterSticker.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// Take the batch back off the rack.
  Future<DplApiResponse<void>> releasePlanItemLocation(
    int planItemId, {
    String? remarks,
  }) {
    return _send<void>(
      () => _dio.delete(
        DplPaths.qaPlanItemLocation(planItemId),
        data: _cleanQuery({
          'remarks': (remarks ?? '').trim().isEmpty ? null : remarks!.trim(),
        }),
      ),
      fallback: 'Failed to release the location.',
    );
  }

  // ---------------------------------------------------------------------------
  // Administration (backend migration 148)
  //
  // Users, organizations and the role/permission grid. Every endpoint here is
  // permission-guarded server-side; the client's own permission checks decide
  // what to SHOW, never what to allow.
  //
  // An administrator works across organizations, so `organizationId` is an
  // optional FILTER on the list rather than an implicit scope. Omit it and
  // every tenant's users come back.
  // ---------------------------------------------------------------------------

  /// The role list and the grouped permission catalogue.
  ///
  /// Served by the backend rather than hard-coded here so the grid can never
  /// render a permission this build of the API does not enforce, nor miss one
  /// it does.
  Future<DplApiResponse<DplPermissionMatrix>> getAdminCatalogue() {
    return _send<DplPermissionMatrix>(
      () => _dio.get(DplPaths.adminCatalogue),
      fallback: 'Failed to load the permission catalogue.',
      fromJson: (data) => DplPermissionMatrix.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  Future<DplApiResponse<DplManagedUserPage>> getAdminUsers({
    int? organizationId,
    String? q,
    String? role,
    String status = 'all',
    int page = 1,
    int limit = 50,
  }) {
    return _send<DplManagedUserPage>(
      () => _dio.get(
        DplPaths.adminUsers,
        queryParameters: _cleanQuery({
          'organization_id': organizationId,
          'q': (q ?? '').trim().isEmpty ? null : q!.trim(),
          'role': (role ?? '').trim().isEmpty ? null : role,
          'status': status,
          'page': page,
          'limit': limit,
        }),
      ),
      fallback: 'Failed to load users.',
      fromJson: (data) => DplManagedUserPage.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// Creates an account. [password] is the temporary one the administrator
  /// hands over; the account is flagged so it stops working once the person
  /// sets their own.
  Future<DplApiResponse<DplManagedUser>> createAdminUser(
    DplManagedUser user, {
    required String password,
  }) {
    return _send<DplManagedUser>(
      () => _dio.post(
        DplPaths.adminUsers,
        data: user.toCreateJson(password: password),
      ),
      fallback: 'Failed to create the user.',
      fromJson: _adminUserFromEnvelope,
    );
  }

  Future<DplApiResponse<DplManagedUser>> updateAdminUser(
    int id,
    DplManagedUser user,
  ) {
    return _send<DplManagedUser>(
      () => _dio.put(DplPaths.adminUserById(id), data: user.toUpdateJson()),
      fallback: 'Failed to update the user.',
      fromJson: _adminUserFromEnvelope,
    );
  }

  /// Disables or re-enables an account.
  ///
  /// There is no delete. Every sticker, scan, slip and trip points at the user
  /// who made it, so removing the row would either break those references or
  /// let the id be reused and re-attribute somebody else's work.
  ///
  /// Refused with `LAST_ADMIN` when it would leave nobody able to administer
  /// the system, and with `CANNOT_DISABLE_SELF` when you are the target.
  Future<DplApiResponse<DplManagedUser>> setAdminUserActive(
    int id,
    bool isActive,
  ) {
    return _send<DplManagedUser>(
      () => _dio.post(
        DplPaths.adminUserStatus(id),
        data: {'is_active': isActive},
      ),
      fallback: 'Failed to change the account status.',
      fromJson: _adminUserFromEnvelope,
    );
  }

  /// Sets someone else's password. There is no matching read — nothing in the
  /// API returns a password or its hash.
  Future<DplApiResponse<DplManagedUser>> resetAdminUserPassword(
    int id,
    String password,
  ) {
    return _send<DplManagedUser>(
      () => _dio.post(
        DplPaths.adminUserPassword(id),
        data: {'password': password},
      ),
      fallback: 'Failed to reset the password.',
      fromJson: _adminUserFromEnvelope,
    );
  }

  Future<DplApiResponse<List<DplAdminOrganization>>> getAdminOrganizations({
    String? q,
    bool includeInactive = true,
  }) {
    return _send<List<DplAdminOrganization>>(
      () => _dio.get(
        DplPaths.adminOrganizations,
        queryParameters: _cleanQuery({
          'q': (q ?? '').trim().isEmpty ? null : q!.trim(),
          // The admin screen is the one place inactive tenants must be
          // visible — otherwise an organization switched off by mistake
          // cannot be switched back on.
          if (includeInactive) 'include_inactive': 'true',
        }),
      ),
      fallback: 'Failed to load organizations.',
      fromJson: (data) => _parseListEnvelope(
        data is Map ? data['organizations'] ?? data : data,
      ).map(DplAdminOrganization.fromJson).toList(),
    );
  }

  Future<DplApiResponse<DplAdminOrganization>> createAdminOrganization(
    DplAdminOrganization org,
  ) {
    return _send<DplAdminOrganization>(
      () => _dio.post(DplPaths.adminOrganizations, data: org.toJsonForWrite()),
      fallback: 'Failed to create the organization.',
      fromJson: (data) => DplAdminOrganization.fromJson(
        data is Map && data['organization'] is Map
            ? Map<String, dynamic>.from(data['organization'] as Map)
            : Map<String, dynamic>.from(data as Map),
      ),
    );
  }

  /// Renaming, recoding or deactivating a tenant. Deactivation is refused with
  /// `ORG_HAS_ACTIVE_USERS` while anyone there can still log in.
  Future<DplApiResponse<DplAdminOrganization>> updateAdminOrganization(
    int id,
    DplAdminOrganization org,
  ) {
    return _send<DplAdminOrganization>(
      () => _dio.put(
        DplPaths.adminOrganizationById(id),
        data: org.toJsonForWrite(),
      ),
      fallback: 'Failed to update the organization.',
      fromJson: (data) => DplAdminOrganization.fromJson(
        data is Map && data['organization'] is Map
            ? Map<String, dynamic>.from(data['organization'] as Map)
            : Map<String, dynamic>.from(data as Map),
      ),
    );
  }

  /// The whole grid for one organization. Omit [organizationId] to get the
  /// caller's own.
  Future<DplApiResponse<DplPermissionMatrix>> getAdminPermissions({
    int? organizationId,
  }) {
    return _send<DplPermissionMatrix>(
      () => _dio.get(
        DplPaths.adminPermissions,
        queryParameters: _cleanQuery({'organization_id': organizationId}),
      ),
      fallback: 'Failed to load the access rules.',
      fromJson: (data) => DplPermissionMatrix.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      ),
    );
  }

  /// Saves the changed cells for one role.
  ///
  /// Only the changes are sent, not the whole row: a full-row save would
  /// write an override for every permission, freezing that role at today's
  /// defaults so a later change to a default could never reach it.
  ///
  /// Refused with `ADMIN_LOCKOUT_REFUSED` if it would leave nobody able to
  /// manage users or access rules.
  Future<DplApiResponse<void>> setAdminPermissions({
    required int organizationId,
    required String role,
    required Map<String, bool> changes,
  }) {
    return _send<void>(
      () => _dio.put(
        DplPaths.adminPermissions,
        data: {
          'organization_id': organizationId,
          'role': role,
          'permissions': changes,
        },
      ),
      fallback: 'Failed to save the access rules.',
    );
  }

  /// Drops every override for one role, returning it to the built-in default.
  Future<DplApiResponse<void>> resetAdminPermissions({
    required int organizationId,
    required String role,
  }) {
    return _send<void>(
      () => _dio.post(
        DplPaths.adminPermissionsReset,
        data: {'organization_id': organizationId, 'role': role},
      ),
      fallback: 'Failed to reset the access rules.',
    );
  }

  Future<DplApiResponse<List<DplUserAuditEntry>>> getAdminAudit({
    int? organizationId,
    int? targetUserId,
    int page = 1,
    int limit = 50,
  }) {
    return _send<List<DplUserAuditEntry>>(
      () => _dio.get(
        DplPaths.adminAudit,
        queryParameters: _cleanQuery({
          'organization_id': organizationId,
          'target_user_id': targetUserId,
          'page': page,
          'limit': limit,
        }),
      ),
      fallback: 'Failed to load the account history.',
      fromJson: (data) => _parseListEnvelope(
        data is Map ? data['entries'] ?? data : data,
      ).map(DplUserAuditEntry.fromJson).toList(),
    );
  }

  /// Every admin write returns `{ user: {...} }`; a few older proxies unwrap
  /// it. Tolerating both here keeps the call sites from each repeating the
  /// same two-line guess.
  DplManagedUser _adminUserFromEnvelope(dynamic data) {
    return DplManagedUser.fromJson(
      data is Map && data['user'] is Map
          ? Map<String, dynamic>.from(data['user'] as Map)
          : Map<String, dynamic>.from(data as Map),
    );
  }
}

/// Lightweight user summary returned by `GET /dispatch/drivers` — just
/// enough to render a picker row without pulling a full user record.
class DplDriverUser {
  final int id;
  final String name;
  final String? email;
  final String? employeeCode;

  /// The trip this driver is currently committed to (assigned + not yet
  /// completed/cancelled), or null when free. A driver can be on at most
  /// one active trip; the picker disables a busy driver.
  final int? activeTripId;
  final int? activeTripNumber;

  const DplDriverUser({
    required this.id,
    required this.name,
    this.email,
    this.employeeCode,
    this.activeTripId,
    this.activeTripNumber,
  });

  /// True when the driver is already out on an active trip.
  bool get isBusy => activeTripId != null;

  factory DplDriverUser.fromJson(Map<String, dynamic> json) {
    final rawTripId = json['active_trip_id'] ?? json['activeTripId'];
    final rawTripNo = json['active_trip_number'] ?? json['activeTripNumber'];
    return DplDriverUser(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name']?.toString() ?? '').trim(),
      email: json['email']?.toString(),
      employeeCode: (json['employee_code'] ?? json['employeeCode'])?.toString(),
      activeTripId: rawTripId is num ? rawTripId.toInt() : null,
      activeTripNumber: rawTripNo is num ? rawTripNo.toInt() : null,
    );
  }
}

// -----------------------------------------------------------------------------
// Auxiliary auth DTOs (only used by the optional DPL-native login flow)
// -----------------------------------------------------------------------------

class DplLoginResult {
  final String token;
  final DplUserProfile? user;

  const DplLoginResult({required this.token, this.user});

  factory DplLoginResult.fromJson(Map<String, dynamic> json) {
    final rawUser = json['user'];
    return DplLoginResult(
      token: json['token']?.toString() ?? '',
      user: rawUser is Map
          ? DplUserProfile.fromJson(Map<String, dynamic>.from(rawUser))
          : null,
    );
  }
}

class DplUserProfile {
  final int id;
  final String name;
  final String email;
  final String role;

  /// Backend now bundles the user's active organization on every
  /// `/auth/login` and `/auth/me` response. `organizationId` is the FK
  /// the JWT carries; `organization` is the resolved tenant record we
  /// render in the AppBar / profile drawer. Both may be null if the
  /// user record is misconfigured server-side — code handling that
  /// case should treat it as the `NO_ORGANIZATION` error path.
  final int? organizationId;
  final DplOrganization? organization;

  /// The permission keys this user holds (backend migration 148).
  ///
  /// `null` means the server did not send the field at all — an API older
  /// than migration 148. That is NOT the same as `[]`, which means the server
  /// answered and the answer was "nothing". Screens must treat null as
  /// "fall back to the role checks" and an empty list as a real denial; the
  /// two are kept distinct all the way to [DplPermissions] for that reason.
  final List<String>? permissions;

  /// True right after an administrator created the account or reset its
  /// password. The app routes such a user to change their password.
  final bool mustChangePassword;

  const DplUserProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.organizationId,
    this.organization,
    this.permissions,
    this.mustChangePassword = false,
  });

  factory DplUserProfile.fromJson(Map<String, dynamic> json) {
    final rawOrg = json['organization'];
    final rawPerms = json['permissions'];
    return DplUserProfile(
      id: json['id'] is int ? json['id'] as int : 0,
      name: json['name']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      role: json['role']?.toString() ?? '',
      organizationId:
          json['organization_id'] is int ? json['organization_id'] as int : null,
      organization: rawOrg is Map
          ? DplOrganization.fromJson(Map<String, dynamic>.from(rawOrg))
          : null,
      permissions: rawPerms is List
          ? rawPerms.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
          : null,
      mustChangePassword: json['must_change_password'] == true ||
          json['mustChangePassword'] == true,
    );
  }
}

// -----------------------------------------------------------------------------
// Riverpod provider
// -----------------------------------------------------------------------------

final dplApiServiceProvider = Provider<DplApiService>((ref) {
  return DplApiService(ref.watch(dplDioProvider));
});
