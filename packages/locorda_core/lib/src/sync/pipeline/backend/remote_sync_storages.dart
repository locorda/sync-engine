import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_core/src/sync/pipeline/backend/file_per_resource_pipeline.dart';
import 'package:locorda_core/src/sync/pipeline/backend/shard_dataset_pipeline.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart';

enum RemoteStorageMode {
  filePerResource,
  shardDataset,
}

abstract interface class RemoteSyncStorageBackend
    implements FPRBackend, SDSBackend {}

class RemoteSyncStorages {
  static PipelineRemoteSyncStorage create({
    required RemoteStorageMode mode,
    required RemoteSyncStorageBackend backend,
    required ResourceGraphLoader resourceGraphLoader,
    int batchSize = defaultPipelineBatchSize,
  }) {
    switch (mode) {
      case RemoteStorageMode.filePerResource:
        return FilePerResourceRemoteSyncStorage(
          backend,
          batchSize: batchSize,
        );
      case RemoteStorageMode.shardDataset:
        return ShardDatasetRemoteSyncStorage(
          backend,
          batchSize: batchSize,
          resourceGraphLoader: resourceGraphLoader,
        );
    }
  }

  static PipelineRemoteSyncStorage createIriTranslated({
    required RemoteStorageMode mode,
    required RemoteSyncStorageBackend backend,
    required ResourceGraphLoader resourceGraphLoader,
    required IriTranslator translator,
    required RdfCore rdfCore,
    int batchSize = defaultPipelineBatchSize,
  }) {
    final effectiveLoader = IriTranslatingResourceGraphLoader(
      inner: resourceGraphLoader,
      iriTranslator: translator,
    );

    final storage = create(
        backend: backend,
        mode: mode,
        resourceGraphLoader: effectiveLoader,
        batchSize: batchSize);

    return PipelineIriTranslatingRemoteSyncStorage(
        remote: storage, iriTranslator: translator, rdfCore: rdfCore);
  }
}
