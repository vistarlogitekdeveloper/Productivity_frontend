/// Endpoint paths and status enums for the Daily Production Loading module.
///
/// All paths are relative to [AppConstants.dplApiBaseUrl]
/// (`https://.../api/v1/dpl`).
class DplPaths {
  // Auth
  static const String authLogin = '/auth/login';
  static const String authMe = '/auth/me';
  static const String authLogout = '/auth/logout';
  static const String authChangePassword = '/auth/change-password';
  // Public list used to populate the org selector on the login screen.
  static const String authOrganizations = '/auth/organizations';

  // ---------------------------------------------------------------------------
  // Administration (backend migration 148)
  //
  // Users, organizations, the role/permission grid and the account-change
  // trail. Guarded server-side by PERMISSION rather than by role, so an
  // installation can hand a plant head `admin.users.view` without handing
  // over the whole panel.
  //
  // The administrator works ACROSS organizations: `/admin/users` takes an
  // optional `organization_id` filter and returns every tenant when it is
  // omitted. That is deliberate — an administrator who could only see their
  // own tenant could not move someone between two.
  // ---------------------------------------------------------------------------
  static const String adminCatalogue = '/admin/catalogue';
  static const String adminUsers = '/admin/users';
  static const String adminOrganizations = '/admin/organizations';
  static const String adminPermissions = '/admin/permissions';
  static const String adminPermissionsReset = '/admin/permissions/reset';
  static const String adminAudit = '/admin/audit';

  static String adminUserById(int id) => '/admin/users/$id';
  static String adminUserStatus(int id) => '/admin/users/$id/status';
  static String adminUserPassword(int id) => '/admin/users/$id/password';
  static String adminOrganizationById(int id) => '/admin/organizations/$id';

  // Manager — dashboard
  static const String dashboard = '/manager/dashboard';
  static const String alerts = '/manager/alerts';

  // Manager — masters
  static const String machines = '/manager/machines';
  static String machineById(int id) => '/manager/machines/$id';

  static const String parts = '/manager/parts';
  static String partById(int id) => '/manager/parts/$id';

  static const String supervisors = '/manager/supervisors';

  static const String downtimeReasons = '/manager/downtime-reasons';
  static String downtimeReasonById(int id) => '/manager/downtime-reasons/$id';

  // Manager — plans
  static const String plansUploadExcel = '/manager/plans/upload-excel';
  static const String plans = '/manager/plans';
  static String planById(int id) => '/manager/plans/$id';
  static String planLock(int id) => '/manager/plans/$id/lock';
  static String planChangeStatus(int id) => '/manager/plans/$id/change-status';
  static String planItemChangeStatus(int planId, int itemId) =>
      '/manager/plans/$planId/items/$itemId/change-status';
  static String planItemCarryForward(int planId, int itemId) =>
      '/manager/plans/$planId/items/$itemId/carry-forward';
  static const String carryForwardCandidates =
      '/manager/plans/carry-forward-candidates';
  static String planItems(int id) => '/manager/plans/$id/items';
  static String planItemById(int planId, int itemId) =>
      '/manager/plans/$planId/items/$itemId';
  static String managerPlanPauses(int id) => '/manager/plans/$id/pauses';
  static String managerPlanItemPauses(int planId, int itemId) =>
      '/manager/plans/$planId/items/$itemId/pauses';

  // Manager — reports
  static const String reportPlanVsActual = '/manager/reports/plan-vs-actual';
  static const String reportDowntime = '/manager/reports/downtime';
  static const String reportDowntimeEvents = '/manager/reports/downtime/events';
  static const String reportSupervisorPerformance =
      '/manager/reports/supervisor-performance';
  static const String reportPartWise = '/manager/reports/part-wise';
  static const String reportExport = '/manager/reports/export';
  static const String reportDplChart = '/manager/reports/dpl-chart';

  // Manager — shifts master
  static const String shifts = '/manager/shifts';
  static String shiftById(int id) => '/manager/shifts/$id';

  // Manager — manpower master
  static const String manpower = '/manager/manpower';
  static String manpowerById(int id) => '/manager/manpower/$id';

