import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_gdrive/src/gdrive_api.dart';
import 'package:locorda_gdrive/src/gdrive_backend_mirror.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

import 'auth/gdrive_auth_provider.dart';
import 'gdrive_folder_strategy.dart';
import 'gdrive_type_index_manager.dart';
import 'shared/gdrive_config.dart';

final _log = Logger('GDriveBackend');
const _isWeb = bool.fromEnvironment('dart.library.js_interop');

bool shouldUseLocalMirror({
  required bool mirrorEnabled,
  required bool isWeb,
}) {
  return mirrorEnabled && !isWeb;
}

class GDriveSyncBackend implements RemoteSyncBackend {
  final GDriveApiClient _client;
  GDriveFolderStrategy _folderStrategy;
  final ResourceLocator _resourceLocator;
  final String _spaces;
  final String _contentType;
  final String _fileExtension;
  final bool _isBinary;
  final Future<void> Function() _onAuthFailure;
  final Future<GDriveFolderStrategy> Function()? _refreshFolderStrategy;

  GDriveSyncBackend({
    required GDriveApiClient client,
    required GDriveFolderStrategy folderStrategy,
    required ResourceLocator resourceLocator,
    required String spaces,
    required String contentType,
    required String fileExtension,
    required bool isBinary,
    required Future<void> Function() onAuthFailure,
    Future<GDriveFolderStrategy> Function()? refreshFolderStrategy,
  })  : _client = client,
        _folderStrategy = folderStrategy,
        _resourceLocator = resourceLocator,
        _spaces = spaces,
        _contentType = contentType,
        _fileExtension = fileExtension,
        _isBinary = isBinary,
        _onAuthFailure = onAuthFailure,
        _refreshFolderStrategy = refreshFolderStrategy;

