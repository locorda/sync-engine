import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_gdrive/src/gdrive_api.dart';
import 'package:locorda_gdrive/src/gdrive_backend_mirror.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

import 'auth/gdrive_auth_provider.dart';
import 'gdrive_type_index_manager.dart';
import 'shared/gdrive_config.dart';

final _log = Logger('GDriveBackend');

class GDriveSyncStorage extends BaseGDriveSyncStorage {
  final GDriveApiClient _client;

  final TypeIndexMappings _typeIndexMappings;
  final ResourceLocator _resourceLocator;
  final String _spaces;

  GDriveSyncStorage({
    required GDriveApiClient client,
    required TypeIndexMappings typeIndexMappings,
    required ResourceLocator resourceLocator,
    required String spaces,
    required super.rdfCore,
    required super.contentType,
    required super.datasetContentType,
    required super.config,
  })  : _client = client,
        _typeIndexMappings = typeIndexMappings,
        _resourceLocator = resourceLocator,
        _spaces = spaces;

  Future<RemoteDownloadResult<T>> downloadDocument<T>(IriTerm documentIri,
      {String? ifNoneMatch, required T Function(String) convert}) async {
    final docIri = _resourceLocator.fromIri(documentIri);
    final folderId = _typeIndexMappings.getFolderId(docIri.typeIri);
    final filePath = docIri.id;
    final fileId = await _client.findFile(
        parentId: folderId,
        fileName: filePath,
        fileNameMayBeRelativePath: true,
        spaces: _spaces);
    if (fileId == null) {
      return RemoteDownloadResult(
        documentIri: documentIri,
        requestETag: ifNoneMatch,
        graph: null,
        etag: null,
        notModified: false,
      );
    }
    final result = await _client.download(fileId,
        ifNoneMatch: ifNoneMatch, convert: convert);
    if (result.notModified) {
      return RemoteDownloadResult.notModified(
        documentIri: documentIri,
        requestETag: ifNoneMatch,
        etag: result.etag!,
      );
    }
    if (result.graph == null) {
      return RemoteDownloadResult(
        documentIri: documentIri,
        requestETag: ifNoneMatch,
        graph: null,
        etag: result.etag,
        notModified: false,
      );
    }
    return RemoteDownloadResult(
      documentIri: documentIri,
      requestETag: ifNoneMatch,
      graph: result.graph!,
      etag: result.etag,
      notModified: false,
    );
  }

  Future<RemoteUploadResult> uploadDocument<T>(
    IriTerm documentIri,
    T graph, {
    String? ifMatch,
    required String contentType,
    required String Function(T) convert,
  }) async {
    final docIri = _resourceLocator.fromIri(documentIri);
    final folderId = _typeIndexMappings.getFolderId(docIri.typeIri);
    final filePath = docIri.id;
    final fileId = await _client.findFile(
        parentId: folderId,
        fileName: filePath,
        fileNameMayBeRelativePath: true,
        spaces: _spaces);

    if (fileId == null) {
      // Create new file
      final created = await _client.createFile(
        filePath,
        graph,
        folderId: folderId,
        fileNameMayBeRelativePath: true,
        spaces: _spaces,
        contentType: contentType,
        convert: convert,
      );
      return SuccessUploadResult(
        created.etag,
        documentIri: documentIri,
        requestETag: ifMatch,
      );
    } else {
      // Update existing file
      return await _client.upload(
        fileId,
        graph,
        ifMatch: ifMatch!,
        documentIri: documentIri,
        convert: convert,
      );
    }
  }
}

abstract class BaseGDriveSyncStorage extends RemoteSyncStorage {
  final RdfCore _rdfCore;
  final String _contentType;
  final String _datasetContentType;
  final GDriveConfig _config;

  BaseGDriveSyncStorage({
    required RdfCore rdfCore,
    required String contentType,
    required String datasetContentType,
    required GDriveConfig config,
  })  : _config = config,
        _contentType = contentType,
        _datasetContentType = datasetContentType,
        _rdfCore = rdfCore;

  @override
  int get maxConcurrentDocumentSyncs => _config.maxConcurrentDocumentSyncs;
  @override
  int get maxConcurrentIndexSyncs => _config.maxConcurrentIndexSyncs;
  @override
  int get maxConcurrentShardSyncs => _config.maxConcurrentShardSyncs;

  @override
  Future<RemoteDownloadResult<RdfGraph>> download(IriTerm documentIri,
          {String? ifNoneMatch}) =>
      downloadDocument<RdfGraph>(
        documentIri,
        ifNoneMatch: ifNoneMatch,
        convert: (content) =>
            _rdfCore.decode(content, contentType: _contentType),
      );

  @override
  Future<RemoteDownloadResult<RdfDataset>> downloadDataset(IriTerm documentIri,
          {String? ifNoneMatch}) =>
      downloadDocument<RdfDataset>(
        documentIri,
        ifNoneMatch: ifNoneMatch,
        convert: (content) => _rdfCore.decodeDataset(
          content,
          contentType: _datasetContentType,
        ),
      );

