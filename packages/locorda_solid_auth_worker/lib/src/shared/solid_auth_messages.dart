/// Solid-specific authentication messages for worker communication.
///
/// Defines message types for transmitting authentication state and credentials
/// from main thread to worker isolate via [WorkerChannel].
library;

import 'package:solid_auth/worker.dart';

/// Message to update authentication credentials in worker.
///
/// Sent from main thread's [SolidAuthConnector] to worker's
/// [WorkerSolidAuthProvider] when authentication state changes.
///
/// - When user logs in: Contains [credentials] and [webId]
/// - When user logs out: Contains `null` credentials to clear worker state
class UpdateAuthMessage {
  /// DPoP credentials for authenticated requests.
  ///
  /// `null` means user is logged out and worker should clear auth state.
  final DpopCredentials? credentials;

  /// Authenticated user's WebID.
  ///
  /// Stored separately from DPoP credentials for backend initialization.
  final String? webId;

  /// Creates update message with optional [credentials] and [webId].
  UpdateAuthMessage({required this.credentials, this.webId});

  /// Serializes to JSON for transmission over channel.
  Map<String, dynamic> toJson() => {
        'type': 'UpdateAuthMessage',
        if (credentials != null) 'credentials': credentials!.toJson(),
        if (webId != null) 'webId': webId,
      };

  /// Deserializes from JSON received on channel.
  factory UpdateAuthMessage.fromJson(Map<String, dynamic> json) {
    final credentialsJson = json['credentials'] as Map<String, dynamic>?;
    return UpdateAuthMessage(
      credentials: credentialsJson != null
          ? DpopCredentials.fromJson(credentialsJson)
          : null,
      webId: json['webId'] as String?,
    );
  }
}

/// Message requesting token refresh from main thread.
///
/// Sent from worker's [WorkerSolidAuthProvider] when:
/// - HTTP request receives 401 Unauthorized
/// - Worker detects token might be expired
///
/// Main thread responds with [UpdateAuthMessage] containing fresh credentials.
class RequestTokenRefreshMessage {
  /// Optional context about why refresh is requested (for debugging).
  final String? reason;

  /// Creates refresh request with optional [reason].
  const RequestTokenRefreshMessage({this.reason});

  /// Serializes to JSON for transmission over channel.
  Map<String, dynamic> toJson() => {
        'type': 'RequestTokenRefresh',
        if (reason != null) 'reason': reason,
      };

  /// Deserializes from JSON received on channel.
  factory RequestTokenRefreshMessage.fromJson(Map<String, dynamic> json) {
    return RequestTokenRefreshMessage(
      reason: json['reason'] as String?,
    );
  }
}

/// Message requesting initial auth state from main thread.
///
/// Sent once by [WorkerSolidAuthProvider] on initialization to get
/// current authentication state before any auth changes occur.
class RequestAuthStateMessage {
  /// Creates auth state request.
  const RequestAuthStateMessage();

  /// Serializes to JSON for transmission over channel.
  Map<String, dynamic> toJson() => {
        'type': 'RequestAuthState',
      };

  /// Deserializes from JSON received on channel.
  factory RequestAuthStateMessage.fromJson(Map<String, dynamic> json) {
    return const RequestAuthStateMessage();
  }
}
