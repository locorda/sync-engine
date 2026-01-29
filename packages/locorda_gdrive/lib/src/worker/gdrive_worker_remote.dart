/// Google Drive storage plugin - worker thread implementation.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_worker/worker.dart';

import '../gdrive_backend.dart';
import '../gdrive_type_index_manager.dart';
import 'gdrive_auth_connector_worker.dart';

/// Worker-thread [RemoteWorkerHandler] implementation for Google Drive backend.
///
/// Creates [GDriveBackend] instances in the worker thread for Drive communication.
/// This plugin handles all backend operations:
/// - HTTP requests to Google Drive API
/// - OAuth2 token management
/// - File operations (list, read, write)
///

///
/// ## Main Thread Counterpart
///
/// This plugin requires a corresponding [GDriveMainHandler] on the main thread.
/// The main thread handles authentication and sends credentials
/// to the worker via [GDriveAuthConnector].
class GDriveWorkerHandler implements RemoteWorkerHandler {
  final GDriveConfig config;

  GDriveWorkerHandler({
    required this.config,
  });

  @override
  String get id => 'gdrive';

  @override
  Future<Backend> createBackend(
      WorkerHandlerContext context, SyncEngineConfig syncEngineConfig) async {
    return GDriveBackend(
      auth: GDriveAuthConnector.receiver(context),
      config: config,
    );
  }
}
