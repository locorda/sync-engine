// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: depend_on_referenced_packages, unused_import

import 'package:locorda_dir/locorda_worker.manifest.dart' as locorda_dir;
import 'package:locorda_drift/locorda_worker.manifest.dart' as locorda_drift;
import 'package:locorda_solid/locorda_worker.manifest.dart' as locorda_solid;
import 'package:locorda_worker/locorda_worker.manifest.dart' as locorda_worker;
import 'package:locorda_worker/worker.dart';
import 'src/generated/mapping_bootstrap.g.dart';

/// Worker entry point for web workers.
///
/// On web, the compiled JS is loaded and main() is called automatically.
void main() {
  workerMain(generatedWorkerSetup);
}

/// Generated worker setup that registers all discovered adapters.
///
/// Active handlers are selected at runtime based on IDs received from main.
///
/// This function is public so main-side code can import and pass it to
/// Locorda.create(workerSetup: generatedWorkerSetup) for isolate spawning.
Future<WorkerParams> generatedWorkerSetup() async => WorkerParams(
  storages: [
    ...locorda_dir.storages,
    ...locorda_drift.storages,
    ...locorda_solid.storages,
    ...locorda_worker.storages,
  ],
  remotes: [
    ...locorda_dir.remotes,
    ...locorda_drift.remotes,
    ...locorda_solid.remotes,
    ...locorda_worker.remotes,
  ],
  mappingBootstrapSources: bootstrapMappings,
);
