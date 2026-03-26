/// Configuration for the local directory backend.
library;

import 'package:locorda_rdf_core/core.dart';

/// Configuration for the local directory storage backend.
///
/// Controls file format and storage mode for synced RDF data.
/// Passed from main thread to worker via [DirConfigConnector].
///
/// ## Usage
///
/// ```dart
/// // Default: file-per-resource with Turtle format
/// final config = DirConfig();
///
/// // Shard datasets enabled (uses TriG for dataset files)
/// final config = DirConfig(useShardDatasets: true);
/// ```
class DirConfig {
  /// MIME type for individual resource files (default: text/turtle).
  final String contentType;

  /// MIME type for dataset/shard files (default: application/trig).
  final String datasetContentType;

  /// Whether to use dataset files for shard storage.
  final bool useShardDatasets;

  DirConfig({
    String? contentType,
    String? datasetContentType,
    this.useShardDatasets = false,
  })  : contentType = contentType ?? turtle.primaryMimeType,
        datasetContentType = datasetContentType ?? trig.primaryMimeType;
}