  Future<RemoteDownloadResult<T>> downloadDocument<T>(IriTerm documentIri,
      {String? ifNoneMatch, required T Function(String) convert});

  @override
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfGraph graph,
          {String? ifMatch}) =>
      uploadDocument<RdfGraph>(
        documentIri,
        graph,
        ifMatch: ifMatch,
        contentType: _contentType,
        convert: (content) =>
            _rdfCore.encode(content, contentType: _contentType),
      );

  @override
  Future<RemoteUploadResult> uploadDataset(
          IriTerm documentIri, RdfDataset dataset,
          {String? ifMatch}) =>
      uploadDocument<RdfDataset>(
        documentIri,
        dataset,
        ifMatch: ifMatch,
        contentType: _datasetContentType,
        convert: (content) => _rdfCore.encodeDataset(
          content,
          contentType: _datasetContentType,
        ),
      );

  Future<RemoteUploadResult> uploadDocument<T>(
    IriTerm documentIri,
    T graph, {
    String? ifMatch,
    required String contentType,
    required String Function(T) convert,
  });

  @override
  Future<void> finalizeSync() async {
    // nothing to do
  }
}

class MirroredGDriveSyncStorage extends BaseGDriveSyncStorage {
  final GDriveLocalMirror _localMirror;

  MirroredGDriveSyncStorage({
    required super.rdfCore,
    required super.contentType,
    required super.datasetContentType,
    required super.config,
    required GDriveLocalMirror localMirror,
  }) : _localMirror = localMirror;

  Future<RemoteDownloadResult<T>> downloadDocument<T>(IriTerm documentIri,
      {String? ifNoneMatch, required T Function(String) convert}) async {
    return _localMirror.download(
      documentIri,
      ifNoneMatch: ifNoneMatch,
      convert: convert,
    );
  }

  Future<RemoteUploadResult> uploadDocument<T>(
    IriTerm documentIri,
    T graph, {
    String? ifMatch,
    required String contentType,
    required String Function(T) convert,
  }) async {
    return _localMirror.upload(
      documentIri,
      graph,
      ifMatch: ifMatch,
      convert: convert,
      contentType: contentType,
    );
  }

  @override
  Future<void> finalizeSync() async {
    await _localMirror.finalize();
  }
}

class GDriveRemoteStorage implements RemoteStorage {
  final RemoteId _remoteId;
  final String _userId;
  final GDriveApiClient _client;
  final ResourceLocator _resourceLocator;
  final String _spaces;
  final GDriveLocalMirrorConfig _mirrorConfig;
  final RdfCore _rdfCore;
  final String _contentType;
  final String _datasetContentType;
  final GDriveConfig _config;
  final AppFolderProvider _appFolderProvider;
  final IriTermFactory _iriTermFactory;

  // Severely reduces the number of files that have to be transferred between
  // the client and Google Drive, improving performance significantly.
  //
  // This means that all resources of a given shard are stored within
  // the shard file with the help of rdf datasets, instead of storing
  // a single file per rdf graph.
  @override
  bool get useShardDatasets => _config.useShardDatasets;

  GDriveRemoteStorage({
    required GDriveApiClient client,
    required String userId,
    required ResourceLocator resourceLocator,
    required String spaces,
    required GDriveLocalMirrorConfig mirrorConfig,
    required IriTermFactory iriTermFactory,
    required RdfCore rdfCore,
    required String contentType,
    required String datasetContentType,
    required AppFolderProvider appFolderProvider,
    required GDriveConfig config,
  })  : _client = client,
        _userId = userId,
        _config = config,
        _resourceLocator = resourceLocator,
        _spaces = spaces,
        _mirrorConfig = mirrorConfig,
        _remoteId = RemoteId("google", userId),
        _rdfCore = rdfCore,
        _iriTermFactory = iriTermFactory,
        _contentType = contentType,
        _appFolderProvider = appFolderProvider,
        _datasetContentType = datasetContentType;

  RemoteId get remoteId => _remoteId;

  @override
  Future<RemoteSyncStorage> createSyncStorage(
      SyncEngineConfig engineConfig) async {
    if (_mirrorConfig.enabled) {
      GDriveLocalMirror? mirror = await GDriveLocalMirror.initialize(
        client: _client,
        typeIndexMappingsProvider: (backend) {
          final typeIndexManager = GDriveTypeIndexManager(
            backend: backend,
            iriTermFactory: _iriTermFactory,
            config: _config,
            rdfCore: _rdfCore,
            appFolderProvider: _appFolderProvider,
          );
          return typeIndexManager.loadOrCreateTypeIndex(engineConfig);
        },
        resourceLocator: _resourceLocator,
        config: _mirrorConfig,
        spaces: _spaces,
        userId: _userId,
        appFolderProvider: () => _appFolderProvider.appFolderId,
      );
      return MirroredGDriveSyncStorage(
        rdfCore: _rdfCore,
        contentType: _contentType,
        datasetContentType: _datasetContentType,
        config: _config,
        localMirror: mirror,
      );
    }
    final typeIndexManager = GDriveTypeIndexManager(
      backend: GDriveTypeIndexManagerBackend(client: _client),
      iriTermFactory: _iriTermFactory,
      config: _config,
      rdfCore: _rdfCore,
      appFolderProvider: _appFolderProvider,
    );
    final typeIndexMappings =
        await typeIndexManager.loadOrCreateTypeIndex(engineConfig);

    return GDriveSyncStorage(
      client: _client,
      resourceLocator: _resourceLocator,
      typeIndexMappings: typeIndexMappings,
      spaces: _spaces,
      rdfCore: _rdfCore,
      contentType: _contentType,
      datasetContentType: _datasetContentType,
      config: _config,
    );
  }

