/// Worker message protocol for local directory authentication.
library;

/// Base class for authentication messages between main thread and worker.
sealed class DirAuthMessage {
  Map<String, dynamic> toJson();

  static DirAuthMessage fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    switch (type) {
      case 'UpdateAuthMessage':
        return UpdateAuthMessage.fromJson(json);
      case 'RequestAuthStateMessage':
        return RequestAuthStateMessage.fromJson(json);
      default:
        throw ArgumentError('Unknown message type: $type');
    }
  }
}

/// Message to update authentication state in worker.
///
/// Sent from main thread when:
/// - Sync is enabled (enabled == true)
/// - Sync is disabled (enabled == false)
class UpdateAuthMessage extends DirAuthMessage {
  final bool enabled;
  final String syncDirectoryPath;

  UpdateAuthMessage({
    required this.enabled,
    required this.syncDirectoryPath,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'UpdateAuthMessage',
        'enabled': enabled,
        'syncDirectoryPath': syncDirectoryPath,
      };

  factory UpdateAuthMessage.fromJson(Map<String, dynamic> json) {
    return UpdateAuthMessage(
      enabled: json['enabled'] as bool,
      syncDirectoryPath: json['syncDirectoryPath'] as String,
    );
  }
}

/// Message to request current auth state from main thread.
///
/// Sent from worker on startup to get initial state.
class RequestAuthStateMessage extends DirAuthMessage {
  RequestAuthStateMessage();

  @override
  Map<String, dynamic> toJson() => {
        'type': 'RequestAuthStateMessage',
      };

  factory RequestAuthStateMessage.fromJson(Map<String, dynamic> json) {
    return RequestAuthStateMessage();
  }
}
