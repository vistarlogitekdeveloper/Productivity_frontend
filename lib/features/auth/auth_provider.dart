import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../core/constants/app_constants.dart';
import '../../data/models/user_model.dart';
import '../../data/repositories/local_storage_repository.dart';
import '../dpl/core/dpl_api_service.dart';
import '../dpl/core/dpl_organization_provider.dart';
import '../dpl/core/dpl_password_gate_provider.dart';
import '../dpl/core/dpl_permissions_provider.dart';
import '../workspace/services/workspace_credentials.dart';
import '../workspace/workspace_account.dart';
import 'auth_exception.dart';

part 'auth_provider.g.dart';

@Riverpod(keepAlive: true)
class AuthController extends _$AuthController {
  @override
  FutureOr<UserModel?> build() async {
    // Server-side session invalidation (401 / ORG_MISMATCH) is handled by
    // the DPL Dio interceptor, which calls [logout] directly.

    // Init block: check persisted auth session.
    final prefs = ref.read(localStorageRepositoryProvider);
    final token = prefs.getToken();
    final role = prefs.getUserRole();

    if (token != null && role != null) {
      // A session saved by the retired classic Productivity sign-in
      // (role ADMIN / SUPERVISOR / BRIN / OPERATOR). Its token is for a
      // backend that now answers 410 Gone, and no screen here serves those
      // roles any more, so sign it out instead of restoring it: wipe the
      // person-scoped prefs (device-scoped keys survive, see
      // [LocalStorageRepository.clearAll]) and come up signed out, which
      // lands on /login. Done once; nothing is left to trigger it again.
      if (!AppConstants.isSupportedSessionRole(role)) {
        await prefs.clearAll();
        return null;
      }

      final id = prefs.getUserId() ?? '';
      final username = prefs.getUsername() ?? '';
      final name = prefs.getUserName() ?? '';

      return UserModel(
        id: id,
        username: username,
        name: name,
        role: role,
      );
    }
    return null;
  }

  /// Opens a local session for the Vistar Workspace portal account. No
  /// network call is made — the launcher only renders links — but the
  /// session is persisted under the same prefs keys as every other role
  /// so a page refresh lands the user back on `/apps`.
  Future<void> _signInToWorkspace(String username, String password) async {
    state = const AsyncValue.loading();
    try {
      // Hold what the user typed, in memory only, so tapping a tile can
      // sign them into that app instead of showing its login form. See
      // [WorkspaceCredentialsStore] for why this is never persisted.
      ref.read(workspaceCredentialsProvider.notifier).set(username, password);

      final prefs = ref.read(localStorageRepositoryProvider);
      await prefs.saveToken(VistarWorkspaceAccount.localSessionToken);
      await prefs.saveUserSession(
        userId: VistarWorkspaceAccount.userId,
        username: VistarWorkspaceAccount.username,
        name: VistarWorkspaceAccount.displayName,
        role: AppConstants.roleVistarWorkspace,
      );

      state = AsyncValue.data(UserModel(
        id: VistarWorkspaceAccount.userId,
        username: VistarWorkspaceAccount.username,
        name: VistarWorkspaceAccount.displayName,
        role: AppConstants.roleVistarWorkspace,
        token: VistarWorkspaceAccount.localSessionToken,
      ));
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
    }
  }

  Future<void> logout() async {
    state = const AsyncValue.loading();
    // Drop the launcher's in-memory credentials first — nothing should
    // outlive the session that could still sign the user into a
    // sibling app.
    ref.read(workspaceCredentialsProvider.notifier).clear();
    final prefs = ref.read(localStorageRepositoryProvider);
    await prefs.clearAll();
    // `clearAll()` already wipes prefs, but the active-org notifier
    // holds the value in memory — null it out so the AppBar pill clears
    // immediately on logout instead of lingering until next app start.
    await ref.read(dplActiveOrganizationProvider.notifier).clear();
    // Same reason as the org snapshot: `clearAll()` wipes prefs, but the
    // notifier still holds the set in memory, so the next login would start
    // from the previous user's permissions until something refreshed it.
    await ref.read(dplPermissionsProvider.notifier).clear();
    await ref.read(dplMustChangePasswordProvider.notifier).clear();
    state = const AsyncValue.data(null);
  }

  /// Logs in against the DPL backend (`/api/v1/dpl/auth/login`) and stores
  /// the returned JWT + user under the same shared-preferences keys the rest
  /// of the app uses. The role is forced to `DPL_MANAGER` if the backend
  /// returns the dpl_manager role in any casing, so the existing router
  /// redirect lands the user on `/dpl/manager`.
  ///
  /// The Vistar Workspace portal account is recognised here too — locally,
  /// and before the network call — so the app launcher stays reachable even
  /// when the backend is down. See [VistarWorkspaceAccount] for the trust
  /// caveat and the path to a server-issued role.
  Future<void> loginDpl(
    String email,
    String password, {
    int? organizationId,
  }) async {
    if (VistarWorkspaceAccount.matches(email, password)) {
      await _signInToWorkspace(email, password);
      return;
    }

    state = const AsyncValue.loading();
    try {
      final svc = ref.read(dplApiServiceProvider);
      final res = await svc.login(email, password, organizationId: organizationId);
      if (res.isError) {
        throw AuthException(res.error ?? 'DPL login failed.');
      }
      final result = res.data;
      final token = result?.token ?? '';
      if (token.isEmpty) {
        throw const AuthException('DPL login succeeded but token is missing.');
      }

      final profile = result?.user;
      final role = (profile?.role.isNotEmpty ?? false)
          ? AppConstants.normalizeRole(profile!.role)
          : AppConstants.roleDplManager;
      // Every role the DPL backend issues has a home here. One that does not
      // would be signed straight back out on the next start (see [build]),
      // so refuse it now, before anything is persisted.
      if (!AppConstants.isSupportedSessionRole(role)) {
        throw AuthException(
          'This account\'s role ($role) is not supported by this app.',
        );
      }
      final userId = (profile?.id ?? 0).toString();
      final username = profile?.email ?? email;
      final name = (profile?.name.isNotEmpty ?? false)
          ? profile!.name
          : (profile?.email ?? email);

      final prefs = ref.read(localStorageRepositoryProvider);
      await prefs.saveToken(token);
      await prefs.saveUserSession(
        userId: userId,
        username: username,
        name: name,
        role: role,
      );

      // Snapshot the active tenant so the AppBar pill renders without
      // an extra /me round-trip. Falls through silently if the backend
      // omitted the org block — it just means no pill until /me is
      // called by `dplActiveOrganizationProvider.refresh()`.
      final org = profile?.organization;
      if (org != null) {
        await ref.read(dplActiveOrganizationProvider.notifier).set(org);
      } else {
        await ref.read(dplActiveOrganizationProvider.notifier).clear();
      }

      // What this user is allowed to do (backend migration 148). Stored so
      // the first frame of the next screen already knows what to render.
      // A null list means the backend predates permissions — it is stored as
      // "unknown", which makes every screen fall back to its role checks
      // rather than rendering nothing at all.
      await ref
          .read(dplPermissionsProvider.notifier)
          .set(profile?.permissions);

      // An administrator created this account, or reset its password, so the
      // value that just got them in is one somebody else knows — including,
      // for a bootstrapped installation, a constant in the repository. The
      // router pins them to /dpl/change-password until this clears.
      await ref
          .read(dplMustChangePasswordProvider.notifier)
          .set(profile?.mustChangePassword ?? false);

      state = AsyncValue.data(UserModel(
        id: userId,
        username: username,
        name: name,
        role: role,
        token: token,
      ));
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
    }
  }
}