  // Supervisor — bulk manpower entry for today
  static const String supervisorManpowerToday = '/supervisor/manpower/today';

  // Supervisor
  static const String supervisorToday = '/supervisor/today';
  static String supervisorPlan(int id) => '/supervisor/plans/$id';
  static String supervisorItemStart(int planId, int itemId) =>
      '/supervisor/plans/$planId/items/$itemId/start';
  static String supervisorItemStop(int planId, int itemId) =>
      '/supervisor/plans/$planId/items/$itemId/stop';
  static String supervisorItemActual(int planId, int itemId) =>
      '/supervisor/plans/$planId/items/$itemId/actual';
  static String supervisorItemPause(int planId, int itemId) =>
      '/supervisor/plans/$planId/items/$itemId/pause';
  static String supervisorItemResume(int planId, int itemId) =>
      '/supervisor/plans/$planId/items/$itemId/resume';
  static String supervisorItemPauses(int planId, int itemId) =>
      '/supervisor/plans/$planId/items/$itemId/pauses';
  static String supervisorPlanPauses(int planId) =>
      '/supervisor/plans/$planId/pauses';
  static String supervisorDowntimeStart(int planId) =>
      '/supervisor/plans/$planId/downtime/start';
  static String supervisorDowntimeResume(int downtimeId) =>
      '/supervisor/downtime/$downtimeId/resume';
  static String supervisorPlanDowntimes(int planId) =>
      '/supervisor/plans/$planId/downtimes';
  static const String supervisorShiftSummary = '/supervisor/shift/summary';
  static const String supervisorShiftSubmit = '/supervisor/shift/submit';
  static const String supervisorDowntimeReasons =
      '/supervisor/downtime-reasons';

  // Supervisor — identity verification (selfie gate)
  static const String supervisorIdentityStatus = '/supervisor/identity/status';
  static const String supervisorIdentityVerify = '/supervisor/identity/verify';
  static String supervisorIdentityPhoto(int id) =>
      '/supervisor/identity/$id/photo';

  // Manager — identity-verification audit log
  static const String managerIdentityVerifications =
      '/manager/identity-verifications';
  static String managerIdentityPhoto(int id) =>
      '/manager/identity-verifications/$id/photo';
  static String managerIdentityFlag(int id) =>
      '/manager/identity-verifications/$id/flag';

  // Supervisor — trolley photo capture (gate before STOP)
  static String supervisorItemTrolleyPhoto(int planId, int itemId) =>
      '/supervisor/plans/$planId/items/$itemId/trolley-photo';
  static String supervisorTrolleyPhotoImage(int id) =>
      '/supervisor/trolley-photos/$id/image';

  // Manager — trolley photo audit log
  static const String managerTrolleyPhotos = '/manager/trolley-photos';
  static String managerTrolleyPhotoImage(int id) =>
      '/manager/trolley-photos/$id/image';

  // Manager — live banner (active downtimes across all plans/machines).
  static const String managerActiveDowntimes = '/manager/active-downtimes';

  // Production summary — aggregate of total actual qty produced per
  // (machine, part) bucket. Same endpoint is consumed by the Manager
  // and by the downstream Dispatch / QA / PDI viewers; backend gates
  // access by JWT role.
  static const String productionSummary = '/manager/production-summary';
  static const String productionSummaryOne = '/manager/production-summary/one';

  // Manager — force-close a stuck/orphaned active downtime. Manager-
  // scoped recovery route; differs from the supervisor `resume` route
  // in that it doesn't require the original supervisor to be online.
  static String managerDowntimeClose(int downtimeId) =>
      '/manager/downtime/$downtimeId/close';

  // Plants — hardcoded 3-plant mapping (Nexon EV / TML PV / MG Motors)
  // served from a backend config file. Any DPL role can read the list.
  static const String plants = '/plants';

  // Dispatch trips — manager-submitted truck plans (see migration 048).
  // Each trip has 1–6 plans (one per part); plans flow through
  // open → slip_created → dispatched as dispatchers cut + ship slips.
  static const String dispatchTrips = '/dispatch/trips';
  static const String dispatchTripsNextNumber = '/dispatch/trips/next-number';

