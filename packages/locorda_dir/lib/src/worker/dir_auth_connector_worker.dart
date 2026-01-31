/// Worker-thread receiver for local directory authentication state.
library;

import 'package:locorda_worker/worker.dart';

import 'worker_dir_auth_provider.dart';

/// Worker-side connector for receiving authentication state from main thread.
class DirAuthConnectorWorker {
  /// Creates a receiver for directory auth updates.
  ///
  /// Call this in the worker thread to get an auth provider that receives
  /// updates from the main thread.
  static WorkerDirAuthProvider receiver(WorkerHandlerContext context) {
    final channel = context.createChannel('locorda_dir/dir_auth');
    return WorkerDirAuthProvider(channel);
  }
}
