import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_gdrive/src/gdrive_api.dart';
import 'package:locorda_gdrive/src/gdrive_backend_mirror.dart';
import 'package:locorda_gdrive/src/gdrive_folder_strategy.dart';
import 'package:locorda_gdrive/src/gdrive_type_index_manager.dart';
import 'package:locorda_gdrive/src/shared/gdrive_config.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:path/path.dart' as path;

class _FakeRemoteFile {
  _FakeRemoteFile({
    required this.fileId,
    required this.bytes,
    required this.path,
  }) : md5Checksum = md5.convert(bytes).toString();

  final String fileId;
  final String path;
  List<int> bytes;
  String md5Checksum;
}

class FakeGDriveClient implements GDriveApiClient {
  FakeGDriveClient();

  final Map<String, _FakeRemoteFile> filesById = {};
  final List<GDriveListedEntry> listedEntries = [];
  int _nextId = 0;
  final Set<String> deletedIds = {};

  @override
  Future<List<GDriveListedEntry>> listFilesRecursively({
    required String rootFolderId,
    required String spaces,
    required int maxConcurrentRequests,
  }) async {
    return listedEntries;
  }

  @override
  Future<List<int>> downloadRawBytes(String fileId) async {
    if (deletedIds.contains(fileId)) {
      throw StateError('Missing file: $fileId');
    }
    final file = filesById[fileId];
    if (file == null) throw StateError('Missing file: $fileId');
    return file.bytes;
  }

  @override
  Future<({String fileId, String md5Checksum})> createFileRaw(
    String filename,
    List<int> bytes, {
    required String folderId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
    required String contentType,
  }) async {
    final id = 'new-${_nextId++}';
    final path = filename;
    final file = _FakeRemoteFile(fileId: id, bytes: bytes, path: path);
    filesById[id] = file;
    deletedIds.remove(id);
    listedEntries.add(GDriveListedEntry(
      fileId: id,
      path: path,
      isFolder: false,
      md5Checksum: file.md5Checksum,
      headRevisionId: 'rev-$id',
      version: '1',
    ));
    return (fileId: id, md5Checksum: file.md5Checksum);
  }

  @override
  Future<RemoteUploadResult> uploadRaw(
    String fileId,
    List<int> bytes, {
    required String ifMatch,
    required IriTerm documentIri,
  }) async {
    if (deletedIds.contains(fileId)) {
      throw GDriveClientException('File not found: $fileId');
    }
    final file = filesById[fileId];
    if (file == null) throw StateError('Missing file: $fileId');
    if (file.md5Checksum != ifMatch) {
      return RemoteUploadResult.conflict(
        documentIri: documentIri,
        requestETag: ifMatch,
      );
    }
    file.bytes = bytes;
    file.md5Checksum = md5.convert(bytes).toString();
    return RemoteUploadResult.success(
      file.md5Checksum,
      documentIri: documentIri,
      requestETag: ifMatch,
    );
  }

