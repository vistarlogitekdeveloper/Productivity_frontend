class AppConstants {
  static const String appName = 'Vistar Pulse';
  static const String apiBaseUrl =
      'https://api.vistarlogitek.com/api/v1/productivity';

  // Base URL for the Daily Production Loading (DPL) module. The DPL
  // endpoints live under a parallel path on the same backend host.
  static const String dplApiBaseUrl =
      'https://api.vistarlogitek.com/api/v1/dpl';

  // Shared Preferences Keys
  static const String tokenKey = 'AUTH_TOKEN';
  static const String userRoleKey = 'USER_ROLE';
  static const String userIdKey = 'USER_ID';
  static const String usernameKey = 'USERNAME';
  static const String userNameKey = 'USER_NAME';
  static const String offlineEntriesKey = 'OFFLINE_ENTRIES';
  static const String themeModeKey = 'THEME_MODE';

  // DPL active-organization snapshot — written on login, read on app
  // restart so the AppBar pill renders without an extra round-trip.
  static const String dplOrgIdKey = 'DPL_ORG_ID';
  static const String dplOrgCodeKey = 'DPL_ORG_CODE';
  static const String dplOrgNameKey = 'DPL_ORG_NAME';

  /// The permission keys the logged-in DPL user holds, written on login and
  /// re-read on app restart so a screen never renders before it knows what
  /// the person is allowed to do. Advisory only — the server re-checks every
  /// request, so a stale copy here can hide a button but can never grant one.
  static const String dplPermissionsKey = 'DPL_PERMISSIONS';

  /// The floor language the operator chose for DPL messages: 'mr', 'hi', or absent (English).
  static const String dplLanguageKey = 'DPL_LANGUAGE';

  /// Keys that belong to the DEVICE, not the signed-in person, and must
  /// survive logout. The offline outbox holds floor work not yet synced
  /// (each item already names the operator who did it); losing it on a
  /// shift change would silently drop real scans, and a new device id would
  /// orphan the server-side sequence. The floor language is the handheld's
  /// setting too.
  static const String dplSyncOutboxKey = 'dpl_sync_outbox_v1';
  static const String dplSyncNextSeqKey = 'dpl_sync_next_seq';
  static const String dplDeviceIdKey = 'dpl_device_id';
  static const List<String> deviceScopedKeys = [
    dplSyncOutboxKey,
    dplSyncNextSeqKey,
    dplDeviceIdKey,
    dplLanguageKey,
  ];

  /// True while the backend says this account is still on a password somebody
  /// else chose — an administrator created it, or reset it. The router forces
  /// the user to `/dpl/change-password` until it clears.
  static const String dplMustChangePasswordKey = 'DPL_MUST_CHANGE_PASSWORD';

  // Roles
  static const String roleAdmin = 'ADMIN';
  static const String roleSupervisor = 'SUPERVISOR';
  static const String roleBrin = 'BRIN';
  static const String roleOperator = 'OPERATOR';

  /// DPL Administrator. Creates organizations and users, and edits the
  /// role/permission grid. Backend value `dpl_admin` (migration 148).
  ///
  /// Distinct from [roleAdmin], which belongs to the Productivity module and
  /// lands on `/admin-dashboard`. The two are unrelated despite the name.
  static const String roleDplAdmin = 'DPL_ADMIN';

  static const String roleDplManager = 'DPL_MANAGER';
  static const String roleDplSupervisor = 'DPL_SUPERVISOR';

  /// Read-only DPL viewer — sees the Manager Dashboard + Plans tab but
  /// cannot create / edit / delete anything.
  static const String roleDplCustomer = 'DPL_CUSTOMER';

  /// Downstream "production summary" viewers — Dispatch / QA / PDI.
  /// They share a single Production Summary screen and have no other
  /// access into the DPL module.
  static const String roleDplDispatch = 'DPL_DISPATCH';
  static const String roleDplQa = 'DPL_QA';
  static const String roleDplPdi = 'DPL_PDI';

  /// Dispatch Data-Entry Operator. Sits between Dispatch and PDI: receives
  /// the slips Dispatch cuts (status `pending_deo`), stamps the trip's
  /// invoice number, then forwards the whole trip to PDI + emails it.
  static const String roleDplDeo = 'DPL_DEO';

  /// Vistar Workspace portal user. Lands on `/apps` — the launcher for
  /// the wider Vistar app family (KRA, VTMS, Vistar Hire, …). Holds no
  /// production data access of its own.
  static const String roleVistarWorkspace = 'VISTAR_WORKSPACE';

  /// Scanner-only DPL roles. Each of these lands on its own scanner home
  /// screen (not the shared Production Summary shell) and has no other
  /// access into the DPL module.
  static const String roleDplSecurity = 'DPL_SECURITY';
  static const String roleDplQre = 'DPL_QRE';
  static const String roleDplDriver = 'DPL_DRIVER';

  static const List<String> assignableRoles = <String>[
    roleAdmin,
    roleSupervisor,
    roleBrin,
    roleOperator,
  ];

  static String normalizeRole(String role) => role.trim().toUpperCase();

  static String roleLabel(String role) {
    switch (normalizeRole(role)) {
      case roleAdmin:
        return 'Admin';
      case roleSupervisor:
        return 'Supervisor';
      case roleBrin:
        return 'BRIN';
      case roleOperator:
        return 'Operator';
      case roleDplAdmin:
        return 'DPL Administrator';
      case roleDplManager:
        return 'DPL Manager';
      case roleDplSupervisor:
        return 'DPL Supervisor';
      case roleDplCustomer:
        return 'DPL Customer';
      case roleDplDispatch:
        return 'DPL Dispatch';
      case roleDplQa:
        return 'DPL QA';
      case roleDplPdi:
        return 'DPL PDI';
      case roleDplDeo:
        return 'Dispatch DEO';
      case roleDplSecurity:
        return 'DPL Security';
      case roleDplQre:
        return 'DPL QRE';
      case roleDplDriver:
        return 'DPL Driver';
      case roleVistarWorkspace:
        return 'Vistar Workspace';
      default:
        return normalizeRole(role);
    }
  }

  static bool isSupervisorRole(String role) =>
      normalizeRole(role) == roleSupervisor;

  static bool isBrinRole(String role) => normalizeRole(role) == roleBrin;

  static bool isAdminDashboardRole(String role) {
    final normalized = normalizeRole(role);
    return normalized == roleAdmin || normalized == roleSupervisor;
  }

  static bool isDplAdminRole(String role) =>
      normalizeRole(role) == roleDplAdmin;

  static bool isDplManagerRole(String role) =>
      normalizeRole(role) == roleDplManager;

  static bool isDplSupervisorRole(String role) =>
      normalizeRole(role) == roleDplSupervisor;

  static bool isDplCustomerRole(String role) =>
      normalizeRole(role) == roleDplCustomer;

  static bool isDplDispatchRole(String role) =>
      normalizeRole(role) == roleDplDispatch;

  static bool isDplQaRole(String role) => normalizeRole(role) == roleDplQa;

  static bool isDplPdiRole(String role) => normalizeRole(role) == roleDplPdi;

  static bool isDplDeoRole(String role) => normalizeRole(role) == roleDplDeo;

  static bool isDplSecurityRole(String role) =>
      normalizeRole(role) == roleDplSecurity;

  static bool isDplQreRole(String role) => normalizeRole(role) == roleDplQre;

  static bool isDplDriverRole(String role) =>
      normalizeRole(role) == roleDplDriver;

  static bool isVistarWorkspaceRole(String role) =>
      normalizeRole(role) == roleVistarWorkspace;

  /// Any of the downstream "summary-only" roles (Dispatch / QA / PDI /
  /// DEO). These users land on the Production Summary shell and have no
  /// other DPL access.
  static bool isDplSummaryViewerRole(String role) =>
      isDplDispatchRole(role) ||
      isDplQaRole(role) ||
      isDplPdiRole(role) ||
      isDplDeoRole(role);

  static bool isDplRole(String role) =>
      isDplAdminRole(role) ||
      isDplManagerRole(role) ||
      isDplSupervisorRole(role) ||
      isDplCustomerRole(role) ||
      isDplSummaryViewerRole(role) ||
      isDplSecurityRole(role) ||
      isDplQreRole(role) ||
      isDplDriverRole(role);
}
