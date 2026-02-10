/// Shared message types for Drift web configuration.
library;

import '../drift_options.dart';

/// Message to send Drift web options from main thread to worker.
class DriftWebOptionsMessage {
  final LocordaDriftWebOptions? options;

  DriftWebOptionsMessage({required this.options});

  Map<String, dynamic> toJson() => {
        'type': 'DriftWebOptionsMessage',
        'hasOptions': options != null,
        if (options != null) ...{
          'sqlite3Wasm': options!.sqlite3Wasm.toString(),
          'driftWorker': options!.driftWorker.toString(),
        },
      };

  static DriftWebOptionsMessage fromJson(Map<String, dynamic> json) {
    final hasOptions = json['hasOptions'] == true;
    if (!hasOptions) {
      return DriftWebOptionsMessage(options: null);
    }
    final sqlite3Wasm = Uri.parse(json['sqlite3Wasm'] as String);
    final driftWorker = Uri.parse(json['driftWorker'] as String);
    return DriftWebOptionsMessage(
      options: LocordaDriftWebOptions(
        sqlite3Wasm: sqlite3Wasm,
        driftWorker: driftWorker,
      ),
    );
  }
}
