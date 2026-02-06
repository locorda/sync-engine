/// Shared message types for SolidConfig synchronization.
library;

import 'package:locorda_solid_core/locorda_solid_core.dart';

/// Message to send SolidConfig from main thread to worker.
class SolidConfigMessage {
  final SolidConfig config;

  SolidConfigMessage({required this.config});

  Map<String, dynamic> toJson() => {
        'type': 'SolidConfigMessage',
        'config': config.toJson(),
      };

  static SolidConfigMessage fromJson(Map<String, dynamic> json) {
    final configJson = json['config'] as Map<String, dynamic>? ?? const {};
    return SolidConfigMessage(
      config: SolidConfig.fromJson(configJson),
    );
  }
}