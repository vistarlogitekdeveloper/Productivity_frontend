import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/local_storage_repository.dart';
import 'dpl_api_service.dart';

/// What the logged-in DPL user is allowed to do (backend migration 148).
///
/// THIS DECIDES WHAT TO SHOW, NEVER WHAT TO ALLOW. Every endpoint re-checks
/// the same permission server-side, so a stale or tampered copy here can hide
/// a control the user should have had — an annoyance — but can never grant one
/// they should not. Treat it accordingly: use it for visibility and for
/// choosing a landing screen, and do not use it in place of a server check.
class DplPermissions {
  /// The granted keys, or `null` when the server never sent any.
  ///
  /// The distinction matters and is the reason this is not just a Set. `null`
  /// means "this API predates permissions, or the lookup failed" — the app
  /// falls back to its role checks and behaves exactly as it did before.
  /// An empty set means the server answered and the answer was "nothing",
  /// which must be obeyed.
  final Set<String>? _granted;

  /// No answer from the server. [can] returns true for everything so screens
  /// fall back to their existing role checks rather than blanking out.
  const DplPermissions.unknown() : _granted = null;

  DplPermissions.of(Iterable<String> keys) : _granted = Set.unmodifiable(keys);

  /// True when the server has told us what this user may do.
  bool get isKnown => _granted != null;

  /// Whether the user holds [key].
  ///
  /// WHEN THE ANSWER IS UNKNOWN, THE FALLBACK DEPENDS ON THE KEY.
  ///
  /// "Unknown" means "behave as this app did before permissions existed".
  /// For a capability that has always been there and was guarded by a role
  /// check, that means ALLOW: an app that renders nothing the first time it
  /// meets an older backend is a worse failure than showing a control whose
  /// endpoint will refuse it with a clear message.
  ///
  /// But for a capability that did NOT exist before — every Maxion one —
  /// behaving as before means NOT SHOWING IT. Those are listed in
  /// [DplPermission.optInOnly] and are denied while the answer is unknown.
  /// Without that split, any moment the list goes unknown (an older backend, a
  /// failed `/auth/me`, a session cached from an earlier build) hands a plant
  /// the entire Maxion feature set that its administrator never switched on.
  bool can(String key) {
    if (_granted == null) return !DplPermission.optInOnly.contains(key);
    return _granted.contains(key);
  }

  /// True when the user holds at least one of [keys].
  bool canAny(Iterable<String> keys) {
    for (final k in keys) {
      if (can(k)) return true;
    }
    return false;
  }

  /// True when the user holds every one of [keys].
  bool canAll(Iterable<String> keys) {
    for (final k in keys) {
      if (!can(k)) return false;
    }
    return true;
  }

  /// The granted keys, empty when unknown. For display only.
  Set<String> get keys => _granted ?? const <String>{};
}

/// Holds [DplPermissions] for the session.
///
/// Hydrated from local storage at app start so the first frame after a restart
/// already knows what to show, then refreshed from `/auth/me` whenever a
/// screen wants to be sure. Written by the auth controller on login.
class DplPermissionsController extends Notifier<DplPermissions> {
  @override
  DplPermissions build() {
    final cached = ref.read(localStorageRepositoryProvider).getDplPermissions();
    if (cached == null) return const DplPermissions.unknown();
    return DplPermissions.of(cached);
  }

  /// Replaces the cached permissions and persists them.
  ///
  /// A null [keys] means the server said nothing about permissions, which is
  /// stored as "unknown" rather than as "none" — writing an empty list would
  /// lock an older backend's users out of their own screens.
  Future<void> set(List<String>? keys) async {
    final prefs = ref.read(localStorageRepositoryProvider);
    if (keys == null) {
      state = const DplPermissions.unknown();
      await prefs.clearDplPermissions();
      return;
    }
    state = DplPermissions.of(keys);
    await prefs.saveDplPermissions(keys);
  }

  Future<void> clear() async {
    state = const DplPermissions.unknown();
    await ref.read(localStorageRepositoryProvider).clearDplPermissions();
  }

  /// Best-effort re-read from `/auth/me`.
  ///
  /// Worth calling after an administrator has changed the grid, and on
  /// entering a screen whose contents depend on a permission that may have
  /// moved. Silently no-ops on a network error: the cached set keeps
  /// rendering, and the server is still the one enforcing.
  Future<void> refresh() async {
    final res = await ref.read(dplApiServiceProvider).me();
    if (res.isError) return;
    await set(res.data?.permissions);
  }
}

final dplPermissionsProvider =
    NotifierProvider<DplPermissionsController, DplPermissions>(
  DplPermissionsController.new,
);

