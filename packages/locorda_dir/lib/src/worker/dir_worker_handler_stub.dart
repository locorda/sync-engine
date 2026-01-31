/// Local directory storage plugin - worker thread implementation.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_worker/worker.dart';

class _DisabledDirBackend implements Backend {
  @override
  Future<void> dispose() async {}

  @override
  String get name => 'local-dir-disabled';

  @override
  List<RemoteStorage> get remotes => const [];
}

class DirWorkerHandler implements RemoteWorkerHandler {
  static bool get isPlatformSupported => false;

  final String appName;

  DirWorkerHandler({this.appName = 'locorda'});

  @override
  String get id => 'local_dir';

  @override
  Future<Backend> createBackend(
      WorkerHandlerContext context, SyncEngineConfig config) async {
    return _DisabledDirBackend();
  }
}