  @override
  Future<RemoteUploadResult> upload<T>(
    String fileId,
    T updatedGraph, {
    required String ifMatch,
    required IriTerm documentIri,
    required String Function(T) convert,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<({T? graph, String? etag, bool notModified})> download<T>(
      String fileId,
      {String? ifNoneMatch,
      required T Function(String) convert}) {
    throw UnimplementedError();
  }

  @override
  Future<({List<int>? bytes, String? etag, bool notModified})> downloadRaw(
      String fileId,
      {String? ifNoneMatch}) async {
    if (deletedIds.contains(fileId)) {
      throw StateError('Missing file: $fileId');
    }
    final file = filesById[fileId];
    if (file == null) throw StateError('Missing file: $fileId');
    if (ifNoneMatch != null && file.md5Checksum == ifNoneMatch) {
      return (bytes: null, etag: ifNoneMatch, notModified: true);
    }
    return (bytes: file.bytes, etag: file.md5Checksum, notModified: false);
  }

  @override
  Future<String?> findFile({
    required String fileName,
    required String parentId,
    bool fileNameMayBeRelativePath = false,
    String spaces = 'drive',
  }) {
    throw UnimplementedError();
  }

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
    required String Function(T) convert,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> dispose() {
    return Future.value();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('GDriveLocalMirror initializes cache and serves local downloads',
      () async {
    final rdfCore =
        RdfCore.withStandardCodecs(iriTermFactory: IriTerm.validated);
    final client = FakeGDriveClient();

    final typeIri = IriTerm.validated('https://example.com/Note');
    final locator = LocalResourceLocator(iriTermFactory: IriTerm.validated);
    final docIri =
        locator.toIri(ResourceIdentifier.document(typeIri, 'note-1'));

    final graph = RdfGraph(triples: {
      Triple(
        docIri,
        IriTerm.validated('https://example.com/predicate'),
        LiteralTerm.string('value'),
      ),
    });
    final bytes = utf8.encode(rdfCore.encode(graph));
    final md5Checksum = md5.convert(bytes).toString();

    final fileId = 'file-1';
    client.filesById[fileId] =
        _FakeRemoteFile(fileId: fileId, bytes: bytes, path: 'Note/note-1.ttl');
    client.listedEntries.add(GDriveListedEntry(
      fileId: fileId,
      path: 'Note/note-1.ttl',
      isFolder: false,
      md5Checksum: md5Checksum,
      headRevisionId: 'rev-1',
      version: '1',
    ));

    final tempDir = await Directory.systemTemp.createTemp('gdrive-mirror-test');
    final mirrorConfig = GDriveLocalMirrorConfig(
      cacheRootPath: tempDir.path,
      maxConcurrentDownloads: 4,
      maxConcurrentListings: 2,
      maxConcurrentUploads: 2,
    );

    final mirror = await GDriveLocalMirror.initialize(
      client: client,
      folderStrategyProvider: (_) async =>
          TypeIndexFolderStrategy(TypeIndexMappings(
        appFolderId: 'root',
        typeMappings: {
          typeIri: const TypeMapping(folderId: 'folder-1', folderName: 'Note'),
        },
      )),
      resourceLocator: locator,
      config: mirrorConfig,
      spaces: 'drive',
      userId: 'user-1',
      appFolderProvider: () => Future.value('root'),
      fileExtension: 'ttl',
    );

    final download = await mirror.download(docIri, convert: rdfCore.decode);
    final success = download as SuccessDownloadResult<RdfGraph>;
    expect(success.graph, isNotNull);
    expect(success.etag, md5Checksum);

    final mirrorIndex = File(
      '${tempDir.path}/locorda_gdrive_cache/${base64Url.encode(utf8.encode('user-1'))}/drive/index.json',
    );
    expect(await mirrorIndex.exists(), isTrue);
  });

  test('GDriveLocalMirror uploads locally and finalizes remote updates',
      () async {
    final rdfCore =
        RdfCore.withStandardCodecs(iriTermFactory: IriTerm.validated);
    final client = FakeGDriveClient();

    final typeIri = IriTerm.validated('https://example.com/Note');
    final locator = LocalResourceLocator(iriTermFactory: IriTerm.validated);
    final docIri =
        locator.toIri(ResourceIdentifier.document(typeIri, 'note-2'));

    final graph = RdfGraph(triples: {
      Triple(
        docIri,
        IriTerm.validated('https://example.com/predicate'),
        LiteralTerm.string('value'),
      ),
    });
    final bytes = utf8.encode(rdfCore.encode(graph));
    final md5Checksum = md5.convert(bytes).toString();

    final fileId = 'file-2';
    client.filesById[fileId] =
        _FakeRemoteFile(fileId: fileId, bytes: bytes, path: 'Note/note-2.ttl');
    client.listedEntries.add(GDriveListedEntry(
      fileId: fileId,
      path: 'Note/note-2.ttl',
      isFolder: false,
      md5Checksum: md5Checksum,
      headRevisionId: 'rev-2',
      version: '1',
    ));

    final tempDir = await Directory.systemTemp.createTemp('gdrive-mirror-test');
    final mirrorConfig = GDriveLocalMirrorConfig(
      cacheRootPath: tempDir.path,
    );

    final mirror = await GDriveLocalMirror.initialize(
      client: client,
      folderStrategyProvider: (_) async =>
          TypeIndexFolderStrategy(TypeIndexMappings(
        appFolderId: 'root',
        typeMappings: {
          typeIri: const TypeMapping(folderId: 'folder-1', folderName: 'Note'),
        },
      )),
      resourceLocator: locator,
      config: mirrorConfig,
      spaces: 'drive',
      userId: 'user-2',
      appFolderProvider: () => Future.value('root'),
      fileExtension: 'ttl',
    );

    final updatedGraph = RdfGraph(triples: {
      Triple(
        docIri,
        IriTerm.validated('https://example.com/predicate'),
        LiteralTerm.string('updated'),
      ),
    });

    final uploadResult = await mirror.upload(docIri, updatedGraph,
        ifMatch: md5Checksum,
        contentType: 'text/turtle',
        convert: rdfCore.encode);
    expect(uploadResult, isA<SuccessUploadResult>());

    await mirror.finalize();

    final remoteFile = client.filesById[fileId]!;
    final updatedMd5 = md5.convert(remoteFile.bytes).toString();
    expect(updatedMd5, isNot(md5Checksum));
  });

  test('GDriveLocalMirror recreates missing remote file on finalize', () async {
    final rdfCore =
        RdfCore.withStandardCodecs(iriTermFactory: IriTerm.validated);
    final client = FakeGDriveClient();

    final typeIri = IriTerm.validated('https://example.com/Note');
    final locator = LocalResourceLocator(iriTermFactory: IriTerm.validated);
    final docIri =
        locator.toIri(ResourceIdentifier.document(typeIri, 'note-3'));

    final graph = RdfGraph(triples: {
      Triple(
        docIri,
        IriTerm.validated('https://example.com/predicate'),
        LiteralTerm.string('value'),
      ),
    });
    final bytes = utf8.encode(rdfCore.encode(graph));
    final md5Checksum = md5.convert(bytes).toString();

    final fileId = 'file-3';
    client.filesById[fileId] =
        _FakeRemoteFile(fileId: fileId, bytes: bytes, path: 'Note/note-3.ttl');
    client.listedEntries.add(GDriveListedEntry(
      fileId: fileId,
      path: 'Note/note-3.ttl',
      isFolder: false,
      md5Checksum: md5Checksum,
      headRevisionId: 'rev-3',
      version: '1',
    ));

    final tempDir = await Directory.systemTemp.createTemp('gdrive-mirror-test');
    final mirrorConfig = GDriveLocalMirrorConfig(
      cacheRootPath: tempDir.path,
    );

    final mirror = await GDriveLocalMirror.initialize(
      client: client,
      folderStrategyProvider: (_) async =>
          TypeIndexFolderStrategy(TypeIndexMappings(
        appFolderId: 'root',
        typeMappings: {
          typeIri: const TypeMapping(folderId: 'folder-1', folderName: 'Note'),
        },
      )),
      resourceLocator: locator,
      config: mirrorConfig,
      spaces: 'drive',
      userId: 'user-3',
      appFolderProvider: () => Future.value('root'),
      fileExtension: 'ttl',
    );

    final updatedGraph = RdfGraph(triples: {
      Triple(
        docIri,
        IriTerm.validated('https://example.com/predicate'),
        LiteralTerm.string('updated'),
      ),
    });

    final uploadResult = await mirror.upload(
      docIri,
      updatedGraph,
      ifMatch: md5Checksum,
      contentType: 'text/turtle',
      convert: rdfCore.encode,
    );
    expect(uploadResult, isA<SuccessUploadResult>());

    client.deletedIds.add(fileId);

    await mirror.finalize();

    expect(client.filesById.length, greaterThan(1));
    final recreated = client.filesById.values.firstWhere(
      (file) => file.fileId != fileId,
    );
    final recreatedMd5 = md5.convert(recreated.bytes).toString();
    expect(recreatedMd5, isNot(md5Checksum));
  });

  test('GDriveMirrorTypeIndexBackend stores the type index in the mirror',
      () async {
    final client = FakeGDriveClient();
    final tempDir = await Directory.systemTemp.createTemp('gdrive-mirror-test');
    final mirrorConfig = GDriveLocalMirrorConfig(
      cacheRootPath: tempDir.path,
      maxConcurrentDownloads: 1,
      maxConcurrentListings: 1,
      maxConcurrentUploads: 1,
    );

    String? createdFileId;
    String? createdEtag;
    String? downloadedContent;
    RemoteUploadResult? uploadResult;

    await GDriveLocalMirror.initialize(
      client: client,
      folderStrategyProvider: (backend) async {
        final created = await backend.createFile(
          'gdrive-index.ttl',
          'initial',
          folderId: 'root',
          spaces: 'drive',
          contentType: 'text/turtle',
          convert: (value) => value,
        );
        createdFileId = created.fileId;
        createdEtag = created.etag;

        final downloaded = await backend.download<String>(
          created.fileId,
          convert: (value) => value,
        );
        downloadedContent = downloaded.graph;

        uploadResult = await backend.upload<String>(
          created.fileId,
          'updated',
          ifMatch: created.etag,
          convert: (value) => value,
        );

        return TypeIndexFolderStrategy(TypeIndexMappings(
          appFolderId: 'root',
          typeMappings: {},
        ));
      },
      resourceLocator: LocalResourceLocator(iriTermFactory: IriTerm.validated),
      config: mirrorConfig,
      spaces: 'drive',
      userId: 'user-type-index',
      appFolderProvider: () => Future.value('root'),
      fileExtension: 'ttl',
    );

    final userSegment = base64Url.encode(utf8.encode('user-type-index'));
    final rootDir = path.join(
      tempDir.path,
      'locorda_gdrive_cache',
      userSegment,
      'drive',
    );
    final typeIndexFile = File(path.join(rootDir, 'files', 'gdrive-index.ttl'));

    expect(createdFileId, 'gdrive-index.ttl');
    expect(createdEtag, isNotNull);
    expect(downloadedContent, 'initial');
    expect(uploadResult, isA<SuccessUploadResult>());
    expect(await typeIndexFile.exists(), isTrue);
    expect(await typeIndexFile.readAsString(), 'updated');
  });

  test('GDriveLocalMirror removes entries missing on remote', () async {
    final client = FakeGDriveClient();

    final typeIri = IriTerm.validated('https://example.com/Note');
    final locator = LocalResourceLocator(iriTermFactory: IriTerm.validated);

    final tempDir = await Directory.systemTemp.createTemp('gdrive-mirror-test');
    final mirrorConfig = GDriveLocalMirrorConfig(
      cacheRootPath: tempDir.path,
    );

    final mirrorRoot = Directory(
      '${tempDir.path}/locorda_gdrive_cache/${base64Url.encode(utf8.encode('user-4'))}/drive',
    );
    final filesDir = Directory('${mirrorRoot.path}/files/Note');
    await filesDir.create(recursive: true);

    final staleFile = File('${filesDir.path}/note-4.ttl');
    await staleFile.writeAsString('stale');

    final indexFile = File('${mirrorRoot.path}/index.json');
    await indexFile.writeAsString(jsonEncode({
      'version': 1,
      'updatedAt': DateTime.now().toIso8601String(),
      'entries': [
        {
          'path': 'Note/note-4.ttl',
          'fileId': 'file-4',
          'remoteMd5': 'md5-4',
          'localMd5': 'md5-4',
          'headRevisionId': 'rev-4',
          'version': '1',
          'contentType': 'text/turtle',
          'dirty': false,
          'localOnly': false,
        }
      ],
    }));

    // ignore: unused_local_variable
    final mirror = await GDriveLocalMirror.initialize(
      client: client,
      folderStrategyProvider: (_) async =>
          TypeIndexFolderStrategy(TypeIndexMappings(
        appFolderId: 'root',
        typeMappings: {
          typeIri: const TypeMapping(folderId: 'folder-1', folderName: 'Note'),
        },
      )),
      resourceLocator: locator,
      config: mirrorConfig,
      spaces: 'drive',
      userId: 'user-4',
      appFolderProvider: () => Future.value('root'),
      fileExtension: 'ttl',
    );

    expect(await staleFile.exists(), isFalse);
  });
}
