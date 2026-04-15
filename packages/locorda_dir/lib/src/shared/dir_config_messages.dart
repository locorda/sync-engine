/// Shared message types for DirConfig synchronization.
library;

import 'package:locorda_core/locorda_core.dart';

import 'dir_config.dart';

/// Message to send [DirConfig] from main thread to worker.
class DirConfigMessage {
  final DirConfig config;

  DirConfigMessage({required this.config});

  Map<String, dynamic> toJson() => {
        'type': 'DirConfigMessage',
        'layout': config.layout.toJson(),
      };

  static DirConfigMessage fromJson(Map<String, dynamic> json) {
    final layoutJson = json['layout'] as Map<String, dynamic>? ??
        const {'type': 'filePerResource'};
    return DirConfigMessage(
      config: DirConfig(
        layout: RemoteStorageLayout.fromJson(layoutJson),
      ),
    );
  }
}
