/// The Vistar Workspace portal account.
///
/// Signing in on the login form with these credentials skips the backend
/// (and the organization picker) and opens the app launcher (`/apps`)
/// instead of a production dashboard. The account exists purely to reach the launcher;
/// it has no production data access and makes no authenticated API calls.
///
/// ## Security caveat
///
/// The password below ships inside the compiled bundle — anyone who can
/// load the web app can extract it. That is acceptable only because this
/// account unlocks nothing but a page of public links. Do **not** attach
/// any real permission to it.
///
/// The moment the backend can issue a `VISTAR_WORKSPACE` role, delete
/// [matches] and let the normal `/dpl/auth/login` path return that role; the
/// router and launcher already key off the role, not off this class.
class VistarWorkspaceAccount {
  const VistarWorkspaceAccount._();

  /// Email typed on the login form.
  static const String username = 'prashant.tamhankar@vistarlogitek.com';

  /// Name shown on the launcher's user chip.
  static const String displayName = 'Prashant Tamhankar';

  /// The portal password.
  ///
  /// Public only because the launcher has to re-derive it after a browser
  /// refresh drops the in-memory copy (see
  /// `services/workspace_credentials.dart`). Exposing it costs nothing
  /// that shipping it in the bundle hadn't already given away — but it is
  /// the clearest possible marker of why this account must stay
  /// permission-free until the backend issues the role instead.
  static const String knownPassword = '12345678';

  /// Placeholder session id / token. Never sent to the Vistar backend —
  /// the launcher issues no authenticated requests — but the auth
  /// controller requires a non-empty token to consider a session live.
  static const String userId = 'vistar-workspace';
  static const String localSessionToken = 'vistar-workspace-local-session';

  /// Whether the submitted credentials are the portal account's.
  /// The username compare is case-insensitive; the password is not.
  static bool matches(String submittedUsername, String submittedPassword) {
    return submittedUsername.trim().toLowerCase() == username &&
        submittedPassword == knownPassword;
  }
}
