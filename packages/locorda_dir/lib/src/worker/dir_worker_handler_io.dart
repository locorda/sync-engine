/// Local directory storage plugin - worker thread implementation.
library;

import 'dart:io';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_dir/src/shared/consts.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_worker/worker.dart';

import '../backend/dir_backend.dart';
import 'dir_auth_connector_worker.dart';
import 'dir_config_connector_worker.dart';

/// Worker-thread [RemoteWorkerHandler] implementation for local directory backend.
///
/// Creates [DirBackend] instances in the worker thread for file I/O operations.
/// This plugin handles:
/// - Reading/writing RDF files to local directory
/// - ETag generation from file metadata
/// - Directory creation and management
///
/// ## Main Thread Counterpart
///
/// This plugin requires a corresponding [DirMainIntegration] on the main thread.
/// The main thread handles UI and authentication state.
class DirWorkerHandler implements RemoteWorkerHandler {
  /// Platform support flag (desktop platforms only).
  static bool get isPlatformSupported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  final String appName;
  final RdfCore _rdfCore;
  @override
  final String id;

  DirWorkerHandler({
    this.appName = 'locorda',
    RdfCore? rdfCore,
    IriTermFactory? iriTermFactory,
    this.id = directoryRemoteHandlerId,
  }) : _rdfCore = rdfCore ??
            RdfCore.withStandardCodecs(
                iriTermFactory: iriTermFactory ?? IriTerm.validated);

  @override
  Future<Backend> createBackend(
      WorkerHandlerContext context, SyncEngineConfig config) async {
    // Get auth from connector (synced from main thread)
    final auth = DirAuthConnectorWorker.receiver(context, id);

    // Get config from connector (synced from main thread)
    final dirConfigReceiver = DirConfigConnectorWorker.receiver(context, id);
    final dirConfig = await dirConfigReceiver.getConfig();

    final backend = DirBackend(
      auth: auth,
      contentType: dirConfig.contentType,
      datasetContentType: dirConfig.datasetContentType,
      rdfCore: _rdfCore,
      useShardDatasets: dirConfig.useShardDatasets,
      perflog: context.perflog,
    );
    if (context.perflog != Perflog.disabled) {
      return PerflogBackend(backend, perflog: context.perflog);
    } else {
      return backend;
    }
  }
}