  /// How many labelled pieces of each part are still free to plan onto a trip.
  ///
  /// `available = issued stickers − qty already on non-cancelled trip plans`.
  /// The planning screen caps its qty input with this; `POST /dispatch/trips`
  /// re-checks it under an advisory lock, so the client figure is advisory.
  static const String dispatchTripsLabelAvailability =
      '/dispatch/trips/label-availability';

  // Scanning printed labels onto a trip before it goes to the DEO
  // (backend migration 147). A slip cannot be cut until every planned piece
  // has been scanned — enforced server-side in createSlipFromTrip.
  static String tripLabelScans(int tripId) =>
      '/dispatch/trips/$tripId/label-scans';
  static String tripLabelScanUndo(int tripId, String serial) =>
      '/dispatch/trips/$tripId/label-scans/$serial';
  static String tripMasterSticker(int tripId, int planId) =>
      '/dispatch/trips/$tripId/plans/$planId/master-sticker';
  static String dispatchTripById(int id) => '/dispatch/trips/$id';
  static String dispatchTripCancel(int id) => '/dispatch/trips/$id/cancel';
  static String dispatchTripPlan(int tripId, int planId) =>
      '/dispatch/trips/$tripId/plans/$planId';

  // Dispatch trips — consolidated slip + gate/dock journey (gate cutover).
  // Consolidated-slip aggregates every slip on a trip into a single
  // printable/emailable payload. The journey feed captures the security /
  // driver / QRE events (gate-out, tata-gate-in, tata-dock-in/out, tata-
  // gate-out) that follow the DEO invoice step. `driver` assignment is
  // done manager-side after the trip is planned; `driverMyTrips` is the
  // driver-role list of trips currently assigned to the caller.
  static const String driverMyTrips = '/driver/my-trips';
  static String tripConsolidatedSlip(int id) =>
      '/dispatch/trips/$id/consolidated-slip';
  static String tripJourney(int id) => '/dispatch/trips/$id/journey';
  static String tripDriver(int id) => '/dispatch/trips/$id/driver';
  static String tripGateOut(int id) => '/dispatch/trips/$id/gate-out';
  static String tripGateIn(int id) => '/dispatch/trips/$id/gate-in';
  static String tripTataGateIn(int id) => '/dispatch/trips/$id/tata-gate-in';
  static String tripTataDockIn(int id) => '/dispatch/trips/$id/tata-dock-in';
  static String tripTataDockOut(int id) => '/dispatch/trips/$id/tata-dock-out';
  static String tripTataGateOut(int id) => '/dispatch/trips/$id/tata-gate-out';

  /// Live trip tracking. One path, both directions:
  ///   * `POST` — driver app flushes a **batch** of GPS fixes (batched so
  ///     a dead-zone backlog uploads in one request when signal returns).
  ///   * `GET`  — dispatch/manager reads the breadcrumb trail for the
  ///     track map. Supports `?since=<iso8601>` for incremental polling.
  static String tripLocations(int id) => '/dispatch/trips/$id/locations';

  // Assign-Driver picker (dispatch/manager) + role-scoped pending-work
  // lists (security/qre home dashboards).
  static const String dispatchDrivers = '/dispatch/drivers';
  static const String securityPendingGateOut = '/security/pending-gate-out';
  static const String qrePendingDockIn = '/qre/pending-dock-in';

  /// `POST /dispatch/trips/:id/send-for-pdi` — DEO role. Stamps the
  /// trip's invoice no, records the DEO actor, and transitions all the
  /// trip's `pending_deo` slips to `pending_pdi` in one transaction.
  static String dispatchTripSendForPdi(int id) =>
      '/dispatch/trips/$id/send-for-pdi';

  // Dispatch slip workflow — Dispatch → QA → PDI three-step approval
  // pipeline with an HMAC-signed QR payload printed on the slip. Roles
  // are gated server-side; the verify endpoint is public.
  static const String dispatchSlips = '/dispatch/slips';
  static String dispatchSlipById(int id) => '/dispatch/slips/$id';
  static String dispatchSlipQaApprove(int id) =>
      '/dispatch/slips/$id/qa-approve';
  static String dispatchSlipQaReject(int id) => '/dispatch/slips/$id/qa-reject';
  static String dispatchSlipPdiApprove(int id) =>
      '/dispatch/slips/$id/pdi-approve';
  static String dispatchSlipPdiReject(int id) =>
      '/dispatch/slips/$id/pdi-reject';
  static String dispatchSlipMarkDispatched(int id) =>
      '/dispatch/slips/$id/mark-dispatched';
  static String dispatchSlipEmail(int id) => '/dispatch/slips/$id/email';
  static const String dispatchSlipVerify = '/dispatch/slips/verify';

