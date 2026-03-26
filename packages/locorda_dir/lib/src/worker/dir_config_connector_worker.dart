/// Worker-thread receiver for local directory configuration.
library;

import 'package:locorda_worker/worker.dart';

import 'worker_dir_config_receiver.dart';

/// Worker-side connector for receiving [DirConfig] from main thread.
class DirConfigConnectorWorker {
  /// Creates a receiver for directory config.
  ///
  /// Call this in the worker thread to get the config sent from main thread.
  static WorkerDirConfigReceiver receiver(
      WorkerHandlerContext context, String id) {
    final channel = context.createChannel('locorda_dir/$id/dir_config');
    return WorkerDirConfigReceiver(channel);
  }
}