  @override
  Future<bool> isAvailable() {
    // TODO: implement availability check, maybe by using some API to
    // check for online/offline status or similar.
    return Future.value(true);
  }

  @override
  Future<void> dispose() {
    return Future.value();
  }
}

class GDriveBackend implements ClassicBackend {
  @override
  String get name => 'gdrive';
  final GDriveAuthProvider _auth;
  final GDriveApiClient _client;
  final IriTermFactory _iriTermFactory;
  final ResourceLocator _resourceLocator;
  final GDriveConfig _config;
  final RdfCore _rdfCore;
  final String _contentType;
  final String _datasetContentType;
  final AppFolderProvider _appFolderProvider;

  List<RemoteStorage> _remotes = [];
  late final BehaviorSubject<List<RemoteStorage>> _remotesChangedSubject;

  static Backend create({
    required GDriveAuthProvider auth,
    required GDriveConfig config,
    IriTermFactory? iriTermFactory,
    required RdfCore rdfCore,
    required http.Client httpClient,
    required String contentType,
    required String datasetContentType,
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
      //  PerfLogGDriveApiClient(client, perflog: perflog)
      client: client,
      iriTermFactory: iriTermFactory,
      contentType: contentType,
      datasetContentType: datasetContentType,
      rdfCore: rdfCore,
      appFolderProvider: appFolderProvider,
    );
    if (perflog != Perflog.disabled) {
      return PerflogBackend(backend, perflog: perflog, name: 'gdrive');
    }
    return backend;
  }

  GDriveBackend._({
    required GDriveAuthProvider auth,
    required GDriveApiClient client,
    required GDriveConfig config,
    required RdfCore rdfCore,
    required String contentType,
    required String datasetContentType,
    required AppFolderProvider appFolderProvider,
    IriTermFactory? iriTermFactory,
  })  : _auth = auth,
        _client = client,
        _config = config,
        _appFolderProvider = appFolderProvider,
        _iriTermFactory = iriTermFactory ?? IriTerm.validated,
        _resourceLocator = LocalResourceLocator(
          iriTermFactory: iriTermFactory ?? IriTerm.validated,
        ),
        _rdfCore = rdfCore,
        _contentType = contentType,
        _datasetContentType = datasetContentType {
    _remotesChangedSubject = BehaviorSubject<List<RemoteStorage>>();
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
        // No change in authentication state
        _log.fine('No change in GDrive remote storage for userId=$userId');
        return;
      }
      _log.info(
          'User logged in: initializing GDrive remote storage for userId=$userId');
      // User logged in: initialize remote storage
      final spaces = _config.folderMode == GDriveFolderMode.appDataFolder
          ? 'appDataFolder'
          : 'drive';

      final baseRemote = GDriveRemoteStorage(
        userId: userId,
        client: _client,
        iriTermFactory: _iriTermFactory,
        resourceLocator: _resourceLocator,
        spaces: spaces,
        mirrorConfig: _config.localMirrorConfig,
        contentType: _contentType,
        datasetContentType: _datasetContentType,
        rdfCore: _rdfCore,
        config: _config,
        appFolderProvider: _appFolderProvider,
      );

      // Wrap with auth-aware retry logic
      _remotes = [
        AuthAwareRemoteStorage(
          inner: baseRemote,
          onAuthFailure: () async {
            _log.info('Auth failure detected, requesting token refresh');
            await _auth.refreshToken(
                reason: 'Authentication failed during sync operation');
          },
          config: const AuthRetryConfig.retryOnce(),
        )
      ];

      // Emit remote change
      _remotesChangedSubject.add(_remotes);
    } else {
      _log.info('User logged out: clearing GDrive remote storage');
      // User logged out: clear remote storage
      _remotes = [];

      // Emit remote change
      _remotesChangedSubject.add(_remotes);
    }
  }

  @override
  List<RemoteStorage> get remotes => _remotes;

  @override
  Stream<List<RemoteStorage>> get remotesChanged =>
      _remotesChangedSubject.stream;

  @override
  Future<void> dispose() async {
    _auth.isAuthenticatedNotifier.removeListener(_authStateChanged);
    await _remotesChangedSubject.close();
  }
}
