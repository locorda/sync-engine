/// Web platform implementation using Web Workers.
library;

// This file is conditionally imported by worker_handle.dart

import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import '../shared/worker_params.dart';

import 'web_worker_handle.dart';
import 'locorda_worker.dart';

Future<LocordaWorker> createImpl(
  WorkerSetup workerSetup,
  SyncEngineConfig config,
  String jsScript,
  String? debugName,
  Future<void> Function(LocordaWorker handle) initializePlugins, {
  void onWorkerSpawn()?,
}) {
  // Note: workerSetup cannot be passed to web worker (not serializable)
  // It must be defined in the worker's JS file via workerMain()
  // workerInitializer is also handled in worker's main() on web
  return WebWorkerHandle.create(jsScript, config, debugName, initializePlugins);
}
