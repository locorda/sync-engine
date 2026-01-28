/// Worker message protocol for Google Drive authentication.
library;

/// Base class for authentication messages between main thread and worker.
sealed class GDriveAuthMessage {
  Map<String, dynamic> toJson();

  static GDriveAuthMessage fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    switch (type) {
      case 'UpdateAuthMessage':
        return UpdateAuthMessage.fromJson(json);
      case 'RequestAuthStateMessage':
        return RequestAuthStateMessage.fromJson(json);
      case 'TokenRefreshRequest':
        return TokenRefreshRequest.fromJson(json);
      case 'TokenRefreshResponse':
        return TokenRefreshResponse.fromJson(json);
      default:
        throw ArgumentError('Unknown message type: $type');
    }
  }
}

/// Message to update authentication state in worker.
///
/// Sent from main thread when:
/// - User logs in (credentials != null)
/// - User logs out (credentials == null)
/// - Token is refreshed (new access token)
class UpdateAuthMessage extends GDriveAuthMessage {
  final String? accessToken;
  final String? refreshToken;
  final String? userEmail;
  final DateTime? expiresAt;

  UpdateAuthMessage({
    this.accessToken,
    this.refreshToken,
    this.userEmail,
    this.expiresAt,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'UpdateAuthMessage',
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'userEmail': userEmail,
        'expiresAt': expiresAt?.toIso8601String(),
      };

  factory UpdateAuthMessage.fromJson(Map<String, dynamic> json) {
    return UpdateAuthMessage(
      accessToken: json['accessToken'] as String?,
      refreshToken: json['refreshToken'] as String?,
      userEmail: json['userEmail'] as String?,
      expiresAt: json['expiresAt'] != null
          ? DateTime.parse(json['expiresAt'] as String)
          : null,
    );
  }
}

/// Message requesting current auth state from main thread.
///
/// Sent by worker on startup to initialize authentication state.
class RequestAuthStateMessage extends GDriveAuthMessage {
  RequestAuthStateMessage();

  @override
  Map<String, dynamic> toJson() => {
        'type': 'RequestAuthStateMessage',
      };

  factory RequestAuthStateMessage.fromJson(Map<String, dynamic> json) {
    return RequestAuthStateMessage();
  }
}

/// Message requesting token refresh from main thread.
///
/// Sent by worker when access token has expired (401 response).
class TokenRefreshRequest extends GDriveAuthMessage {
  final int requestId;
  final String? reason;

  TokenRefreshRequest({
    required this.requestId,
    this.reason,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'TokenRefreshRequest',
        'requestId': requestId,
        'reason': reason,
      };

  factory TokenRefreshRequest.fromJson(Map<String, dynamic> json) {
    return TokenRefreshRequest(
      requestId: json['requestId'] as int,
      reason: json['reason'] as String?,
    );
  }
}

/// Response to token refresh request.
///
/// Sent from main thread after successfully refreshing the access token.
class TokenRefreshResponse extends GDriveAuthMessage {
  final int requestId;
  final String? accessToken;
  final DateTime? expiresAt;
  final String? error;

  TokenRefreshResponse({
    required this.requestId,
    this.accessToken,
    this.expiresAt,
    this.error,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'TokenRefreshResponse',
        'requestId': requestId,
        'accessToken': accessToken,
        'expiresAt': expiresAt?.toIso8601String(),
        'error': error,
      };

  factory TokenRefreshResponse.fromJson(Map<String, dynamic> json) {
    return TokenRefreshResponse(
      requestId: json['requestId'] as int,
      accessToken: json['accessToken'] as String?,
      expiresAt: json['expiresAt'] != null
          ? DateTime.parse(json['expiresAt'] as String)
          : null,
      error: json['error'] as String?,
    );
  }
}
