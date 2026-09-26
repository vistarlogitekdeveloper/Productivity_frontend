import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../features/auth/auth_provider.dart';
import '../../features/auth/force_password_change_screen.dart';
import '../../features/auth/login_screen.dart';
import '../../features/dpl/core/dpl_password_gate_provider.dart';
import '../../features/dashboard/admin_dashboard_screen.dart';
import '../../features/dashboard/brin_dashboard_screen.dart';
import '../../features/dashboard/operator_dashboard_screen.dart';
import '../../features/dpl/admin/admin_shell.dart';
import '../../features/dpl/journey/screens/driver_home_screen.dart';
import '../../features/dpl/journey/screens/qre_home_screen.dart';
import '../../features/dpl/journey/screens/security_home_screen.dart';
import '../../features/dpl/manager/manager_shell.dart';
import '../../features/dpl/manager/screens/masters/downtime_reasons_master_screen.dart';
import '../../features/dpl/manager/screens/masters/machines_master_screen.dart';
import '../../features/dpl/manager/screens/masters/locations_master_screen.dart';
import '../../features/dpl/manager/screens/masters/manpower_master_screen.dart';
import '../../features/dpl/manager/screens/masters/parts_master_screen.dart';
import '../../features/dpl/manager/screens/identity_audit_screen.dart';
import '../../features/dpl/core/dpl_permissions_provider.dart';
import '../../features/dpl/qa/screens/qa_pallet_register_screen.dart';
import '../../features/dpl/manager/screens/masters/shifts_master_screen.dart';
import '../../features/dpl/manager/screens/buffer_norms_screen.dart';
import '../../features/dpl/manager/screens/dispatch_plan_view_screen.dart';
import '../../features/dpl/manager/screens/dispatch_planning_hub_screen.dart';
import '../../features/dpl/manager/screens/morning_stock_update_screen.dart';
import '../../features/dpl/manager/screens/part_field_edit_screen.dart';
import '../../features/dpl/manager/screens/plan_detail_screen.dart';
import '../../features/dpl/manager/screens/plan_trip_screen.dart';
import '../../features/dpl/manager/screens/todays_dispatch_plan_screen.dart';
import '../../features/dpl/models/dpl_part_field.dart';
import '../../features/dpl/manager/screens/upload_plan_screen.dart';
import '../../features/dpl/qa/qa_shell.dart';
import '../../features/dpl/qa/screens/qa_plan_detail_screen.dart';
import '../../features/dpl/qa/screens/qa_scanner_screen.dart';
import '../../features/dpl/summary/summary_shell.dart';
import '../../features/dpl/supervisor/screens/machine_plan_screen.dart';
import '../../features/dpl/supervisor/screens/plan_execution_screen.dart';
import '../../features/dpl/supervisor/screens/supervisor_shell.dart';
import '../../features/production_entry/production_entry_screen.dart';
import '../../features/workspace/workspace_screen.dart';
import '../constants/app_constants.dart';
import '../widgets/vistar/vistar_loaders.dart';

part 'app_router.g.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