  /// `GET /dispatch/reports/plan-vs-actual` — Dispatch + Manager. Returns
  /// the per-(plant, machine, part) breakdown of planned dispatch (Σ trip
  /// plan qty by trip date) vs actual dispatch (Σ dispatched-slip qty by
  /// dispatch date) for Today / MTD / Till-date. The FE filters, sorts and
  /// re-aggregates client-side.
  static const String dispatchPlanVsActual = '/dispatch/reports/plan-vs-actual';

  // ---------------------------------------------------------------------------
  // Auto Dispatch Plan (migration 045) — JIT buffer-replenishment calculator
  // ---------------------------------------------------------------------------
  // Buffer Norms — master data, manager configures per part (target + trolley
  // capacity + trips/day). Drives the FE DplDispatchCalculator inputs.
  static const String bufferNorms = '/manager/buffer-norms';

  // Daily Customer Snapshots — morning entry of TML opening stock + the
  // customer's planned consumption today (per part, per date).
  static const String customerSnapshots = '/manager/customer-snapshots';

  // Dispatch Plan Inputs — the single calculator-feeder endpoint. Backend
  // joins buffer norms + snapshot + GA stock + GA plan and returns the
  // per-part inputs that map 1:1 to `DispatchCalcInput`.
  static const String dispatchPlanInputs = '/manager/dispatch-plan/inputs';

  // Bulk slip creation — atomic N-slip POST used after the calculator
  // produces today's plan. All-or-nothing (single DB transaction).
  static const String dispatchSlipsBulk = '/dispatch/slips/bulk';

  // ---------------------------------------------------------------------------
  // Simple Dispatch Planning — three per-part master fields the manager
  // edits at different cadences. Dispatch = (StockingNorm + TodaysPlan)
  // − CustomerOpeningStock.
  //   stocking-norms          — configured ONCE per part
  //   customer-opening-stocks — refreshed MONTHLY
  //   customer-todays-plans   — updated DAILY
  // ---------------------------------------------------------------------------
  static const String stockingNorms = '/manager/stocking-norms';
  static const String customerOpeningStocks =
      '/manager/customer-opening-stocks';
  static const String customerTodaysPlans = '/manager/customer-todays-plans';

  // GA Opening Stock — per-part opening stock held at GA, refreshed
  // monthly. Manual master seeding the buffer report's "Opn Stock at GA"
  // column (the Dispatch role that runs the report must be able to read it).
  static const String gaOpeningStocks = '/manager/ga-opening-stocks';

  // Packaging Qty — customer-supplied units per pack (migration 049).
  // Drives the "Pack: N NOS" hint on every qty input across the
  // dispatch flow. Not enforced by backend; partial packs are valid.
  static const String packagingQtys = '/manager/packaging-qtys';

  // ---------------------------------------------------------------------------
  // QA finished-goods stickers (backend migration 144).
  //
  // QA scans the Grupo Antolin raw-material label on a produced part, the
  // server resolves its substrate part no to the customer part reference(s)
  // it maps to (one substrate legitimately maps to several), QA picks one,
  // and the server issues serials — never more than the plan item's recorded
  // `actual_qty`.
  //
  // Serials are ALWAYS server-issued. The app must never mint its own: two
  // handhelds doing that produce colliding labels on physical parts.
  //
  // QA's plan-browsing screens deliberately reuse `/manager/plans`,
  // `/manager/plans/:id` and `/manager/dashboard` — `dpl_qa` was added to
  // those endpoints' read-only role guard so the QA view cannot drift from
  // the Manager view it is meant to mirror.
  // ---------------------------------------------------------------------------
  // Direct printing (backend migration 149). Labels with NO production plan
  // behind them and NO actual-quantity cap — Maxion SSR v3.0 §5.2, where the
  // pack point prints a pallet's worth in one go and over-printing is caught
  // by shift-end reconciliation rather than refused up front.
  //
  // Server-gated on `labels.print_batch`, which an administrator grants per
  // organization. A plant without it gets 403 DIRECT_PRINT_NOT_ALLOWED and
  // keeps the plan-item cap unchanged.
  static const String qaStickersDirect = '/qa/stickers/direct';
  static const String qaMachines = '/qa/machines';
  static const String qaParts = '/qa/parts';

