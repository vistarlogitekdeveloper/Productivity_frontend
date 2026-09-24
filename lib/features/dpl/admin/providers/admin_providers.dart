/// Providers behind the Administration panel (backend migration 148).
///
/// All hand-written Notifiers rather than StateProvider: Riverpod 3 dropped
/// the latter, and every DPL provider in this codebase is written without
/// codegen.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dpl_api_response.dart';
import '../../core/dpl_api_service.dart';
import '../../models/dpl_admin.dart';

// ---------------------------------------------------------------------------
// Small state holders
// ---------------------------------------------------------------------------

/// A nullable-int filter. Public, not private, because the provider's type
/// argument is what makes `.notifier.set(...)` visible at the call site — a
/// `NotifierProvider<Notifier<int?>, int?>` exposes only the base class.
class AdminIntFilter extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? value) => state = value;
}

class AdminStringFilter extends Notifier<String> {
  final String _initial;

  AdminStringFilter([this._initial = '']);

  @override
  String build() => _initial;

  void set(String value) => state = value;
}

/// Which organization the Users tab is filtered to. `null` means "every
/// organization", which is the default: an administrator who could only see
/// their own tenant could not move somebody between two.
final adminUserOrgFilterProvider =
    NotifierProvider<AdminIntFilter, int?>(AdminIntFilter.new);

final adminUserSearchProvider =
    NotifierProvider<AdminStringFilter, String>(AdminStringFilter.new);

/// 'all' | 'active' | 'disabled'.
final adminUserStatusProvider = NotifierProvider<AdminStringFilter, String>(
  () => AdminStringFilter('all'),
);

/// A role key, or empty for every role.
final adminUserRoleProvider = NotifierProvider<AdminStringFilter, String>(
  () => AdminStringFilter(''),
);

/// Which organization's access rules the Access tab is showing. `null` means
/// the caller's own, which is what the backend defaults to.
final adminPermissionOrgProvider =
    NotifierProvider<AdminIntFilter, int?>(AdminIntFilter.new);

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

/// The role list and permission catalogue.
///
/// keepAlive by omission of autoDispose would be wrong here — but so would
/// re-fetching it on every tab switch, so it is deliberately a plain
/// FutureProvider: the catalogue only changes when the backend is redeployed.
final adminCatalogueProvider =
    FutureProvider<DplApiResponse<DplPermissionMatrix>>((ref) async {
  return ref.watch(dplApiServiceProvider).getAdminCatalogue();
});

final adminUsersProvider =
    FutureProvider.autoDispose<DplApiResponse<DplManagedUserPage>>((ref) async {
  final orgId = ref.watch(adminUserOrgFilterProvider);
  final q = ref.watch(adminUserSearchProvider);
  final status = ref.watch(adminUserStatusProvider);
  final role = ref.watch(adminUserRoleProvider);

  return ref.watch(dplApiServiceProvider).getAdminUsers(
        organizationId: orgId,
        q: q,
        role: role.isEmpty ? null : role,
        status: status,
        limit: 200,
      );
});

/// Every organization, including the inactive ones — this is the one screen
/// that must show them, otherwise a tenant switched off by mistake can never
/// be switched back on.
final adminOrganizationsProvider =
    FutureProvider.autoDispose<DplApiResponse<List<DplAdminOrganization>>>(
        (ref) async {
  return ref
      .watch(dplApiServiceProvider)
      .getAdminOrganizations(includeInactive: true);
});

final adminPermissionMatrixProvider =
    FutureProvider.autoDispose<DplApiResponse<DplPermissionMatrix>>((ref) async {
  final orgId = ref.watch(adminPermissionOrgProvider);
  return ref.watch(dplApiServiceProvider).getAdminPermissions(
        organizationId: orgId,
      );
});

final adminAuditProvider =
    FutureProvider.autoDispose<DplApiResponse<List<DplUserAuditEntry>>>(
        (ref) async {
  return ref.watch(dplApiServiceProvider).getAdminAudit(limit: 100);
});
