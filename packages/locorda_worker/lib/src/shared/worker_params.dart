import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_worker/worker.dart';

import 'package:http/http.dart' as http;

/// Factory function type for creating EngineParams in worker.
///
/// Apps implement this to configure storage, backends, and other worker-side resources.
/// The framework creates the SyncEngine from the returned EngineParams.
typedef WorkerSetup = Future<WorkerParams> Function();

class WorkerParams {
  final List<StorageWorkerHandler> storages;
  final List<RemoteWorkerHandler> remotes;
  final PhysicalTimestampFactory? physicalTimestampFactory;
  final InstallationIdFactory? installationIdFactory;
  final IriTermFactory? iriFactory;
  final RdfCore rdfCore;
  final http.Client? httpClient;
  final Fetcher? fetcher;
  final Iterable<String>? mappingBootstrapSources;

  WorkerParams({
    required this.storages,
    this.remotes = const [],
    this.physicalTimestampFactory,
    this.installationIdFactory,
    this.iriFactory,
    RdfCore? rdfCore,
    this.httpClient,
    this.fetcher,
    this.mappingBootstrapSources,
  }) : rdfCore = rdfCore ??
            RdfCore.withStandardCodecs(
              additionalBinaryDatasetCodecs:
                  StandardSyncEngine.extraBinaryDatasetCodecs,
              additionalBinaryGraphCodecs:
                  StandardSyncEngine.extraBinaryGraphCodecs,
            );
}
