/// A sign-in or password-change failure whose [message] is already fit to
/// show the user as-is.
class AuthException implements Exception {
  final String message;

  const AuthException(this.message);

  @override
  String toString() => message;
}
