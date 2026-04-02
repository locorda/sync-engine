import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_core/src/sync/pipeline/backend/file_per_resource_pipeline.dart';
import 'package:locorda_core/src/sync/pipeline/backend/shard_dataset_pipeline.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_rdf_core/core.dart';

/// Storage mode determining how resources are organized on the remote.
enum RemoteStorageMode {
  /// One file per resource — graph format (default: Turtle).
  filePerResource(defaultContentType: 'text/turtle'),

  /// All resources in one dataset file per shard — dataset format (default: TriG).
  shardDataset(defaultContentType: 'application/trig');

  /// Default content type for encoding/decoding in this mode.
  final String defaultContentType;

  const RemoteStorageMode({required this.defaultContentType});

  static RemoteStorageMode fromFlags({
    required bool useShardDatasets,
  }) {
    return useShardDatasets
        ? RemoteStorageMode.shardDataset
        : RemoteStorageMode.filePerResource;
  }
}

/// Factory for creating [PipelineRemoteSyncStorage] implementations backed
/// by a stream-based [RemoteSyncBackend].
class RemoteSyncStorages {
  static PipelineRemoteSyncStorage create({
    required RemoteStorageMode mode,
    required RemoteSyncBackend backend,
    required RdfCore rdfCore,
    required ResourceGraphLoader resourceGraphLoader,
    String? contentType,
    bool? isBinary,
  }) {
    final effectiveContentType = contentType ?? mode.defaultContentType;
    return switch (mode) {
      RemoteStorageMode.filePerResource => FilePerResourceRemoteSyncStorage(
          backend,
          rdfCore: rdfCore,
          contentType: effectiveContentType,
          isBinary: isBinary,
        ),
      RemoteStorageMode.shardDataset => ShardDatasetRemoteSyncStorage(
          backend,
          rdfCore: rdfCore,
          contentType: effectiveContentType,
          resourceGraphLoader: resourceGraphLoader,
          isBinary: isBinary,
        ),
    };
  }

  static PipelineRemoteSyncStorage createIriTranslated({
    required RemoteStorageMode mode,
    required RemoteSyncBackend backend,
    required RdfCore rdfCore,
    required ResourceGraphLoader resourceGraphLoader,
    required IriTranslator translator,
    String? contentType,
    bool? isBinary,
  }) {
    final effectiveLoader = IriTranslatingResourceGraphLoader(
      inner: resourceGraphLoader,
      iriTranslator: translator,
    );

    final storage = create(
      backend: backend,
      mode: mode,
      rdfCore: rdfCore,
      resourceGraphLoader: effectiveLoader,
      contentType: contentType,
      isBinary: isBinary,
    );

    return PipelineIriTranslatingRemoteSyncStorage(
        remote: storage, iriTranslator: translator, rdfCore: rdfCore);
  }
}
