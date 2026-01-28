library;

/// Response message sent from main thread to worker with resolved database paths.
///
/// This is an internal implementation detail shared between sender and receiver.
class ResponseDriftOptionsMessage {
  final String? databaseDirectory;
  final String? tempDirectoryPath;
  final String? databasePath;

  ResponseDriftOptionsMessage({
    this.databaseDirectory,
    this.tempDirectoryPath,
    this.databasePath,
  });

  Map<String, dynamic> toJson() => {
        'type': 'ResponseDriftOptions',
        if (databaseDirectory != null) 'databaseDirectory': databaseDirectory,
        if (tempDirectoryPath != null) 'tempDirectoryPath': tempDirectoryPath,
        if (databasePath != null) 'databasePath': databasePath,
      };

  factory ResponseDriftOptionsMessage.fromJson(Map<String, dynamic> json) {
    return ResponseDriftOptionsMessage(
      databaseDirectory: json['databaseDirectory'] as String?,
      tempDirectoryPath: json['tempDirectoryPath'] as String?,
      databasePath: json['databasePath'] as String?,
    );
  }
}
