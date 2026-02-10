/// Adapter manifest contract for worker-side handlers.
///
/// Adapter packages provide a manifest file that declares which handler types
/// they expose to the worker registry builder.
library;

import '../worker/remote_worker_handler.dart';
import '../worker/storage_worker_handler.dart';

/// Factory signature for storage handlers.
typedef StorageWorkerHandlerFactory = StorageWorkerHandler Function(String id);

/// Factory signature for remote handlers.
typedef RemoteWorkerHandlerFactory = RemoteWorkerHandler Function(String id);

/// Describes a worker-side handler available from an adapter package.
sealed class AdapterManifestEntry {
  /// Unique handler key, e.g. 'locorda_drift:default', 'locorda_solid:default'.
  ///
  /// Corresponds to StorageWorkerHandler.id / RemoteWorkerHandler.id.
  final String key;

  const AdapterManifestEntry._({
    required this.key,
  });
}

class StorageManifestEntry extends AdapterManifestEntry {
  /// Factory that creates a handler instance for the given id.
  final StorageWorkerHandlerFactory factory;

  const StorageManifestEntry({
    required String key,
    required this.factory,
  }) : super._(key: key);
}

class RemoteManifestEntry extends AdapterManifestEntry {
  /// Factory that creates a handler instance for the given id.
  final RemoteWorkerHandlerFactory factory;

  const RemoteManifestEntry({
    required String key,
    required this.factory,
  }) : super._(key: key);
}
