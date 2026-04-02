/// Google Drive storage plugin - worker thread implementation.
library;

import 'package:http/http.dart' as http;
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_worker/worker.dart';

import '../gdrive_backend.dart';
import '../shared/consts.dart';
import 'gdrive_auth_connector_worker.dart';

/// Worker-thread [RemoteWorkerHandler] implementation for Google Drive backend.
///
/// Creates [GDriveBackend] instances in the worker thread for Drive communication.
/// This plugin handles all backend operations:
/// - HTTP requests to Google Drive API
/// - OAuth2 token management
/// - File operations (list, read, write)
///
/// The configuration ([GDriveConfig]) is automatically received from the main thread
/// via [GDriveAuthConnector.receiveConfig].
///
/// ## Main Thread Counterpart
///
/// This plugin requires a corresponding [GDriveMainIntegration] on the main thread.
/// The main thread handles authentication and configuration, sending both
/// to the worker via connectors.
///
/// ## Usage
///
/// ```dart
/// Future<WorkerParams> setupWorkerEngine() async => WorkerParams(
///   remotes: [
///     GDriveWorkerHandler(), // Config received automatically
///   ],
///   // ... storage needs to be configured as well
/// );
/// ```
class GDriveWorkerHandler implements RemoteWorkerHandler {
  final IriTermFactory? _iriTermFactory;
  final RdfCore _rdfCore;
  final http.Client _httpClient;
  final String _contentType;
  final String _datasetContentType;
  final String id;

  GDriveWorkerHandler({
    IriTermFactory? iriTermFactory,
    RdfCore? rdfCore,
    http.Client? httpClient,
    String? contentType,
    String? datasetContentType,
    this.id = gDriveRemoteHandlerId,
  })  : _iriTermFactory = iriTermFactory ?? IriTerm.validated,
        _rdfCore = rdfCore ??
            RdfCore.withStandardCodecs(
                iriTermFactory: iriTermFactory ?? IriTerm.validated),
        _httpClient = httpClient ?? http.Client(),
        _contentType = contentType ?? turtle.primaryMimeType,
        _datasetContentType = datasetContentType ?? trig.primaryMimeType;

  @override
  Future<Backend> createBackend(BackendWorkerHandlerContext context,
      SyncEngineConfig syncEngineConfig) async {
    // Receive config from main thread
    final config = await GDriveAuthConnector.receiveConfig(context, id);

    return GDriveBackend.create(
      auth: GDriveAuthConnector.receiver(context, id),
      config: config,
      iriTermFactory: _iriTermFactory,
      rdfCore: _rdfCore,
      httpClient: _httpClient,
      contentType: _contentType,
      datasetContentType: _datasetContentType,
      perflog: context.perflog,
    );
  }
}
