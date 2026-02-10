/// Native platform implementation using Dart isolates.
library;

// This file is conditionally imported by worker_handle.dart

import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import '../shared/worker_params.dart';

import 'native_worker_handle.dart';
import 'locorda_worker.dart';

Future<LocordaWorker> createImpl(
  WorkerSetup workerSetup,
  SyncEngineConfig config,
  String jsScript,
  String? debugName,
  String activeStorageId,
  List<String> activeRemoteIds,
  Future<void> Function(LocordaWorker handle) initializePlugins, {
  void onWorkerSpawn()?,
}) {
  // jsScript is ignored on native - only needed for web
  return NativeWorkerHandle.create(
    workerSetup,
    config.toJson(),
    debugName,
    activeStorageId,
    activeRemoteIds,
    initializePlugins,
    onWorkerSpawn: onWorkerSpawn,
  );
}
