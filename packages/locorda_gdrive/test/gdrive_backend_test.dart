import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_gdrive/src/gdrive_api.dart';
import 'package:locorda_gdrive/src/gdrive_backend.dart';
import 'package:locorda_gdrive/src/gdrive_folder_strategy.dart';
import 'package:locorda_rdf_core/core.dart';

class _FakeGDriveApiClient implements GDriveApiClient {
  final List<String> createFolderIds = [];
  int createAttempts = 0;

  @override
  Future<({String fileId, String md5Checksum})> createFileRaw(
    String filename,
    List<int> bytes, {
    required String folderId,
    required String contentType,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
  }) async {
    createAttempts++;
    createFolderIds.add(folderId);
    if (createAttempts == 1) {
      throw GDriveClientException('missing parent', statusCode: 404);
    }
    return (fileId: 'file-1', md5Checksum: 'etag-1');
  }

  @override
  Future<String?> findFile({
    required String fileName,
    required String parentId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
  }) async =>
      null;

  @override
  Future<String> getOrCreateFolder({
    required String folderName,
    String? parentId,
    String spaces = 'drive',
  }) {
    throw UnimplementedError();
  }

  @override
  Future<({String fileId, String etag})> createFile<T>(
    String filename,
    T graph, {
    required String folderId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
    required String contentType,
    required String Function(T p1) convert,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<({T? graph, String? etag, bool notModified})> download<T>(
    String fileId, {
    String? ifNoneMatch,
    required T Function(String p1) convert,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<({List<int>? bytes, String? etag, bool notModified})> downloadRaw(
    String fileId, {
    String? ifNoneMatch,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<int>> downloadRawBytes(String fileId) {
    throw UnimplementedError();
  }

  @override
  Future<List<GDriveListedEntry>> listFilesRecursively({
    required String rootFolderId,
    required String spaces,
    required int maxConcurrentRequests,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<RemoteUploadResult> upload<T>(
    String fileId,
    T updatedGraph, {
    required String ifMatch,
    required IriTerm documentIri,
    required String Function(T p1) convert,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<RemoteUploadResult> uploadRaw(
    String fileId,
    List<int> bytes, {
    required String ifMatch,
    required IriTerm documentIri,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  test('recreates folder strategy once when create hits missing parent 404',
      () async {
    final client = _FakeGDriveApiClient();
    final resourceLocator =
        LocalResourceLocator(iriTermFactory: IriTerm.validated);
    final typeIri = IriTerm.validated('https://example.com/Note');
    final documentIri =
        resourceLocator.toIri(ResourceIdentifier.document(typeIri, 'note-1'));

    var refreshCalls = 0;
    final backend = GDriveSyncBackend(
      client: client,
      folderStrategy: AppRootFolderStrategy(appFolderId: 'stale-root'),
      refreshFolderStrategy: () async {
        refreshCalls++;
        return AppRootFolderStrategy(appFolderId: 'fresh-root');
      },
      resourceLocator: resourceLocator,
      spaces: 'drive',
      contentType: 'application/trig',
      fileExtension: 'trig',
      isBinary: false,
      onAuthFailure: () async {},
    );

    final result = await backend
        .upload(Stream.value(RemoteUploadRequest<RawContent>(
          documentIri: documentIri,
          document: TextContent('content', contentType: 'application/trig'),
        )))
        .single;

    expect(result, isA<SuccessUploadResult>());
    expect(refreshCalls, 1);
    expect(client.createFolderIds, ['stale-root', 'fresh-root']);
  });
}
