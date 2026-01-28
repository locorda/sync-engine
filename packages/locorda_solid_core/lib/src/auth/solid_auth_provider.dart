import 'package:locorda_core/locorda_core.dart';

abstract interface class SolidAuthProvider implements Auth {
  /// Generates a DPoP (Demonstration of Proof-of-Possession) token for API requests.
  ///
  /// DPoP tokens are required by Solid servers to prove that the client making
  /// an API request is the same client that was issued the access token. This
  /// prevents token theft and replay attacks.
  ///
  /// ## Parameters
  ///
  /// - [url]: The complete URL of the API endpoint you're about to call
  /// - [method]: The HTTP method ('GET', 'POST', 'PUT', 'DELETE', etc.)
  ///
  /// ## Return Value
  ///
  /// Returns a [DPoP] object containing:
  /// - `dpopToken`: The DPoP JWT token
  /// - `accessToken`: The OAuth2 access token
  /// - `httpHeaders()`: Convenience method to get properly formatted HTTP headers
  ///
  /// ## Example
  /// ```dart
  /// // Generate DPoP token for a GET request
  /// final dpop = solidAuth.genDpopToken(
  ///   'https://alice.solidcommunity.net/profile/card',
  ///   'GET'
  /// );
  ///
  /// // Use with HTTP client
  /// final response = await http.get(
  ///   Uri.parse('https://alice.solidcommunity.net/profile/card'),
  ///   headers: {
  ///     ...dpop.httpHeaders(),
  ///     'Content-Type': 'text/turtle',
  ///   },
  /// );
  ///
  /// // Or set headers manually
  /// final response = await http.get(
  ///   Uri.parse('https://alice.solidcommunity.net/profile/card'),
  ///   headers: {
  ///     'Authorization': 'DPoP ${dpop.accessToken}',
  ///     'DPoP': dpop.dpopToken,
  ///     'Content-Type': 'text/turtle',
  ///   },
  /// );
  /// ```
  ///
  /// ## Requirements
  ///
  /// - User must be authenticated (call [authenticate] first)
  /// - The URL must be the exact URL you're going to call
  /// - The method must match the actual HTTP method used
  /// - Each DPoP token can only be used once for the specific URL/method combination
  ///
  /// ## Security Notes
  ///
  /// - DPoP tokens are tied to the specific URL and HTTP method
  /// - Each token includes a unique nonce and timestamp
  /// - Tokens should be generated immediately before making the API call
  /// - Never reuse DPoP tokens across different requests
  ///
  /// ## Throws
  ///
  /// Throws an exception if no user is currently authenticated.
  Future<({String accessToken, String dPoP})> getDpopToken(
      String url, String method);
  String? get currentWebId;

  /// Refreshes the authentication token.
  ///
  /// Called by [SolidBackend] when an HTTP request receives 401 Unauthorized,
  /// indicating the access token has expired. Implementations should request
  /// fresh credentials from the authentication provider.
  ///
  /// ## Parameters
  ///
  /// - [reason]: Optional context about why refresh is needed (for debugging)
  ///
  /// ## Implementation Notes
  ///
  /// - **Main thread** ([SolidAuthBridge]): Can call `solid_auth.genDpopToken()`
  ///   which internally handles token refresh
  /// - **Worker thread** ([WorkerSolidAuthProvider]): Sends request to main
  ///   thread and waits for fresh credentials
  ///
  /// ## Throws
  ///
  /// May throw if refresh fails (e.g., refresh token expired, network error).
  Future<void> refreshToken({String? reason});
}
