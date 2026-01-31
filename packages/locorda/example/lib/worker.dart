/// Worker entry point for Personal Notes App.
///
/// This file runs in a separate isolate/web worker and handles:
/// - Database operations (DriftStorage)
/// - CRDT synchronization
/// - Solid Pod communication
/// - All heavy computation
///
/// The main thread only handles UI and communicates via messages.
library;

import 'package:locorda/worker.dart';
import 'package:locorda_dir/worker.dart';
import 'package:personal_notes_app/utils/logging_setup.dart';

/// Worker entry point for web workers.
///
/// On web, the compiled JS is loaded and main() is called automatically.
void main() {
  workerMain(setupWorkerEngine, onWorkerSpawn: setupWorkerLogging);
}

/// Factory function that creates and configures the SyncEngine in the worker.
///
/// This function is passed to `workerMain()` and called by the framework during
/// the worker setup process after receiving configuration from the main thread.
///
/// Framework provides:
/// - [config]: SyncEngineConfig (already converted from LocordaConfig by main thread)
/// - [context]: WorkerContext with communication channel for cross-thread operations
///
/// App creates:
/// - Storage (DriftWorkerStorage with platform-specific options)
/// - Remotes (SolidWorkerRemote, GDriveWorkerRemote)
///
/// Returns parameters for SyncEngine creation in the worker.
Future<WorkerParams> setupWorkerEngine() async => WorkerParams(
      // in main, we configured Solid and GDrive as remotes
      remotes: [
        if (DirWorkerHandler.isPlatformSupported) DirWorkerHandler(),
        SolidWorkerHandler(),
        GDriveWorkerHandler()
      ],

      // in main, we also configured DriftStorage as the storage
      storage: DriftWorkerHandler(
          web: LocordaDriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
      )),
    );