/// Every permission key the app checks, so a typo is a compile error rather
/// than a silently-denied screen.
///
/// Must stay in step with `src/modules/dpl/config/permissions.js` on the
/// backend — that file is the authority, and a key here that does not exist
/// there will simply never be granted.
class DplPermission {
  static const String usersView = 'admin.users.view';
  static const String usersManage = 'admin.users.manage';
  static const String orgsView = 'admin.orgs.view';
  static const String orgsManage = 'admin.orgs.manage';
  static const String permissionsManage = 'admin.permissions.manage';
  static const String auditView = 'admin.audit.view';

  static const String mastersView = 'masters.view';
  static const String mastersEdit = 'masters.edit';
  static const String locationsEdit = 'masters.locations.edit';

  static const String plansView = 'plans.view';
  static const String plansCreate = 'plans.create';
  static const String plansEdit = 'plans.edit';
  static const String plansDelete = 'plans.delete';
  static const String plansLock = 'plans.lock';
  static const String plansExecute = 'plans.execute';

  static const String labelsScan = 'labels.scan';
  static const String labelsPrint = 'labels.print';

  /// Enter a quantity and issue a whole batch, instead of one label per press.
  ///
  /// Off for every role by default, and granted per ORGANIZATION: a plant that
  /// sticks each label on the part in front of the operator works one at a
  /// time, a plant that packs a pallet needs the quantity field. The server
  /// re-checks this on every issue, so hiding the field is presentation only.
  static const String labelsPrintBatch = 'labels.print_batch';

  /// Pallet build and close (Maxion SSR Module 4). Granted by default to the
  /// roles that print labels, because the SSR gives the wheel QR and the
  /// pallet to the same pack point operator.
  /// The register. Read-only and separate from building, so a plant can let
  /// dispatch browse what is packed without letting them pack one.
  static const String palletView = 'pallet.view';
  static const String palletBuild = 'pallet.build';
  static const String palletClose = 'pallet.close';
  static const String palletMerge = 'pallet.merge';
  /// Record which rack a closed pallet is stored on — SSR Module 6. Separate
  /// from building and closing because which role racks a pallet differs by
  /// plant: the pack operator at a small site, a dedicated putaway operator
  /// with a handheld at Maxion.
  static const String palletPutaway = 'pallet.putaway';

  /// Take named wheels off a closed pallet and label each one as an individual
  /// spare-parts pack — SSR §8. Its own key because converting stock for a
  /// customer order is a different authority from packing or storing it.
  static const String palletSpd = 'pallet.spd';

  /// Accept wheel stickers printed by the plant's OTHER system during the
  /// changeover. Its own key because it is meant to be switched OFF again
  /// once every part prints from this app.
  static const String labelsScanExternal = 'labels.scan_external';

  /// Use the device camera to read wheel labels, instead of a hardware
  /// scanner or typing the serial. Separate so a plant issuing ring scanners
  /// can revoke it without touching the operator's ability to pack.
  static const String palletScanCamera = 'pallet.scan_camera';
  static const String labelsVoid = 'labels.void';
  static const String labelsAssignLocation = 'labels.assign_location';

  static const String tripsView = 'trips.view';
  static const String tripsCreate = 'trips.create';
  static const String tripsCancel = 'trips.cancel';
  static const String tripsAssignDriver = 'trips.assign_driver';
  static const String tripsScanLabels = 'trips.scan_labels';

  static const String slipsView = 'slips.view';
  static const String slipsCreate = 'slips.create';
  static const String slipsDeo = 'slips.deo';
  static const String slipsPdi = 'slips.pdi';
  static const String slipsDispatch = 'slips.dispatch';

  static const String journeyGate = 'journey.gate';
  static const String journeyCustomer = 'journey.customer';
  static const String journeyDrive = 'journey.drive';

  static const String summaryView = 'summary.view';
  static const String reportsView = 'reports.view';

  /// Anything that opens the Administration panel.
  static const List<String> adminPanel = <String>[
    usersView,
    orgsView,
    permissionsManage,
  ];

  /// The capabilities the Maxion integration ADDED, for which an unknown
  /// permission list must mean DENIED rather than allowed.
  ///
  /// The rule these encode is the product rule: the existing DPL flow keeps
  /// working exactly as it did, and every Maxion capability is something an
  /// administrator switches on, per organization. A plant that has never been
  /// given one of these must never see it — and "the app could not read the
  /// permission list" is not a reason to show it.
  ///
  /// Add a key here whenever a NEW capability is introduced. Leave the
  /// PRE-EXISTING DPL keys out: those mirror role guards that already shipped,
  /// so denying them on an unknown list would blank out screens people use
  /// today the first time `/auth/me` hiccups.
  static const Set<String> optInOnly = <String>{
    // Maxion SSR §5.2 — a quantity field instead of one label per press.
    labelsPrintBatch,
    // Maxion SSR Module 4 and 5 — the pack point, the register, the sticker.
    palletView,
    palletBuild,
    palletClose,
    palletMerge,
    palletScanCamera,
    palletPutaway,
    palletSpd,
    labelsScanExternal,
  };
}

