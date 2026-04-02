/// Local directory storage plugin - worker thread implementation.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_dir/src/shared/consts.dart';
import 'package:locorda_worker/worker.dart';
import 'package:rxdart/rxdart.dart';

class _DisabledDirBackend implements PipelineBackend {
  final BehaviorSubject<List<PipelineRemoteStorage>> _subject =
      BehaviorSubject<List<PipelineRemoteStorage>>.seeded(const []);

  Stream<List<PipelineRemoteStorage>> get pipelineRemotesChanged =>
      _subject.stream;

  @override
  Future<void> dispose() async {}

  @override
  String get name => 'local-dir-disabled';

  @override
  List<PipelineRemoteStorage> get pipelineRemotes => const [];
}

class DirWorkerHandler implements RemoteWorkerHandler {
  static bool get isPlatformSupported => false;

  final String appName;
  @override
  final String id;

  DirWorkerHandler({
    this.appName = 'locorda',
    this.id = directoryRemoteHandlerId,
  });

  @override
  Future<Backend> createBackend(
      BackendWorkerHandlerContext context, SyncEngineConfig config) async {
    return _DisabledDirBackend();
  }
}
