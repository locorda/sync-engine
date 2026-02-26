import 'dart:async';

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_objects/locorda_objects.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

import 'test_models.dart';

class _FakeSyncManager implements SyncManager {
  @override
  Stream<SyncState> get statusStream => const Stream<SyncState>.empty();

  @override
  SyncState get currentState => const SyncState.idle();

  @override
  bool get isSyncing => false;

  @override
  Future<void> sync({SyncTrigger trigger = SyncTrigger.manual}) async {}

  @override
  void enableAutoSync({Duration interval = const Duration(minutes: 5)}) {}

  @override
  void disableAutoSync() {}

  @override
  Future<void> dispose() async {}
}

class _FakeSyncEngine implements SyncEngine {
  final _syncManager = _FakeSyncManager();
  IriTerm? lastDeleteTypeIri;
  List<IriTerm>? lastDeleteIris;
  bool deleteDocumentCalled = false;

  @override
  SyncManager get syncManager => _syncManager;

  @override
  Future<void> deleteDocuments(
    IriTerm typeIri,
    Iterable<IriTerm> externalIris,
  ) async {
    lastDeleteTypeIri = typeIri;
    lastDeleteIris = externalIris.toList();
  }

  @override
  Future<void> deleteDocument(IriTerm typeIri, IriTerm externalIri) async {
    deleteDocumentCalled = true;
    throw StateError('deleteDocument should not be called in batch deletion');
  }

  @override
  Future<void> save(IriTerm type, RdfGraph appData) async {
    throw UnimplementedError();
  }

  @override
  Future<void> saveAll(List<(IriTerm type, RdfGraph appData)> items) async {
    throw UnimplementedError();
  }

  @override
  Future<RdfGraph?> ensure(
    IriTerm typeIri,
    IriTerm localIri, {
    required Future<RdfGraph?> Function(IriTerm localIri) loadFromLocal,
    Duration? timeout = const Duration(seconds: 15),
    bool skipInitialFetch = false,
  }) async {
    throw UnimplementedError();
  }

  @override
  Stream<HydrationBatch> hydrateStream({
    required IriTerm typeIri,
    String? indexName,
    String? cursor,
    int initialBatchSize = 100,
  }) {
    throw UnimplementedError();
  }

  @override
  Stream<IndexInstanceSyncState> watchGroupIndexSyncState({
    required String indexName,
    required RdfGraph groupKeyGraph,
  }) {
    return const Stream<IndexInstanceSyncState>.empty();
  }

  @override
  Stream<IndexInstanceSyncState> watchSyncState({
    required IriTerm typeIri,
    String? indexName,
  }) {
    return const Stream<IndexInstanceSyncState>.empty();
  }

  @override
  Future<void> ensureGroupIndexSubscription({
    required String indexName,
    required RdfGraph groupKeyGraph,
    RootResourceFetchPolicy? rootResourceFetchPolicy,
    bool triggerSync = true,
  }) async {}

  @override
  Future<void> ensureGroupIndexSynced({
    required String indexName,
    required RdfGraph groupKeyGraph,
    RootResourceFetchPolicy? rootResourceFetchPolicy,
  }) async {}

  @override
  Future<void> close() async {}
}

void main() {
  group('ObjectSyncEngine.deleteAll', () {
    test('forwards a batch delete without per-item calls', () async {
      final fakeSyncEngine = _FakeSyncEngine();

      final engine = await ObjectSyncEngine.create(
        config: LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
            ),
          ],
        ),
        mapperInitializer: (_) => createTestMapper(),
        syncEngineFactory: (_) async => fakeSyncEngine,
      );

      await engine.deleteAll<TestDocument>(['note-1', 'note-2']);

      expect(fakeSyncEngine.deleteDocumentCalled, isFalse);
      expect(fakeSyncEngine.lastDeleteTypeIri, equals(TestVocab.testDocument));

      final locator = LocalResourceLocator(iriTermFactory: IriTerm.validated);
      final expectedIris = ['note-1', 'note-2']
          .map((id) => locator
              .toIri(ResourceIdentifier.document(TestVocab.testDocument, id)))
          .toList();

      expect(fakeSyncEngine.lastDeleteIris, equals(expectedIris));
    });
  });
}