  @override
  Stream<RemoteDownloadResult<RawContent>> download(
      Stream<RemoteDownloadRequest> requests) async* {
    await for (final request in requests) {
      try {
        yield await retryOnAuthFailure(
          config: const AuthRetryConfig.retryOnce(),
          onAuthFailure: _onAuthFailure,
          operation: () => _downloadOne(request),
        );
      } catch (e, st) {
        yield ErrorDownloadResult<RawContent>(
          documentIri: request.documentIri,
          requestETag: request.ifNoneMatch,
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  Future<RemoteDownloadResult<RawContent>> _downloadOne(
      RemoteDownloadRequest request) async {
    final docIri = _resourceLocator.fromIri(request.documentIri);
    final folderId = _folderStrategy.folderIdFor(docIri.typeIri);
    final fileId = await _client.findFile(
      parentId: folderId,
      fileName: '${docIri.id}.$_fileExtension',
      fileNameMayBeRelativePath: true,
      spaces: _spaces,
    );
    if (fileId == null) {
      return NotFoundDownloadResult<RawContent>(
        documentIri: request.documentIri,
        requestETag: request.ifNoneMatch,
      );
    }

    if (_isBinary) {
      final result = await _client.downloadRaw(
        fileId,
        ifNoneMatch: request.ifNoneMatch,
      );
      if (result.notModified) {
        return NotModifiedDownloadResult<RawContent>(
          documentIri: request.documentIri,
          requestETag: request.ifNoneMatch,
          etag: result.etag ?? request.ifNoneMatch ?? '',
        );
      }
      if (result.bytes == null) {
        return NotFoundDownloadResult<RawContent>(
          documentIri: request.documentIri,
          requestETag: request.ifNoneMatch,
        );
      }
      return SuccessDownloadResult<RawContent>(
        documentIri: request.documentIri,
        requestETag: request.ifNoneMatch,
        graph: BinaryContent(Uint8List.fromList(result.bytes!),
            contentType: _contentType),
        etag: result.etag ?? '',
      );
    }

    final result = await _client.download<String>(
      fileId,
      ifNoneMatch: request.ifNoneMatch,
      convert: (content) => content,
    );
    if (result.notModified) {
      return NotModifiedDownloadResult<RawContent>(
        documentIri: request.documentIri,
        requestETag: request.ifNoneMatch,
        etag: result.etag ?? request.ifNoneMatch ?? '',
      );
    }
    if (result.graph == null) {
      return NotFoundDownloadResult<RawContent>(
        documentIri: request.documentIri,
        requestETag: request.ifNoneMatch,
      );
    }
    return SuccessDownloadResult<RawContent>(
      documentIri: request.documentIri,
      requestETag: request.ifNoneMatch,
      graph: TextContent(result.graph!, contentType: _contentType),
      etag: result.etag ?? '',
    );
  }

  @override
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> requests) async* {
    await for (final request in requests) {
      try {
        yield await retryOnAuthFailure(
          config: const AuthRetryConfig.retryOnce(),
          onAuthFailure: _onAuthFailure,
          operation: () => _uploadOne(request),
        );
      } catch (e, st) {
        yield ErrorUploadResult(
          documentIri: request.documentIri,
          requestETag: request.ifMatch,
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  Future<RemoteUploadResult> _uploadOne(
      RemoteUploadRequest<RawContent> request) async {
    final docIri = _resourceLocator.fromIri(request.documentIri);
    final folderId = _folderStrategy.folderIdFor(docIri.typeIri);
    final filePath = '${docIri.id}.$_fileExtension';
    final fileId = await _client.findFile(
      parentId: folderId,
      fileName: filePath,
      fileNameMayBeRelativePath: true,
      spaces: _spaces,
    );

    final bytes = switch (request.document) {
      TextContent(:final text) => utf8.encode(text),
      BinaryContent(:final bytes) => bytes,
    };

    if (fileId == null) {
      final created = await _createFileRawWithFolderRecovery(
        documentIri: request.documentIri,
        filePath: filePath,
        bytes: bytes,
        contentType: request.document.contentType,
        initialFolderId: folderId,
      );
      return SuccessUploadResult(
        created.md5Checksum,
        documentIri: request.documentIri,
        requestETag: request.ifMatch,
      );
    }

    if (request.ifMatch == null) {
      return RemoteUploadResult.conflict(
        documentIri: request.documentIri,
        requestETag: request.ifMatch,
      );
    }

    return _client.uploadRaw(
      fileId,
      bytes,
      ifMatch: request.ifMatch!,
      documentIri: request.documentIri,
    );
  }

  Future<({String fileId, String md5Checksum})>
      _createFileRawWithFolderRecovery({
    required IriTerm documentIri,
    required String filePath,
    required List<int> bytes,
    required String contentType,
    required String initialFolderId,
  }) async {
    try {
      return await _client.createFileRaw(
        filePath,
        bytes,
        folderId: initialFolderId,
        fileNameMayBeRelativePath: true,
        spaces: _spaces,
        contentType: contentType,
      );
    } on GDriveClientException catch (error) {
      if (!_isMissingParentFolderError(error) ||
          _refreshFolderStrategy == null) {
        rethrow;
      }

      _log.warning(
          'Parent folder missing while creating $filePath. Refreshing folder strategy and retrying once.');
      _folderStrategy = await _refreshFolderStrategy();
      final docIri = _resourceLocator.fromIri(documentIri);
      final refreshedFolderId = _folderStrategy.folderIdFor(docIri.typeIri);
      return _client.createFileRaw(
        filePath,
        bytes,
        folderId: refreshedFolderId,
        fileNameMayBeRelativePath: true,
        spaces: _spaces,
        contentType: contentType,
      );
    }
  }

  bool _isMissingParentFolderError(GDriveClientException error) =>
      error.statusCode == 404;

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {}
}

class GDriveMirrorSyncBackend implements RemoteSyncBackend {
  final GDriveLocalMirror _localMirror;
  final String _contentType;
  final bool _isBinary;
  final Future<void> Function() _onAuthFailure;

  GDriveMirrorSyncBackend({
    required GDriveLocalMirror localMirror,
    required String contentType,
    required bool isBinary,
    required Future<void> Function() onAuthFailure,
  })  : _localMirror = localMirror,
        _contentType = contentType,
        _isBinary = isBinary,
        _onAuthFailure = onAuthFailure;

  @override
  Stream<RemoteDownloadResult<RawContent>> download(
      Stream<RemoteDownloadRequest> requests) async* {
    await for (final request in requests) {
      try {
        yield await retryOnAuthFailure(
          config: const AuthRetryConfig.retryOnce(),
          onAuthFailure: _onAuthFailure,
          operation: () => _downloadOne(request),
        );
      } catch (e, st) {
        yield ErrorDownloadResult<RawContent>(
          documentIri: request.documentIri,
          requestETag: request.ifNoneMatch,
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  Future<RemoteDownloadResult<RawContent>> _downloadOne(
      RemoteDownloadRequest request) async {
    if (_isBinary) {
      final result = await _localMirror.downloadRaw(
        request.documentIri,
        ifNoneMatch: request.ifNoneMatch,
      );
      return switch (result) {
        SuccessDownloadResult(:final graph, :final etag) =>
          SuccessDownloadResult<RawContent>(
            documentIri: result.documentIri,
            requestETag: result.requestETag,
            graph: BinaryContent(Uint8List.fromList(graph),
                contentType: _contentType),
            etag: etag,
          ),
        NotModifiedDownloadResult(:final etag) =>
          NotModifiedDownloadResult<RawContent>(
            documentIri: result.documentIri,
            requestETag: result.requestETag,
            etag: etag,
          ),
        NotFoundDownloadResult() => NotFoundDownloadResult<RawContent>(
            documentIri: result.documentIri,
            requestETag: result.requestETag,
          ),
        ErrorDownloadResult(:final error, :final stackTrace) =>
          ErrorDownloadResult<RawContent>(
            documentIri: result.documentIri,
            requestETag: result.requestETag,
            error: error,
            stackTrace: stackTrace,
          ),
      };
    }

    final result = await _localMirror.download<String>(
      request.documentIri,
      ifNoneMatch: request.ifNoneMatch,
      convert: (content) => content,
    );
    return switch (result) {
      SuccessDownloadResult(:final graph, :final etag) =>
        SuccessDownloadResult<RawContent>(
          documentIri: result.documentIri,
          requestETag: result.requestETag,
          graph: TextContent(graph, contentType: _contentType),
          etag: etag,
        ),
      NotModifiedDownloadResult(:final etag) =>
        NotModifiedDownloadResult<RawContent>(
          documentIri: result.documentIri,
          requestETag: result.requestETag,
          etag: etag,
        ),
      NotFoundDownloadResult() => NotFoundDownloadResult<RawContent>(
          documentIri: result.documentIri,
          requestETag: result.requestETag,
        ),
      ErrorDownloadResult(:final error, :final stackTrace) =>
        ErrorDownloadResult<RawContent>(
          documentIri: result.documentIri,
          requestETag: result.requestETag,
          error: error,
          stackTrace: stackTrace,
        ),
    };
  }

  @override
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> requests) async* {
    await for (final request in requests) {
      try {
        yield await retryOnAuthFailure(
          config: const AuthRetryConfig.retryOnce(),
          onAuthFailure: _onAuthFailure,
          operation: () => _uploadOne(request),
        );
      } catch (e, st) {
        yield ErrorUploadResult(
          documentIri: request.documentIri,
          requestETag: request.ifMatch,
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  Future<RemoteUploadResult> _uploadOne(
      RemoteUploadRequest<RawContent> request) {
    final bytes = switch (request.document) {
      TextContent(:final text) => utf8.encode(text),
      BinaryContent(:final bytes) => bytes,
    };
    return _localMirror.uploadRaw(
      request.documentIri,
      bytes,
      ifMatch: request.ifMatch,
      contentType: request.document.contentType,
    );
  }

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {
    if (state is! SyncFinalizationSuccess) {
      return;
    }
    await retryOnAuthFailure(
      config: const AuthRetryConfig.retryOnce(),
      onAuthFailure: _onAuthFailure,
      operation: _localMirror.finalize,
    );
  }
}

class GDriveRemoteStorage implements PipelineRemoteStorage {
  final RemoteId _remoteId;
  final String _userId;
  final GDriveApiClient _client;
  final ResourceLocator _resourceLocator;
  final String _spaces;
  final GDriveLocalMirrorConfig _mirrorConfig;
  final BackendStorageAccess _storageAccess;
  final RdfCore _rdfCore;
  final GDriveConfig _config;
  final AppFolderProvider _appFolderProvider;
  final IriTermFactory _iriTermFactory;
  final Future<void> Function() _onAuthFailure;

  GDriveRemoteStorage({
    required GDriveApiClient client,
    required String userId,
    required ResourceLocator resourceLocator,
    required String spaces,
    required GDriveLocalMirrorConfig mirrorConfig,
    required BackendStorageAccess storageAccess,
    required IriTermFactory iriTermFactory,
    required RdfCore rdfCore,
    required AppFolderProvider appFolderProvider,
    required GDriveConfig config,
    required Future<void> Function() onAuthFailure,
  })  : _client = client,
        _userId = userId,
        _config = config,
        _resourceLocator = resourceLocator,
        _spaces = spaces,
        _mirrorConfig = mirrorConfig,
        _storageAccess = storageAccess,
        _remoteId = RemoteId('google', userId),
        _rdfCore = rdfCore,
        _iriTermFactory = iriTermFactory,
        _appFolderProvider = appFolderProvider,
        _onAuthFailure = onAuthFailure;

  @override
  RemoteId get remoteId => _remoteId;

  @override
  Future<PipelineRemoteSyncStorage> createPipelineSyncStorage(
      SyncEngineConfig engineConfig) {
    return retryOnAuthFailure(
      config: const AuthRetryConfig.retryOnce(),
      onAuthFailure: _onAuthFailure,
      operation: () => _createPipelineSyncStorage(engineConfig),
    );
  }

  Future<PipelineRemoteSyncStorage> _createPipelineSyncStorage(
      SyncEngineConfig engineConfig) async {
    final layout = _config.layout;
    final contentType = layout.contentType;
    final isBinary = _rdfCore.contentTypeInfo(contentType)?.isBinary ?? false;
    // Mirror only makes sense for FilePerResource: it uses folder/file paths
    // derived from the type index. SingleFile and ShardDataset put all files
    // in the app root, which the mirror's path logic cannot handle.
    final useMirror = shouldUseLocalMirror(
          mirrorEnabled: _mirrorConfig.enabled,
          isWeb: _isWeb,
        ) &&
        layout is FilePerResource;

    if (useMirror) {
      final mirror = await GDriveLocalMirror.initialize(
        client: _client,
        folderStrategyProvider: (backend) async {
          final typeIndexManager = GDriveTypeIndexManager(
            backend: backend,
            iriTermFactory: _iriTermFactory,
            config: _config,
            rdfCore: _rdfCore,
            appFolderProvider: _appFolderProvider,
          );
          final mappings = await typeIndexManager.loadOrCreateTypeIndex(
            _collectRequiredTypes(engineConfig),
          );
          return TypeIndexFolderStrategy(mappings);
        },
        resourceLocator: _resourceLocator,
        config: _mirrorConfig,
        spaces: _spaces,
        userId: _userId,
        appFolderProvider: () => _appFolderProvider.appFolderId,
        fileExtension: layout.fileExtension,
      );
      return RemoteSyncStorages.create(
        layout: layout,
        backend: GDriveMirrorSyncBackend(
          localMirror: mirror,
          contentType: contentType,
          isBinary: isBinary,
          onAuthFailure: _onAuthFailure,
        ),
        rdfCore: _rdfCore,
        storageAccess: _storageAccess,
      );
    }

    if (_mirrorConfig.enabled && !useMirror) {
      _log.info(
          'GDrive local mirror is enabled in config but disabled at runtime'
          '${_isWeb ? ' on web' : ' for ${layout.runtimeType} layout'}. '
          'Falling back to direct remote sync backend.');
    }

    final folderStrategy = await _createFolderStrategy(engineConfig, layout);

    return RemoteSyncStorages.create(
      layout: layout,
      backend: GDriveSyncBackend(
        client: _client,
        folderStrategy: folderStrategy,
        refreshFolderStrategy: () =>
            _refreshFolderStrategy(engineConfig, layout),
        resourceLocator: _resourceLocator,
        spaces: _spaces,
        contentType: contentType,
        fileExtension: layout.fileExtension,
        isBinary: isBinary,
        onAuthFailure: _onAuthFailure,
      ),
      rdfCore: _rdfCore,
      storageAccess: _storageAccess,
    );
  }

  /// Builds the [GDriveFolderStrategy] appropriate for [layout].
  ///
  /// [FilePerResource] requires the type index (one Drive folder per type).
  /// [SingleFile] and [ShardDataset] store all files directly in the app
  /// root folder — no type index is needed or created.
  Future<GDriveFolderStrategy> _createFolderStrategy(
      SyncEngineConfig engineConfig, RemoteStorageLayout layout) async {
    if (layout is FilePerResource) {
      final typeIndexManager = GDriveTypeIndexManager(
        backend: GDriveTypeIndexManagerBackend(client: _client),
        iriTermFactory: _iriTermFactory,
        config: _config,
        rdfCore: _rdfCore,
        appFolderProvider: _appFolderProvider,
      );
      final mappings = await typeIndexManager.loadOrCreateTypeIndex(
        _collectRequiredTypes(engineConfig),
      );
      return TypeIndexFolderStrategy(mappings);
    }
    // SingleFile, ShardDataset: flat layout, all files in app root
    final appFolderId = await _appFolderProvider.appFolderId;
    return AppRootFolderStrategy(appFolderId: appFolderId);
  }

  Future<GDriveFolderStrategy> _refreshFolderStrategy(
      SyncEngineConfig engineConfig, RemoteStorageLayout layout) async {
    _appFolderProvider.invalidate();
    return _createFolderStrategy(engineConfig, layout);
  }

  /// Collects the resource type IRIs that need Drive folder mappings.
  static Set<IriTerm> _collectRequiredTypes(SyncEngineConfig engineConfig) =>
      engineConfig.resources.map((r) => r.typeIri).toSet();

  @override
  Future<bool> isAvailable() => Future.value(true);

  @override
  Future<void> dispose() => Future.value();
}

class GDriveBackend implements PipelineBackend {
  @override
  String get name => 'gdrive';

  final GDriveAuthProvider _auth;
  final GDriveApiClient _client;
  final IriTermFactory _iriTermFactory;
  final ResourceLocator _resourceLocator;
  final GDriveConfig _config;
  final RdfCore _rdfCore;
  final BackendStorageAccessFactory _storageAccessFactory;
  final AppFolderProvider _appFolderProvider;

  List<PipelineRemoteStorage> _remotes = [];
  late final BehaviorSubject<List<PipelineRemoteStorage>>
      _remotesChangedSubject;

  static Backend create({
    required GDriveAuthProvider auth,
    required GDriveConfig config,
    IriTermFactory? iriTermFactory,
    required RdfCore rdfCore,
    required http.Client httpClient,
    required BackendStorageAccessFactory storageAccessFactory,
    required Perflog perflog,
  }) {
    final client = GDriveClient(
      authProvider: auth,
      httpClient: httpClient,
      perflog: perflog,
    );
    final appFolderProvider = AppFolderProvider(client: client, config: config);
    final backend = GDriveBackend._(
      auth: auth,
      config: config,
      client: client,
      iriTermFactory: iriTermFactory,
      rdfCore: rdfCore,
      storageAccessFactory: storageAccessFactory,
      appFolderProvider: appFolderProvider,
    );
    if (perflog != Perflog.disabled) {
      return PerflogPipelineBackend(backend, perflog: perflog, name: 'gdrive');
    }
    return backend;
  }

  GDriveBackend._({
    required GDriveAuthProvider auth,
    required GDriveApiClient client,
    required GDriveConfig config,
    required RdfCore rdfCore,
    required BackendStorageAccessFactory storageAccessFactory,
    required AppFolderProvider appFolderProvider,
    IriTermFactory? iriTermFactory,
  })  : _auth = auth,
        _client = client,
        _config = config,
        _rdfCore = rdfCore,
        _storageAccessFactory = storageAccessFactory,
        _appFolderProvider = appFolderProvider,
        _iriTermFactory = iriTermFactory ?? IriTerm.validated,
        _resourceLocator = LocalResourceLocator(
          iriTermFactory: iriTermFactory ?? IriTerm.validated,
        ) {
    _remotesChangedSubject = BehaviorSubject<List<PipelineRemoteStorage>>();
    _auth.isAuthenticatedNotifier.addListener(_authStateChanged);
    _authStateChanged();
  }

  void _authStateChanged() {
    _log.info('Authentication state changed: '
        'isAuthenticated=${_auth.isAuthenticatedNotifier.isAuthenticated}, userId=${_auth.userId}');
    if (_auth.isAuthenticatedNotifier.isAuthenticated) {
      final userId = _auth.userId;
      if (userId == null) {
        throw StateError(
            'User is authenticated but userId is null in GDriveBackend');
      }
      if (_remotes.length == 1 &&
          _remotes.first is GDriveRemoteStorage &&
          (_remotes.first as GDriveRemoteStorage)._userId == userId) {
        _log.fine('No change in GDrive remote storage for userId=$userId');
        return;
      }
      _log.info(
          'User logged in: initializing GDrive remote storage for userId=$userId');
      final spaces = _config.folderMode == GDriveFolderMode.appDataFolder
          ? 'appDataFolder'
          : 'drive';

      _remotes = [
        GDriveRemoteStorage(
          userId: userId,
          client: _client,
          iriTermFactory: _iriTermFactory,
          resourceLocator: _resourceLocator,
          spaces: spaces,
          mirrorConfig: _config.localMirrorConfig,
          storageAccess:
              _storageAccessFactory.forRemote(RemoteId('google', userId)),
          rdfCore: _rdfCore,
          config: _config,
          appFolderProvider: _appFolderProvider,
          onAuthFailure: () async {
            _log.info('Auth failure detected, requesting token refresh');
            await _auth.refreshToken(
              reason: 'Authentication failed during sync operation',
            );
          },
        )
      ];
      _remotesChangedSubject.add(_remotes);
      return;
    }

    _log.info('User logged out: clearing GDrive remote storage');
    _remotes = [];
    _remotesChangedSubject.add(_remotes);
  }

  @override
  List<PipelineRemoteStorage> get pipelineRemotes => _remotes;

  @override
  Stream<List<PipelineRemoteStorage>> get pipelineRemotesChanged =>
      _remotesChangedSubject.stream;

  @override
  Future<void> dispose() async {
    _auth.isAuthenticatedNotifier.removeListener(_authStateChanged);
    await _remotesChangedSubject.close();
  }
}
