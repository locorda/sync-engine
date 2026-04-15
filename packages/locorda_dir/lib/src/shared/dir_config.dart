/// Configuration for the local directory backend.
library;

import 'package:locorda_core/locorda_core.dart';

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
/// // Shard datasets: one TriG file per shard
/// final config = DirConfig(layout: ShardDataset());
///
/// // Single file: everything in one TriG file
/// final config = DirConfig(layout: SingleFile());
///
/// // Custom format: NQuads for shard datasets
/// final config = DirConfig(
///   layout: ShardDataset(contentType: 'application/n-quads'),
/// );
/// ```
class DirConfig {
  /// How resources are organized on the remote backend.
  ///
  /// Determines the file layout and content type:
  /// - [FilePerResource] — one file per resource (default: Turtle)
  /// - [ShardDataset] — one dataset per shard (default: TriG)
  /// - [SingleFile] — everything in a single file (default: TriG)
  ///
  /// The content type for each layout can be overridden via the layout's
  /// [RemoteStorageLayout.contentType] constructor parameter.
  final RemoteStorageLayout layout;

  /// Creates a [DirConfig] with the given storage [layout].
  ///
  /// Choose the layout that matches your backend's file organisation:
  ///
  /// - [FilePerResource] *(default)* — one Turtle file per RDF resource,
  ///   best for fine-grained change tracking and partial sync, but means more files and HTTP requests:
  ///   ```dart
  ///   DirConfig()
  ///   DirConfig(layout: FilePerResource())
  ///   DirConfig(layout: FilePerResource(contentType: 'text/n3'))
  ///   ```
  ///
  /// - [ShardDataset] — one TriG dataset file per index shard, reduces
  ///   round-trips when many resources change together:
  ///   ```dart
  ///   DirConfig(layout: ShardDataset())
  ///   DirConfig(layout: ShardDataset(contentType: 'application/n-quads'))
  ///   ```
  ///
  /// - [SingleFile] — all data in a single TriG file, simplest setup for
  ///   small datasets or when http requests are expensive:
  ///   ```dart
  ///   DirConfig(layout: SingleFile())
  ///   DirConfig(layout: SingleFile(contentType: 'application/n-quads'))
  ///   ```
  DirConfig({this.layout = const FilePerResource()});
}
