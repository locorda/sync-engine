/// Shared message types for DirConfig synchronization.
library;

import 'dir_config.dart';

/// Message to send [DirConfig] from main thread to worker.
class DirConfigMessage {
  final DirConfig config;

  DirConfigMessage({required this.config});

  Map<String, dynamic> toJson() => {
        'type': 'DirConfigMessage',
        'contentType': config.contentType,
        'datasetContentType': config.datasetContentType,
        'useShardDatasets': config.useShardDatasets,
      };

  static DirConfigMessage fromJson(Map<String, dynamic> json) {
    return DirConfigMessage(
      config: DirConfig(
        contentType: json['contentType'] as String?,
        datasetContentType: json['datasetContentType'] as String?,
        useShardDatasets: json['useShardDatasets'] as bool? ?? false,
      ),
    );
  }
}