@riverpod
GoRouter appRouter(Ref ref) {
  final authState = ref.watch(authControllerProvider);
  // Watched, not read: clearing the flag after a successful change has to
  // re-run the redirect, otherwise the user stays pinned to the screen they
  // just satisfied.
  final mustChangePassword = ref.watch(dplMustChangePasswordProvider);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/login',
    // Visual only — flashes the breathing-S loader on screen switches.
    observers: [VistarRouteLoader.instance],
    redirect: (context, state) {
      const loginPath = '/login';
      const adminDashboardPath = '/admin-dashboard';
      const brinDashboardPath = '/brin-dashboard';
      const operatorDashboardPath = '/operator-dashboard';
      const newEntryPath = '/new-entry';
      const dplAdminPath = '/dpl/admin';
      const dplManagerPath = '/dpl/manager';
      const dplSupervisorPath = '/dpl/supervisor';
      const dplSummaryPath = '/dpl/summary';
      const dplQaPath = '/dpl/qa';
      const dplSecurityPath = '/dpl/security';
      const dplQrePath = '/dpl/qre';
      const dplDriverPath = '/dpl/driver';
      const workspacePath = '/apps';

      final isAuth = authState.value != null;
      final isLoggingIn = state.matchedLocation == loginPath;
      final role = authState.value?.role ?? '';
      final isAdminRole = AppConstants.isAdminDashboardRole(role);
      final isBrinRole = AppConstants.isBrinRole(role);
      final isDplAdminRole = AppConstants.isDplAdminRole(role);
      final isDplManagerRole = AppConstants.isDplManagerRole(role);
      final isDplSupervisorRole = AppConstants.isDplSupervisorRole(role);
      final isDplCustomerRole = AppConstants.isDplCustomerRole(role);
      final isDplSummaryViewerRole =
          AppConstants.isDplSummaryViewerRole(role);
      final isDplQaRole = AppConstants.isDplQaRole(role);
      final isDplSecurityRole = AppConstants.isDplSecurityRole(role);
      final isDplQreRole = AppConstants.isDplQreRole(role);
      final isDplDriverRole = AppConstants.isDplDriverRole(role);
      final isWorkspaceRole = AppConstants.isVistarWorkspaceRole(role);

      final defaultDashboardPath = isWorkspaceRole
          ? workspacePath
          // The Administrator lands on their own panel. Tested first because
          // no other predicate claims DPL_ADMIN, and putting it here keeps the
          // chain in "most specific role wins" order.
          : isDplAdminRole
          ? dplAdminPath
          : isDplManagerRole
          ? dplManagerPath
          : isDplSupervisorRole
              ? dplSupervisorPath
              : isDplCustomerRole
                  ? dplManagerPath
                  // QA MUST be tested before isDplSummaryViewerRole: that
                  // predicate already returns true for DPL_QA, so a QA branch
                  // placed after it would be unreachable and QA would keep
                  // landing on /dpl/summary.
                  : isDplQaRole
                      ? dplQaPath
                      : isDplSummaryViewerRole
                      ? dplSummaryPath
                      : isDplSecurityRole
                          ? dplSecurityPath
                          : isDplQreRole
                              ? dplQrePath
                              : isDplDriverRole
                                  ? dplDriverPath
                                  : isAdminRole
                                      ? adminDashboardPath
                                      : isBrinRole
                                          ? brinDashboardPath
                                          : operatorDashboardPath;

      // If still loading init state, don't redirect aggressively
      if (authState.isLoading && !isAuth) return null;

      if (!isAuth) {
        return isLoggingIn ? null : loginPath;
      }

      // Forced password change. Placed BEFORE every other authenticated
      // redirect so no role branch below can route around it.
      //
      // The flag means the password that just got this user in was chosen by
      // somebody else — an administrator set it, or it is the built-in
      // bootstrap value, which is a constant in the repository. Until they
      // replace it, the only reachable destinations are this screen and
      // logging out.
      //
      // Scoped to DPL roles because the flag and the screen behind it both
      // talk to the DPL backend. A stale flag left over from a previous DPL
      // session must not strand a Productivity user on a screen whose
      // endpoint would reject them.
      const changePasswordPath = '/dpl/change-password';
      final passwordGateApplies =
          mustChangePassword && AppConstants.isDplRole(role);
      if (passwordGateApplies) {
        return state.matchedLocation == changePasswordPath
            ? null
            : changePasswordPath;
      }
      // Nothing to change, so nobody should be sitting on that screen.
      if (state.matchedLocation == changePasswordPath) {
        return defaultDashboardPath;
      }

      if (isLoggingIn || state.matchedLocation == '/') {
        return defaultDashboardPath;
      }

      // Keep users in role-appropriate dashboard routes.
      if (state.matchedLocation == adminDashboardPath && !isAdminRole) {
        return defaultDashboardPath;
      }
      if (state.matchedLocation == brinDashboardPath && !isBrinRole) {
        return defaultDashboardPath;
      }
      // The Workspace launcher belongs to the portal role alone — every
      // other role gets bounced to their own dashboard.
      if (state.matchedLocation.startsWith(workspacePath) &&
          !isWorkspaceRole) {
        return defaultDashboardPath;
      }
      if (state.matchedLocation == operatorDashboardPath &&
          (isAdminRole ||
              isBrinRole ||
              isWorkspaceRole ||
              isDplAdminRole ||
              isDplManagerRole ||
              isDplSupervisorRole ||
              isDplCustomerRole ||
              isDplSummaryViewerRole ||
              isDplSecurityRole ||
              isDplQreRole ||
              isDplDriverRole)) {
        return defaultDashboardPath;
      }
      // The Administration panel belongs to the Administrator alone. The
      // panel's own tabs are gated per-permission inside the shell, and every
      // endpoint behind them is gated again server-side; this check is only
      // about which role the route belongs to.
      if (state.matchedLocation.startsWith(dplAdminPath) && !isDplAdminRole) {
        return defaultDashboardPath;
      }
      // Sandbox each new journey shell to only its own role.
      if (state.matchedLocation.startsWith(dplSecurityPath) && !isDplSecurityRole) {
        return defaultDashboardPath;
      }
      if (state.matchedLocation.startsWith(dplQrePath) && !isDplQreRole) {
        return defaultDashboardPath;
      }
      if (state.matchedLocation.startsWith(dplDriverPath) && !isDplDriverRole) {
        return defaultDashboardPath;
      }
      // QA's own shell. The Manager is allowed in too so the flow can be
      // verified without borrowing a QA badge — an audit trail that names the
      // wrong person is worse than no audit trail.
      if (state.matchedLocation.startsWith(dplQaPath) &&
          !(isDplQaRole || isDplManagerRole)) {
        return defaultDashboardPath;
      }
      if (state.matchedLocation == newEntryPath && isBrinRole) {
        return brinDashboardPath;
      }

      // Sandbox DPL routes to DPL roles only.
      // DPL Customer can enter `/dpl/manager` shell and view plan detail,
      // but write-only routes (upload, masters, identity audit) are blocked.
      if (state.matchedLocation.startsWith('/dpl/manager') &&
          !(isDplManagerRole || isDplCustomerRole)) {
        return defaultDashboardPath;
      }
      if (isDplCustomerRole) {
        final loc = state.matchedLocation;
        final isWriteOnlyDplRoute = loc.startsWith('/dpl/manager/upload-plan') ||
            loc.startsWith('/dpl/manager/masters') ||
            loc.startsWith('/dpl/manager/identity-audit');
        if (isWriteOnlyDplRoute) {
          return dplManagerPath;
        }
      }
      if (state.matchedLocation.startsWith('/dpl/supervisor') &&
          !isDplSupervisorRole) {
        return defaultDashboardPath;
      }
      // Sandbox the Production Summary (Dispatch) shell to the summary-only
      // roles PLUS the Manager — the manager can toggle into the Dispatch
      // dashboard for quick oversight via the AppBar switcher. Supervisor /
      // Customer still have no business here and are bounced to their shell.
      if (state.matchedLocation.startsWith('/dpl/summary') &&
          !(isDplSummaryViewerRole || isDplManagerRole)) {
        return defaultDashboardPath;
      }

      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/admin-dashboard',
        builder: (context, state) => const AdminDashboardScreen(),
      ),
      GoRoute(
        path: '/operator-dashboard',
        builder: (context, state) => const OperatorDashboardScreen(),
      ),
      GoRoute(
        path: '/brin-dashboard',
        builder: (context, state) => const BrinDashboardScreen(),
      ),
      GoRoute(
        path: '/new-entry',
        builder: (context, state) => const ProductionEntryScreen(),
      ),
      // Vistar Workspace — the launcher for the wider Vistar app family.
      GoRoute(
        path: '/apps',
        builder: (context, state) => const WorkspaceScreen(),
      ),
      // Forced password change. Not nested under any shell: it must be
      // reachable while the redirect above is refusing every other route.
      GoRoute(
        path: '/dpl/change-password',
        builder: (context, state) => const ForcePasswordChangeScreen(),
      ),
      // DPL Administration — users, organizations, access rules and the
      // account-change trail. Which tabs appear is decided inside the shell
      // from the caller's permissions.
      GoRoute(
        path: '/dpl/admin',
        builder: (context, state) => const DplAdminShell(),
      ),
      // DPL Manager — shell with bottom nav for 4 tabs.
      GoRoute(
        path: '/dpl/manager',
        builder: (context, state) => const DplManagerShell(),
        routes: [
          GoRoute(
            path: 'upload-plan',
            builder: (context, state) => const DplUploadPlanScreen(),
          ),
          GoRoute(
            path: 'todays-dispatch-plan',
            builder: (context, state) => const TodaysDispatchPlanScreen(),
          ),
          GoRoute(
            path: 'buffer-norms',
            builder: (context, state) => const BufferNormsScreen(),
          ),
          GoRoute(
            path: 'morning-stock',
            builder: (context, state) => const MorningStockUpdateScreen(),
          ),
          // ───── Simple dispatch planning (3 master fields + computed view) ─────
          GoRoute(
            path: 'dispatch-planning',
            builder: (context, state) => const DispatchPlanningHubScreen(),
          ),
          GoRoute(
            path: 'stocking-norms',
            builder: (context, state) => const PartFieldEditScreen(
              kind: DplPartFieldKind.stockingNorm,
            ),
          ),
          GoRoute(
            path: 'customer-opening-stocks',
            builder: (context, state) => const PartFieldEditScreen(
              kind: DplPartFieldKind.customerOpeningStock,
            ),
          ),
          GoRoute(
            path: 'customer-todays-plans',
            builder: (context, state) => const PartFieldEditScreen(
              kind: DplPartFieldKind.customerTodayPlan,
            ),
          ),
          GoRoute(
            path: 'packaging-qtys',
            builder: (context, state) => const PartFieldEditScreen(
              kind: DplPartFieldKind.packagingQty,
            ),
          ),
          GoRoute(
            path: 'ga-opening-stocks',
            builder: (context, state) => const PartFieldEditScreen(
              kind: DplPartFieldKind.gaOpeningStock,
            ),
          ),
          GoRoute(
            path: 'dispatch-plan-view',
            builder: (context, state) => const DispatchPlanViewScreen(),
          ),
          GoRoute(
            path: 'plan-trip',
            builder: (context, state) => const PlanTripScreen(),
          ),
          GoRoute(
            path: 'plans/:id',
            builder: (context, state) {
              final raw = state.pathParameters['id'] ?? '';
              final id = int.tryParse(raw) ?? 0;
              return DplPlanDetailScreen(planId: id);
            },
          ),
          GoRoute(
            path: 'masters/machines',
            builder: (context, state) => const DplMachinesMasterScreen(),
          ),
          GoRoute(
            path: 'masters/parts',
            builder: (context, state) => const DplPartsMasterScreen(),
          ),
          GoRoute(
            path: 'masters/downtime-reasons',
            builder: (context, state) =>
                const DplDowntimeReasonsMasterScreen(),
          ),
          GoRoute(
            path: 'masters/shifts',
            builder: (context, state) => const DplShiftsMasterScreen(),
          ),
          GoRoute(
            path: 'masters/manpower',
            builder: (context, state) => const DplManpowerMasterScreen(),
          ),
          GoRoute(
            path: 'masters/locations',
            builder: (context, state) => const DplLocationsMasterScreen(),
          ),
          GoRoute(
            path: 'identity-audit',
            builder: (context, state) => const DplIdentityAuditScreen(),
          ),
          // The pallet register, reachable from Settings. The same screen the
          // QA shell mounts as a tab — one implementation, because a second
          // copy of these filters would drift from the first within a release.
          //
          // Guarded here as well as by hiding the Settings tile. Hiding a tile
          // is not access control: this path is a URL in a web build, so it
          // survives in history and in a pasted link long after an
          // administrator revokes the permission.
          GoRoute(
            path: 'pallets',
            builder: (context, state) => const _PalletRegisterGate(),
          ),
        ],
      ),
      // DPL Production Summary — single-tab shell shared by the
      // Dispatch / QA / PDI roles. AppBar title is picked from the
      // authenticated user's role inside the shell.
      GoRoute(
        path: '/dpl/summary',
        builder: (context, state) => const DplSummaryShell(),
      ),
      // DPL QA — production plan vs actual, then scan the raw-material label
      // and print finished-goods labels capped at the recorded actual qty.
      // Child paths are relative (go_router throws on a leading '/').
      GoRoute(
        path: '/dpl/qa',
        builder: (context, state) => const DplQaShell(),
        routes: [
          GoRoute(
            path: 'plans/:id',
            builder: (context, state) => QaPlanDetailScreen(
              planId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
            ),
            routes: [
              GoRoute(
                path: 'items/:itemId/scan',
                builder: (context, state) => QaScannerScreen(
                  planId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
                  planItemId:
                      int.tryParse(state.pathParameters['itemId'] ?? '') ?? 0,
                  // The part this plan item is producing. Labels may only be
                  // printed for it, so the scanner refuses material belonging
                  // to any other part.
                  expectedPartId:
                      int.tryParse(state.uri.queryParameters['partId'] ?? '') ??
                          0,
                  expectedPartNumber:
                      state.uri.queryParameters['partNo'] ?? '',
                ),
              ),
            ],
          ),
        ],
      ),
      // DPL Journey actors — each role lands on their own scanner-driven shell.
      GoRoute(
        path: '/dpl/security',
        builder: (context, state) => const SecurityHomeScreen(),
      ),
      GoRoute(
        path: '/dpl/qre',
        builder: (context, state) => const QreHomeScreen(),
      ),
      GoRoute(
        path: '/dpl/driver',
        builder: (context, state) => const DriverHomeScreen(),
      ),
      // DPL Supervisor — Phase 2 shell with bottom nav.
      GoRoute(
        path: '/dpl/supervisor',
        builder: (context, state) => const SupervisorShell(),
        routes: [
          GoRoute(
            path: 'machine/:planId',
            builder: (context, state) {
              final id = int.tryParse(
                    state.pathParameters['planId'] ?? '',
                  ) ??
                  0;
              return MachinePlanScreen(planId: id);
            },
            routes: [
              GoRoute(
                path: 'execute/:itemId',
                builder: (context, state) {
                  final planId = int.tryParse(
                        state.pathParameters['planId'] ?? '',
                      ) ??
                      0;
                  final itemId = int.tryParse(
                        state.pathParameters['itemId'] ?? '',
                      ) ??
                      0;
                  return PlanExecutionScreen(
                    planId: planId,
                    itemId: itemId,
                  );
                },
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

/// `pallet.view` enforced at the route, not just on the tile that links to it.
///
/// A hidden tile stops discovery; it does not stop a URL. In a web build the
/// register's path lives in browser history and in whatever link somebody
/// pasted into a chat, so revoking the permission has to close the route
/// itself. The server refuses the data either way — this is what stops the
/// operator meeting a screen of red errors instead of a plain explanation.
class _PalletRegisterGate extends ConsumerWidget {
  const _PalletRegisterGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed =
        ref.watch(dplPermissionsProvider).can(DplPermission.palletView);
    if (allowed) return const QaPalletRegisterScreen();

    return Scaffold(
      appBar: AppBar(title: const Text('Pallets')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 44, color: Color(0xFFB6BFCC)),
              const SizedBox(height: 14),
              const Text(
                'The pallet register is not switched on for your plant.',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
              const SizedBox(height: 8),
              const Text(
                'An administrator can enable it for your organization under '
                'Administration — Access rules.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: Color(0xFF5D6A7A)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
