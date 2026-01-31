/// Shared interface for directory authentication providers.
library;

import 'package:locorda_core/locorda_core.dart';

/// Interface for authentication providers that support local directory sync.
///
/// Implemented by:
/// - [DirAuth] (main thread)
/// - [WorkerDirAuthProvider] (worker thread)
abstract interface class DirAuthProvider implements Auth {
  /// Directory path where sync files are stored.
  String get syncDirectoryPath;
}
