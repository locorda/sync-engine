import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:test/test.dart';

class _GraphCall {
  final IriTerm documentIri;
  final String? conditional;

  const _GraphCall({required this.documentIri, required this.conditional});
}

class _GraphUploadCall {
  final IriTerm documentIri;
  final String? ifMatch;
  final RdfGraph graph;

  const _GraphUploadCall({
    required this.documentIri,
    required this.ifMatch,
    required this.graph,
  });
}

class _FakeGraphSyncStorage extends GraphSyncStorage {
  final downloadCalls = <_GraphCall>[];
  final uploadCalls = <_GraphUploadCall>[];

  @override
  Future<RemoteDownloadResult<RdfGraph>> download(IriTerm documentIri,
      {String? ifNoneMatch}) async {
    downloadCalls
        .add(_GraphCall(documentIri: documentIri, conditional: ifNoneMatch));
    return RemoteDownloadResult<RdfGraph>(
      graph: RdfGraph(),
      etag: 'd-${documentIri.value}',
    );
  }

  @override
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfGraph graph,
      {String? ifMatch}) async {
    uploadCalls.add(
      _GraphUploadCall(
          documentIri: documentIri, ifMatch: ifMatch, graph: graph),
    );
    return RemoteUploadResult.success('u-${documentIri.value}');
  }
}

class _DatasetCall {
  final IriTerm documentIri;
  final String? conditional;

  const _DatasetCall({required this.documentIri, required this.conditional});
}

class _DatasetUploadCall {
  final IriTerm documentIri;
  final String? ifMatch;
  final RdfDataset dataset;

  const _DatasetUploadCall({
    required this.documentIri,
    required this.ifMatch,
    required this.dataset,
  });
}

class _FakeRemoteSyncStorage extends RemoteSyncStorage {
  final graphDownloadCalls = <_GraphCall>[];
  final graphUploadCalls = <_GraphUploadCall>[];
  final datasetDownloadCalls = <_DatasetCall>[];
  final datasetUploadCalls = <_DatasetUploadCall>[];

  @override
  Future<RemoteDownloadResult<RdfGraph>> download(IriTerm documentIri,
      {String? ifNoneMatch}) async {
    graphDownloadCalls
        .add(_GraphCall(documentIri: documentIri, conditional: ifNoneMatch));
    return RemoteDownloadResult<RdfGraph>(
      graph: RdfGraph(),
      etag: 'g-${documentIri.value}',
    );
  }

  @override
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfGraph graph,
      {String? ifMatch}) async {
    graphUploadCalls.add(
      _GraphUploadCall(
          documentIri: documentIri, ifMatch: ifMatch, graph: graph),
    );
    return RemoteUploadResult.success('gu-${documentIri.value}');
  }

  @override
  Future<RemoteDownloadResult<RdfDataset>> downloadDataset(IriTerm documentIri,
      {String? ifNoneMatch}) async {
    datasetDownloadCalls
        .add(_DatasetCall(documentIri: documentIri, conditional: ifNoneMatch));
    return RemoteDownloadResult<RdfDataset>(
      graph: RdfDataset(defaultGraph: RdfGraph(), namedGraphs: const {}),
      etag: 'ds-${documentIri.value}',
    );
  }

  @override
  Future<RemoteUploadResult> uploadDataset(
      IriTerm documentIri, RdfDataset dataset,
      {String? ifMatch}) async {
    datasetUploadCalls.add(
      _DatasetUploadCall(
        documentIri: documentIri,
        ifMatch: ifMatch,
        dataset: dataset,
      ),
    );
    return RemoteUploadResult.success('du-${documentIri.value}');
  }
}