  // Pallet build and close (backend migration 151, Maxion SSR Module 4).
  // The operator opens a pallet, scans printed wheel labels onto it, and
  // closes it; the SYSTEM decides full / half / merged and issues the number.
  static const String qaPallets = '/qa/pallets';
  static const String qaPalletOpen = '/qa/pallets/open';
  static const String qaPalletsHalf = '/qa/pallets/half';
  static const String qaPalletsCombine = '/qa/pallets/combine';

  static String qaPalletById(int palletId) => '/qa/pallets/$palletId';
  static String qaPalletScan(int palletId) => '/qa/pallets/$palletId/scan';
  static String qaPalletClose(int palletId) => '/qa/pallets/$palletId/close';

  /// Fill one closed pallet from another, stopping at the standard quantity.
  static const String qaPalletsMerge = '/qa/pallets/merge';

  /// The drag-and-drop merge: the operator says where each moved wheel ends up.
  static const String qaPalletsRedistribute = '/qa/pallets/redistribute';

  // --- SPD conversion (SSR §8, Module 12) ---
  static const String qaSpdPacks = '/qa/spd';
  static String qaPalletWheels(int palletId) => '/qa/pallets/$palletId/wheels';
  static String qaPalletSpd(int palletId) => '/qa/pallets/$palletId/spd';
  static String qaPalletUndoScan(int palletId, String serial) =>
      '/qa/pallets/$palletId/scan/$serial';

  /// The master pallet label's data — the client renders the PDF.
  ///
  /// A GET of its own rather than a field on the close response, because
  /// SSR §5 has the pallet label reprinted "when the pallet changes, for
  /// example on a merge" — long after the close, often by someone else.
  static String qaPalletLabel(int palletId) => '/qa/pallets/$palletId/label';

  // --- Warehouse putaway (Maxion SSR Module 6) ---
  //
  // A SEPARATE prefix from /qa on purpose. The QA router is role-locked to
  // dpl_qa / dpl_supervisor / dpl_manager before any permission is read, so a
  // pallet endpoint living there could never be granted to a storeman however
  // the administrator sets the grid. These are guarded by `pallet.putaway`
  // alone, which is what makes "who racks a pallet" a setting.
  static const String warehouseLocations = '/warehouse/locations';
  static const String warehousePalletResolve = '/warehouse/pallets/resolve';
  static String warehousePalletPutaway(int palletId) =>
      '/warehouse/pallets/$palletId/putaway';

  static const String qaCurrentShift = '/qa/current-shift';
  static const String qaScanResolve = '/qa/scan/resolve';
  static const String qaStickers = '/qa/stickers';
  static const String qaStickersVoid = '/qa/stickers/void';

  static String qaStickerSummary(int planItemId) =>
      '/qa/plan-items/$planItemId/stickers/summary';
  static String qaIssueStickers(int planItemId) =>
      '/qa/plan-items/$planItemId/stickers';

  // ---------------------------------------------------------------------------
  // Storage locations (backend migration 146).
  //
  // The master is manager-maintained and carries a capacity; QA reads it
  // (active rows only) to pick where a finished batch is stored. Every row
  // returns `used_qty` / `free_qty` from the assignment ledger, so the picker
  // shows remaining room without a round trip per location.
  //
  // Capacity is enforced server-side under a row lock on the location — the
  // client figure is only there to keep the list honest.
  // ---------------------------------------------------------------------------
  static const String managerLocations = '/manager/locations';
  static const String qaLocations = '/qa/locations';

