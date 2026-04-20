/// Shared message types for Drift web configuration.
library;

import '../drift_options.dart';

/// Message to transfer Drift storage settings from main thread to worker.
///
/// Carries both the web platform configuration and storage-level settings
/// (such as [deduplicateOnLoad]) so the worker can initialise [DriftStorage]
/// with the same parameters the app developer configured on the main thread.
class DriftSettingsMessage {
  final LocordaDriftWebOptions? webOptions;
  final bool deduplicateOnLoad;

  DriftSettingsMessage({
    required this.webOptions,
    required this.deduplicateOnLoad,
  });

  Map<String, dynamic> toJson() => {
        'type': 'DriftSettingsMessage',
        'hasWebOptions': webOptions != null,
        if (webOptions != null) ...{
          'sqlite3Wasm': webOptions!.sqlite3Wasm.toString(),
          'driftWorker': webOptions!.driftWorker.toString(),
        },
        'deduplicateOnLoad': deduplicateOnLoad,
      };

  static DriftSettingsMessage fromJson(Map<String, dynamic> json) {
    final hasWebOptions = json['hasWebOptions'] == true;
    final deduplicateOnLoad = json['deduplicateOnLoad'] as bool? ?? false;

    LocordaDriftWebOptions? webOptions;
    if (hasWebOptions) {
      webOptions = LocordaDriftWebOptions(
        sqlite3Wasm: Uri.parse(json['sqlite3Wasm'] as String),
        driftWorker: Uri.parse(json['driftWorker'] as String),
      );
    }

    return DriftSettingsMessage(
      webOptions: webOptions,
      deduplicateOnLoad: deduplicateOnLoad,
    );
  }
}
