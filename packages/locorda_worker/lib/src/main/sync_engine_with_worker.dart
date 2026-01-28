/// Main facade for the CRDT sync system.
library;

import 'dart:async';

import 'package:locorda_core/locorda_core.dart';

import '../shared/worker_params.dart';
import 'locorda_worker.dart';
import 'locorda_worker_impl_native.dart'
    if (dart.library.html) 'locorda_worker_impl_web.dart' as impl;
import 'remote_main_handler.dart';
import 'storage_main_handler.dart';
import 'proxy_sync_engine.dart';
import 'worker_plugin.dart';

class SyncEngineWithWorker {
  static Future<SyncEngine> create(
      {required List<RemoteMainHandler> remotes,
      required StorageMainHandler storage,
      required List<WorkerPluginFactory> plugins,
      required WorkerSetup workerSetup,
      required SyncEngineConfig syncEngineConfig,
      required String jsScript,
      String? debugName,
      void Function()? onWorkerSpawn}) async {
    // Extract worker connectors from storage plugins and merge with other plugins
    final List<WorkerPluginFactory> allPluginFactories = [
      ...remotes.expand((r) => r.workerConnectors),
      ...storage.create(),
      ...plugins,
    ];

    // Create worker handle and initialize plugins in correct order:
    // 1. Spawn worker (creates handle + communication channel)
    // 2. Initialize plugins (sets up listeners before worker processes)
    // 3. Send config to worker (triggers engine initialization)
    // 4. Wait for ready (engine is now initialized)
    final (workerHandle, closeFunctions) = await _createWorkerWithPlugins(
      workerSetup: workerSetup,
      config: syncEngineConfig,
      jsScript: jsScript,
      debugName: debugName,
      onWorkerSpawn: onWorkerSpawn,
      pluginFactories: allPluginFactories,
    );

    // Create proxy that forwards operations to worker
    final syncEngine = await ProxySyncEngine.create(
      workerHandle: workerHandle,
      closeFunctions: closeFunctions,
    );
    return syncEngine;
  }

  /// Creates worker with proper plugin initialization order.
  ///
  /// Execution order guarantees plugins are ready before worker starts:
  /// 1. Spawn worker isolate/web worker (creates communication channel)
  /// 2. Initialize plugins (sets up message listeners)
  /// 3. Send config to worker (triggers engine initialization)
  /// 4. Wait for 'ready' (worker has created SyncEngine)
  static Future<(LocordaWorker, List<Future<void> Function()>)>
      _createWorkerWithPlugins({
    required WorkerSetup workerSetup,
    required SyncEngineConfig config,
    required String jsScript,
    required List<WorkerPluginFactory> pluginFactories,
    String? debugName,
    void onWorkerSpawn()?,
  }) async {
    final closeFunctions = <Future<void> Function()>[];

    final workerHandle = await impl.createImpl(
      workerSetup,
      config,
      jsScript,
      debugName,
      (handle) async {
        // Initialize all plugins with the handle
        for (final pluginFactory in pluginFactories) {
          final plugin = pluginFactory(handle);
          await plugin.initialize();
          closeFunctions.add(plugin.dispose);
        }
      },
      onWorkerSpawn: onWorkerSpawn,
    );

    return (workerHandle, closeFunctions);
  }
}
