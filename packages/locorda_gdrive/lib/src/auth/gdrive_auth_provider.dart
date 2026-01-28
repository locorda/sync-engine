import 'package:locorda_core/locorda_core.dart';

/// Authentication provider interface for Google Drive backend.
///
/// Provides OAuth2-based authentication for accessing Google Drive API.
/// Unlike Solid's DPoP, Google Drive uses standard Bearer token authentication.
abstract interface class GDriveAuthProvider implements Auth {
  /// Gets the current OAuth2 access token for API requests.
  ///
  /// Returns a valid access token that can be used in HTTP Authorization header:
  /// ```dart
  /// headers: {'Authorization': 'Bearer ${await auth.getAccessToken()}'}
  /// ```
  ///
  /// The implementation handles token refresh automatically if the token has expired.
  ///
  /// Throws if user is not authenticated.
  Future<String> getAccessToken();

  /// The email address of the authenticated Google user.
  ///
  /// Returns null if not authenticated.
  String? get userEmail;

  /// Refreshes the OAuth2 access token.
  ///
  /// Called by [GDriveBackend] when an HTTP request receives 401 Unauthorized,
  /// indicating the access token has expired.
  ///
  /// ## Parameters
  ///
  /// - [reason]: Optional context about why refresh is needed (for debugging)
  ///
  /// ## Implementation Notes
  ///
  /// - **Main thread** ([GDriveAuth]): Uses googleapis_auth to refresh
  /// - **Worker thread** ([WorkerGDriveAuthProvider]): Sends request to main
  ///   thread and waits for fresh credentials
  ///
  /// ## Throws
  ///
  /// May throw if refresh fails (e.g., refresh token expired, network error).
  Future<void> refreshToken({String? reason});
}
