/// Solid Pod storage plugin - worker thread implementation.
library solid_worker_plugin;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_solid_core/locorda_solid_core.dart';
import 'package:locorda_solid_auth_worker/worker.dart';
import 'package:locorda_worker/worker.dart';
import 'package:http/http.dart' as http;

import '../shared/consts.dart';
import 'solid_config_connector_worker.dart';

/// Worker-thread [RemoteWorkerHandler] implementation for Solid Pod backend.
///
/// Creates [SolidBackend] instances in the worker thread for Pod communication.
/// This plugin handles all backend operations:
/// - HTTP requests to Solid Pods
/// - DPoP token generation
/// - RDF graph fetching and pushing

/// ## Main Thread Counterpart
///
/// This plugin requires a corresponding [SolidMainIntegration] on the main thread.
/// The main thread handles authentication and sends credentials
/// to the worker via [SolidAuthConnector].
class SolidWorkerHandler implements RemoteWorkerHandler {
  final http.Client _httpClient;
  final String _contentType;
  final String _datasetContentType;
  final String id;

  SolidWorkerHandler({
    http.Client? httpClient,
    String? contentType,
    String? datasetContentType,
    this.id = solidRemoteHandlerId,
  })  : _httpClient = httpClient ?? http.Client(),
        _contentType = contentType ?? turtle.primaryMimeType,
        _datasetContentType = datasetContentType ?? trig.primaryMimeType;

  @override
  Future<Backend> createBackend(
      BackendWorkerHandlerContext context, SyncEngineConfig config) async {
    final solidConfig = await SolidConfigConnector.receiveConfig(context, id);

    final backend = SolidBackend(
      auth: SolidAuthConnector.receiver(context, id),
      rdfCore: context.rdfCore,
      iriTermFactory: context.iriFactory ?? IriTerm.validated,
      httpClient: _httpClient,
      contentType: _contentType,
      datasetContentType: _datasetContentType,
      config: solidConfig,
    );
    if (context.perflog != Perflog.disabled) {
      return PerflogBackend(backend, perflog: context.perflog);
    } else {
      return backend;
    }
  }
}
