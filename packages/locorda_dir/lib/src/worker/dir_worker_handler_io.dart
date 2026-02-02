/// Local directory storage plugin - worker thread implementation.
library;

import 'dart:io';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_worker/worker.dart';

import '../backend/dir_backend.dart';
import 'dir_auth_connector_worker.dart';

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
  final String _contentType;

  DirWorkerHandler(
      {this.appName = 'locorda',
      String? contentType,
      RdfCore? rdfCore,
      IriTermFactory? iriTermFactory})
      : _rdfCore = rdfCore ??
            RdfCore.withStandardCodecs(
                iriTermFactory: iriTermFactory ?? IriTerm.validated),
        _contentType = contentType ?? turtle.primaryMimeType;

  @override
  String get id => 'local_dir';

  @override
  Future<Backend> createBackend(
      WorkerHandlerContext context, SyncEngineConfig config) async {
    // Get auth from connector (synced from main thread)
    // Backend queries syncDirectoryPath from auth when it becomes enabled
    final auth = DirAuthConnectorWorker.receiver(context);

    return DirBackend(auth: auth, contentType: _contentType, rdfCore: _rdfCore);
  }
}
