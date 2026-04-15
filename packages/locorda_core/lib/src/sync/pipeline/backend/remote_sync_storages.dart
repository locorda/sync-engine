import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/sync/pipeline/backend/file_per_resource_pipeline.dart';
import 'package:locorda_core/src/sync/pipeline/backend/shard_dataset_pipeline.dart';
import 'package:locorda_core/src/sync/pipeline/backend/single_file_pipeline.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_support.dart';
import 'package:locorda_rdf_core/core.dart';

/// Storage layout determining how resources are organized on the remote.
///
/// Sealed hierarchy so each layout can carry layout-specific settings
/// (e.g. future delta layout may need reconciliation parameters).
sealed class RemoteStorageLayout {
  /// RDF content type for encoding/decoding resources in this layout.
  final String contentType;

  /// File extension (without leading dot) for files in this layout.
  ///
  /// Defaults to the canonical extension for [contentType] (e.g. `ttl` for
  /// Turtle, `trig` for TriG). Override in the constructor to use a custom
  /// extension for content types not in the built-in mapping.
  final String fileExtension;

  const RemoteStorageLayout({required this.contentType, String? fileExtension})
      : fileExtension = fileExtension ??
            // no clue why dart 3.6 doesn't allow switch expressions in initializer lists, this is so sad
            (contentType == 'text/turtle'
                ? 'ttl'
                : contentType == 'application/trig'
                    ? 'trig'
                    : contentType == 'application/n-triples'
                        ? 'nt'
                        : contentType == 'application/n-quads'
                            ? 'nq'
                            : contentType == 'application/ld+json'
                                ? 'jsonld'
                                : contentType == 'application/x-jelly-rdf'
                                    ? 'jelly'
                                    : 'bin');

  /// Serializes this layout to a JSON map.
  ///
  /// The `fileExtension` is only included when it differs from the default
  /// for the given [contentType].
  Map<String, dynamic> toJson() {
    final type = switch (this) {
      FilePerResource() => 'filePerResource',
      ShardDataset() => 'shardDataset',
      SingleFile() => 'singleFile',
    };
    return {
      'type': type,
      'contentType': contentType,
      'fileExtension': fileExtension,
    };
  }

  /// Deserializes a layout from a JSON map produced by [toJson].
  static RemoteStorageLayout fromJson(Map<String, dynamic> json) {
    final contentType = json['contentType'] as String?;
    final fileExtension = json['fileExtension'] as String?;
    return switch (json['type'] as String?) {
      'shardDataset' => ShardDataset(
          contentType: contentType,
          fileExtension: fileExtension,
        ),
      'singleFile' => SingleFile(
          contentType: contentType,
          fileExtension: fileExtension,
        ),
      _ => FilePerResource(
          contentType: contentType,
          fileExtension: fileExtension,
        ),
    };
  }
}

/// One file per resource — graph format (default: Turtle).
class FilePerResource extends RemoteStorageLayout {
  const FilePerResource({
    String? contentType,
    super.fileExtension,
  }) : super(contentType: contentType ?? 'text/turtle');
}

/// All resources in one dataset file per shard — dataset format (default: TriG).
class ShardDataset extends RemoteStorageLayout {
  const ShardDataset({
    String? contentType,
    super.fileExtension,
  }) : super(contentType: contentType ?? 'application/trig');
}

/// All shards and resources in a single dataset file — dataset format (default: TriG).
///
/// The file is an RDF dataset with no default graph. Every shard document and
/// every resource document is stored as a named graph, keyed by its document IRI.
///
/// The document IRI is auto-generated internally by the pipeline using the
/// framework's `tag:locorda.org,2025:l:...` IRI scheme.
/// Best for small datasets or backends with expensive per-file operations.
class SingleFile extends RemoteStorageLayout {
  const SingleFile({
    String? contentType,
    super.fileExtension,
  }) : super(contentType: contentType ?? 'application/trig');
}

/// Factory for creating [PipelineRemoteSyncStorage] implementations backed
/// by a stream-based [RemoteSyncBackend].
class RemoteSyncStorages {
  static PipelineRemoteSyncStorage create({
    required RemoteStorageLayout layout,
    required RemoteSyncBackend backend,
    required RdfCore rdfCore,
    required BackendStorageAccess storageAccess,
  }) {
    return switch (layout) {
      FilePerResource(:final contentType) => FilePerResourceRemoteSyncStorage(
          backend,
          rdfCore: rdfCore,
          contentType: contentType,
        ),
      ShardDataset(:final contentType) => ShardDatasetRemoteSyncStorage(
          backend,
          rdfCore: rdfCore,
          contentType: contentType,
          storageAccess: storageAccess,
        ),
      SingleFile(:final contentType) => SingleFileRemoteSyncStorage(
          backend,
          rdfCore: rdfCore,
          contentType: contentType,
          storageAccess: storageAccess,
        ),
    };
  }

  static PipelineRemoteSyncStorage createIriTranslated({
    required RemoteStorageLayout layout,
    required RemoteSyncBackend backend,
    required RdfCore rdfCore,
    required BackendStorageAccess storageAccess,
    required IriTranslator translator,
  }) {
    final effectiveAccess = IriTranslatingBackendStorageAccess(
      inner: storageAccess,
      iriTranslator: translator,
    );

    final storage = create(
      backend: backend,
      layout: layout,
      rdfCore: rdfCore,
      storageAccess: effectiveAccess,
    );

    return PipelineIriTranslatingRemoteSyncStorage(
        remote: storage, iriTranslator: translator, rdfCore: rdfCore);
  }
}