  static String managerLocationById(int id) => '/manager/locations/$id';
  static String managerLocationContents(int id) =>
      '/manager/locations/$id/contents';
  static String qaPlanItemLocation(int planItemId) =>
      '/qa/plan-items/$planItemId/location';
}

/// Allowed `context` values for the identity-verify endpoint.
class DplIdentityContext {
  static const String login = 'login';
  static const String planAccess = 'plan_access';
  static const String itemStart = 'item_start';
  static const String downtimeStart = 'downtime_start';
}

/// Backend status values for production plans.
class DplPlanStatus {
  static const String draft = 'draft';
  static const String published = 'published';
  static const String inProgress = 'in_progress';
  static const String completed = 'completed';
  static const String locked = 'locked';

  static const List<String> all = <String>[
    draft,
    published,
    inProgress,
    completed,
    locked,
  ];

  static String label(String status) {
    switch (status) {
      case draft:
        return 'Draft';
      case published:
        return 'Published';
      case inProgress:
        return 'In Progress';
      case completed:
        return 'Completed';
      case locked:
        return 'Locked';
      default:
        return status.isEmpty
            ? '-'
            : status[0].toUpperCase() + status.substring(1);
    }
  }

  /// Per backend update (2026-05-21): manager can edit a plan in ANY
  /// status except locked. Backend returns INVALID_STATUS for locked.
  static bool isEditable(String status) => status != locked;

  static bool isLockable(String status) =>
      status == published || status == inProgress;

  static bool isDeletable(String status) => status == draft;

  /// Read-only is now equivalent to locked. Use the change-status
  /// endpoint to move out of locked before editing.
  static bool isReadOnly(String status) => status == locked;
}

/// Downtime-reason categories.
class DplDowntimeCategory {
  static const String planned = 'planned';
  static const String unplanned = 'unplanned';

  static const List<String> all = <String>[planned, unplanned];

  static String label(String category) {
    switch (category) {
      case planned:
        return 'Planned';
      case unplanned:
        return 'Unplanned';
      default:
        return category;
    }
  }
}

/// Report export formats supported by the backend.
class DplReportFormat {
  static const String xlsx = 'xlsx';
  static const String pdf = 'pdf';
  static const String csv = 'csv';
}

/// Lifecycle status values for `dpl.dpl_dispatch_slips`.
///
/// Status machine (trip-driven slips):
///   pending_deo → pending_pdi → approved → dispatched
///               ↘ ─── rejected ─── ↙
///
/// `pending_qa` is a legacy/dormant state kept for back-compat (the QA
/// step was removed from the workflow). Trip-driven slips are now cut in
/// `pending_deo` so the Dispatch DEO can stamp an invoice no before they
/// reach PDI.
class DplDispatchSlipStatus {
  static const String pendingQa = 'pending_qa';
  static const String pendingDeo = 'pending_deo';
  static const String pendingPdi = 'pending_pdi';
  static const String approved = 'approved';
  static const String dispatched = 'dispatched';
  static const String rejected = 'rejected';

  static const List<String> all = <String>[
    pendingQa,
    pendingDeo,
    pendingPdi,
    approved,
    dispatched,
    rejected,
  ];

  /// Short, user-facing label.
  static String label(String status) {
    switch (status) {
      case pendingQa:
        return 'Pending QA';
      case pendingDeo:
        return 'Pending DEO';
      case pendingPdi:
        return 'Pending PDI';
      case approved:
        return 'Approved';
      case dispatched:
        return 'Dispatched';
      case rejected:
        return 'Rejected';
      default:
        if (status.isEmpty) return '-';
        return status[0].toUpperCase() + status.substring(1);
    }
  }

  /// True while the slip is still moving through the approval pipeline.
  static bool isOpen(String status) =>
      status == pendingQa || status == pendingDeo || status == pendingPdi;

  /// True once both quality gates have signed off (QR is populated).
  static bool isApproved(String status) => status == approved;

  /// True once stock has physically left the plant.
  static bool isClosed(String status) =>
      status == dispatched || status == rejected;
}

/// Default copy used in the upload-plan form.
class DplDefaults {
  static const String planReleasedBy = 'Vistar Logitek Pvt. Ltd.';
  static const String planApprovedBy = 'Grupo Antolin India Pvt. Ltd';
}
