library;

/// Response message sent from main thread to worker with resolved database paths.
///
/// This is an internal implementation detail shared between sender and receiver.
class ResponseDriftOptionsMessage {
  final String? databaseDirectory;
  final String? tempDirectoryPath;
  final String? databasePath;
  final bool enableWal;
  final int readPool;

  ResponseDriftOptionsMessage({
    this.databaseDirectory,
    this.tempDirectoryPath,
    this.databasePath,
    this.enableWal = false,
    this.readPool = 0,
  });

  Map<String, dynamic> toJson() => {
        'type': 'ResponseDriftOptions',
        if (databaseDirectory != null) 'databaseDirectory': databaseDirectory,
        if (tempDirectoryPath != null) 'tempDirectoryPath': tempDirectoryPath,
        if (databasePath != null) 'databasePath': databasePath,
        'enableWal': enableWal,
        'readPool': readPool,
      };

  factory ResponseDriftOptionsMessage.fromJson(Map<String, dynamic> json) {
    return ResponseDriftOptionsMessage(
      databaseDirectory: json['databaseDirectory'] as String?,
      tempDirectoryPath: json['tempDirectoryPath'] as String?,
      databasePath: json['databasePath'] as String?,
      enableWal: json['enableWal'] as bool? ?? false,
      readPool: json['readPool'] as int? ?? 0,
    );
  }
}
