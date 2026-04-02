/// Local directory storage plugin - worker thread implementation.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_dir/src/shared/consts.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_worker/worker.dart';
import 'package:rxdart/rxdart.dart';

class _DisabledDirBackend implements Backend {
  final BehaviorSubject<List<RemoteStorage>> _subject =
      BehaviorSubject<List<RemoteStorage>>.seeded(const []);

  Stream<List<RemoteStorage>> get remotesChanged => _subject.stream;

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
  @override
  final String id;
  final Perflog? perflog;
  DirWorkerHandler({
    this.appName = 'locorda',
    RdfCore? rdfCore,
    IriTermFactory? iriTermFactory,
    this.id = directoryRemoteHandlerId,
    this.perflog,
  });

  @override
  Future<Backend> createBackend(
      BackendWorkerHandlerContext context, SyncEngineConfig config) async {
    return _DisabledDirBackend();
  }
}