void main() {
  group('Remote storage bulk default implementations', () {
    test('GraphSyncStorage.downloadMany delegates to single downloads',
        () async {
      final storage = _FakeGraphSyncStorage();
      final docA = IriTerm.validated('tag:locorda.org,2025:l:test/doc-a');
      final docB = IriTerm.validated('tag:locorda.org,2025:l:test/doc-b');

      final results = await storage.downloadMany([
        RemoteDownloadRequest(documentIri: docA, ifNoneMatch: 'etag-a'),
        RemoteDownloadRequest(documentIri: docB),
      ]);

      expect(results, hasLength(2));
      expect(storage.downloadCalls, hasLength(2));
      expect(storage.downloadCalls[0].documentIri, docA);
      expect(storage.downloadCalls[0].conditional, 'etag-a');
      expect(storage.downloadCalls[1].documentIri, docB);
      expect(storage.downloadCalls[1].conditional, isNull);
    });

    test('GraphSyncStorage.uploadMany delegates to single uploads', () async {
      final storage = _FakeGraphSyncStorage();
      final docA = IriTerm.validated('tag:locorda.org,2025:l:test/doc-a');
      final docB = IriTerm.validated('tag:locorda.org,2025:l:test/doc-b');

      final results = await storage.uploadMany([
        RemoteUploadRequest<RdfGraph>(
          documentIri: docA,
          document: RdfGraph(),
          ifMatch: 'etag-a',
        ),
        RemoteUploadRequest<RdfGraph>(
          documentIri: docB,
          document: RdfGraph(),
        ),
      ]);

      expect(results, hasLength(2));
      expect(storage.uploadCalls, hasLength(2));
      expect(storage.uploadCalls[0].documentIri, docA);
      expect(storage.uploadCalls[0].ifMatch, 'etag-a');
      expect(storage.uploadCalls[1].documentIri, docB);
      expect(storage.uploadCalls[1].ifMatch, isNull);
    });

    test('RemoteSyncStorage.downloadManyDatasets delegates to single downloads',
        () async {
      final storage = _FakeRemoteSyncStorage();
      final shardA = IriTerm.validated('tag:locorda.org,2025:l:test/shard-a');
      final shardB = IriTerm.validated('tag:locorda.org,2025:l:test/shard-b');

      final results = await storage.downloadManyDatasets([
        RemoteDownloadRequest(documentIri: shardA, ifNoneMatch: 'etag-a'),
        RemoteDownloadRequest(documentIri: shardB),
      ]);

      expect(results, hasLength(2));
      expect(storage.datasetDownloadCalls, hasLength(2));
      expect(storage.datasetDownloadCalls[0].documentIri, shardA);
      expect(storage.datasetDownloadCalls[0].conditional, 'etag-a');
      expect(storage.datasetDownloadCalls[1].documentIri, shardB);
      expect(storage.datasetDownloadCalls[1].conditional, isNull);
    });

    test('RemoteSyncStorage.uploadManyDatasets delegates to single uploads',
        () async {
      final storage = _FakeRemoteSyncStorage();
      final shardA = IriTerm.validated('tag:locorda.org,2025:l:test/shard-a');
      final shardB = IriTerm.validated('tag:locorda.org,2025:l:test/shard-b');

      final results = await storage.uploadManyDatasets([
        RemoteUploadRequest<RdfDataset>(
          documentIri: shardA,
          document: RdfDataset(defaultGraph: RdfGraph(), namedGraphs: const {}),
          ifMatch: 'etag-a',
        ),
        RemoteUploadRequest<RdfDataset>(
          documentIri: shardB,
          document: RdfDataset(defaultGraph: RdfGraph(), namedGraphs: const {}),
        ),
      ]);

      expect(results, hasLength(2));
      expect(storage.datasetUploadCalls, hasLength(2));
      expect(storage.datasetUploadCalls[0].documentIri, shardA);
      expect(storage.datasetUploadCalls[0].ifMatch, 'etag-a');
      expect(storage.datasetUploadCalls[1].documentIri, shardB);
      expect(storage.datasetUploadCalls[1].ifMatch, isNull);
    });
  });
}
