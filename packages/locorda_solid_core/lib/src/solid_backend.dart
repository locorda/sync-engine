import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

import 'auth/solid_auth_provider.dart';
import 'solid_config.dart';
import 'solid_profile_parser.dart';

final _log = Logger('SolidRemoteStorage');

/// Creates an HTTP client with automatic retry on network errors.
///
/// Uses [RetryClient] from package:http to retry failed requests up to 3 times
/// with exponential backoff (500ms, 1s, 2s).
///
/// Retries on:
/// - Network/connection errors (SocketException, IOException, ClientException)
/// - HTTP 503 Service Unavailable
/// - HTTP 408 Request Timeout
///
/// Does NOT retry on:
/// - 4xx client errors (except 408)
/// - 401 Unauthorized (auth issues)
/// - 404 Not Found
/// - 409 Conflict (optimistic locking)
http.Client _createRetryClient(http.Client inner) {
  return RetryClient(
    inner,
    retries: 3,
    when: (response) {
      // Retry on 503 Service Unavailable or 408 Request Timeout
      return response.statusCode == 503 || response.statusCode == 408;
    },
    whenError: (error, stackTrace) {
      // Retry on network/connection errors
      _log.fine('Network error, will retry: $error');
      return true;
    },
    delay: (retryCount) {
      // Exponential backoff: 500ms, 1s, 2s
      final delay = Duration(milliseconds: 500 * (1 << retryCount));
      _log.fine('Retry attempt $retryCount, waiting ${delay.inMilliseconds}ms');
      return delay;
    },
  );
}

class SolidBackend implements ClassicBackend {
  String get name => 'solid';

  final SolidAuthProvider _authProvider;
  final IriTermFactory _iriTermFactory;
  final SolidClient _solidClient;
  final RdfCore _rdfCore;
  final String _contentType;
  final String _datasetContentType;
  final SolidConfig _config;
  List<RemoteStorage> _remotes = [];
  late final BehaviorSubject<List<RemoteStorage>> _remotesChangedSubject;

  SolidBackend({
    required SolidAuthProvider auth,
    required IriTermFactory iriTermFactory,
    required http.Client httpClient,
    required RdfCore rdfCore,
    required String contentType,
    required String datasetContentType,
    SolidConfig config = const SolidConfig(),
  })  : _authProvider = auth,
        _iriTermFactory = iriTermFactory,
        _solidClient = SolidClient(
          client: _createRetryClient(httpClient),
          authProvider: auth,
        ),
        _contentType = contentType,
        _datasetContentType = datasetContentType,
        _rdfCore = rdfCore,
        _config = config {
    _remotesChangedSubject = BehaviorSubject<List<RemoteStorage>>();
    auth.isAuthenticatedNotifier.addListener(_authStateChanged);
    // initialize based on current auth state
    _authStateChanged();
  }

  void _authStateChanged() {
    _log.info('Authentication state changed: '
        'isAuthenticated=${_authProvider.isAuthenticatedNotifier.isAuthenticated}, webId=${_authProvider.currentWebId}');
    if (_authProvider.isAuthenticatedNotifier.isAuthenticated) {
      final webId = _authProvider.currentWebId;
      if (webId == null) {
        throw StateError(
            'User is authenticated but currentWebId is null in SolidBackend');
      }
      if (_remotes.length == 1 &&
          _remotes.first is SolidRemoteStorage &&
          (_remotes.first as SolidRemoteStorage).webId == webId) {
        // No change in authentication state
        _log.fine('No change in Solid remote storage for webId=$webId');
        return;
      }
      _log.info(
          'User logged in: initializing Solid remote storage for webId=$webId');
      // User logged in: initialize remote storage
      final baseRemote = SolidRemoteStorage(
        webId: webId,
        client: _solidClient,
        iriTermFactory: _iriTermFactory,
        rdfCore: _rdfCore,
        contentType: _contentType,
        datasetContentType: _datasetContentType,
        config: _config,
      );

      // Wrap with auth-aware retry logic
      _remotes = [
        AuthAwareRemoteStorage(
          inner: baseRemote,
          onAuthFailure: () async {
            _log.info('Auth failure detected, requesting token refresh');
            await _authProvider.refreshToken(
                reason: 'Authentication failed during sync operation');
          },
          config: const AuthRetryConfig.retryOnce(),
        )
      ];

      // Emit remote change
      _remotesChangedSubject.add(_remotes);
    } else {
      _log.info('User logged out: clearing Solid remote storage');
      // User logged out: clear remote storage
      _remotes = [];

      // Emit remote change
      _remotesChangedSubject.add(_remotes);
    }
  }

  @override
  Future<void> dispose() async {
    _authProvider.isAuthenticatedNotifier.removeListener(_authStateChanged);
    await _remotesChangedSubject.close();
  }

  @override
  List<RemoteStorage> get remotes => _remotes;

  @override
  Stream<List<RemoteStorage>> get remotesChanged =>
      _remotesChangedSubject.stream;

  @override
  String toString() => 'SolidBackend(config:${_config})';
}

class SolidClientException implements Exception {
  final String message;
  SolidClientException(this.message);

  @override
  String toString() => 'SolidClientException: $message';
}

class NotFoundException implements SolidClientException {
  final String message;
  NotFoundException(this.message);

  @override
  String toString() => 'NotFoundException: $message';
}

class SolidClient {
  final http.Client _client;
  final SolidAuthProvider _authProvider;

  SolidClient({
    required http.Client client,
    required SolidAuthProvider authProvider,
  })  : _client = client,
        _authProvider = authProvider;

  Future<RemoteDownloadResult<T>> download<T>(
    String url, {
    bool requiresAuth = true,
    String? ifNoneMatch,
    required IriTerm documentIri,
    required String acceptContentType,
    required T Function(String, {String? documentUrl, String? mimeType})
        convert,
  }) async {
    final dpop = requiresAuth
        ? await _authProvider.getDpopToken(_prepareUrlForDpopToken(url), 'GET')
        : null;

    _log.fine('GET $url with auth=${requiresAuth}');
    if (dpop != null) {
      _log.finer('Authorization: DPoP ${dpop.accessToken.substring(0, 20)}...');
      _log.finer('DPoP token length: ${dpop.dPoP.length}');
    }

    final response = await _client.get(
      Uri.parse(url),
      headers: {
        'Accept':
            acceptContentType, // 'text/turtle, application/ld+json;q=0.9, */*;q=0.8',
        if (dpop != null) 'Authorization': 'DPoP ${dpop.accessToken}',
        if (dpop != null) 'DPoP': dpop.dPoP,
        if (ifNoneMatch != null) 'If-None-Match': ifNoneMatch,
      },
    );

    _log.fine('Response status: ${response.statusCode}');

    if (response.statusCode == 401) {
      _log.warning('401 Unauthorized for $url - authentication required');
      throw AuthException(
        'Solid Pod authentication failed for $url',
        cause: 'HTTP 401 Unauthorized',
      );
    }

    if (response.statusCode == 404) {
      //throw NotFoundException('Resource not found at $url');
      return RemoteDownloadResult(
        documentIri: documentIri,
        requestETag: ifNoneMatch,
        graph: null,
        etag: null,
      );
    }
    if (response.statusCode == 304) {
      // Not modified
      return RemoteDownloadResult.notModified(
        documentIri: documentIri,
        requestETag: ifNoneMatch,
        etag: ifNoneMatch!,
      );
    }
    if (response.statusCode != 200) {
      _log.warning('Failed to fetch $url: ${response.statusCode}');
      _log.warning('Response body: ${response.body}');
      throw SolidClientException(
          'Failed to fetch $url: ${response.statusCode}');
    }

    final contentType = response.headers['content-type'] ?? '';
    final data = response.body;

    // Extract MIME type from content-type header (remove charset and other parameters)
    final mimeType = contentType.split(';').first.trim();
    final graph = convert(data, documentUrl: url, mimeType: mimeType);
    return RemoteDownloadResult(
      documentIri: documentIri,
      requestETag: ifNoneMatch,
      graph: graph,
      etag: response.headers['etag'],
    );
  }

  // Important: '=' characters in URLs must be percent-encoded here
  // because they will be automatically percent-encoded when the url is sent
  // to the server and the challenge verification will fail otherwise.
  //
  // Those '=' characters often appear due to base64 encoding of the iri type in the pod URL.
  String _prepareUrlForDpopToken(String url) => url.replaceAll('=', '%3D');

  /// Fetch current ETag for a resource using HEAD request
  Future<String?> _fetchETag(String url, {bool requiresAuth = true}) async {
    final dpop = requiresAuth
        ? await _authProvider.getDpopToken(_prepareUrlForDpopToken(url), 'HEAD')
        : null;

    _log.fine('HEAD $url with auth=${requiresAuth}');

    final response = await _client.head(
      Uri.parse(url),
      headers: {
        if (dpop != null) 'Authorization': 'DPoP ${dpop.accessToken}',
        if (dpop != null) 'DPoP': dpop.dPoP,
      },
    );

    if (response.statusCode == 200) {
      return response.headers['etag'];
    }

    _log.warning('HEAD request failed for $url: ${response.statusCode}');
    return null;
  }

  Future<RemoteUploadResult> upload<T>(String url, T graph,
      {bool requiresAuth = true,
      String? ifMatch,
      required IriTerm documentIri,
      required String Function(T) convert}) async {
    final turtle = convert(graph);
    final dpop = requiresAuth
        ? await _authProvider.getDpopToken(_prepareUrlForDpopToken(url), 'PUT')
        : null;

    _log.fine('PUT $url with auth=${requiresAuth}');
    if (dpop != null) {
      _log.finer('Authorization: DPoP ${dpop.accessToken.substring(0, 20)}...');
      _log.finer('DPoP token length: ${dpop.dPoP.length}');
    }

    final response = await _client.put(
      Uri.parse(url),
      body: turtle,
      headers: {
        'Content-Type': 'text/turtle',
        'Accept': 'text/turtle, application/ld+json;q=0.9, */*;q=0.8',
        if (dpop != null) 'Authorization': 'DPoP ${dpop.accessToken}',
        if (dpop != null) 'DPoP': dpop.dPoP,
        if (ifMatch != null) 'If-Match': ifMatch,
        if (ifMatch == null) 'If-None-Match': '*',
      },
    );

    _log.fine('Response status: ${response.statusCode}');

    if (response.statusCode == 401) {
      _log.warning('401 Unauthorized for $url - authentication required');
      throw AuthException(
        'Solid Pod authentication failed for $url',
        cause: 'HTTP 401 Unauthorized',
      );
    }

    if (response.statusCode == 404) {
      throw NotFoundException('Resource not found at $url');
    }
    if (response.statusCode == 409) {
      // Conflict
      return RemoteUploadResult.conflict(
        documentIri: documentIri,
        requestETag: ifMatch,
      );
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      var etag = response.headers['etag'];
      if (etag == null) {
        _log.fine('No ETag in PUT response from $url, fetching via HEAD');
        etag = await _fetchETag(url, requiresAuth: requiresAuth);
        if (etag == null) {
          _log.warning('Could not fetch ETag via HEAD for $url');
        }
      }

      return RemoteUploadResult.success(
        etag ?? '',
        documentIri: documentIri,
        requestETag: ifMatch,
      );
    }
    _log.warning('Failed to upload to $url: ${response.statusCode}');
    _log.warning('Response body: ${response.body}');
    throw SolidClientException(
        'Failed to upload to $url: ${response.statusCode}');
  }
}

// FIXME: A proper resource locator for Solid would need to:
// - Read from the user's profile to find the type index
// - Ask the user to edit the type index if necessary
// - Allow the user to decline type index editing
// - Handle changing configurations - maybe by maintaining a database
//   mapping from internal resource IRIs to Pod URLs - possbly supported
//   by embedding the internal resource IRI in the document itself.
//
// For now, we just hardcode the logic for the paths.
class SolidResourceLocator extends ResourceLocator {
  final IriTermFactory _iriTermFactory;
  final String _podBaseUrl;

  SolidResourceLocator(
      {required IriTermFactory iriTermFactory, required String podBaseUrl})
      : _iriTermFactory = iriTermFactory,
        _podBaseUrl = podBaseUrl;

  @override
  bool isIdentifiableIri(IriTerm subjectIri) {
    if (!subjectIri.value.startsWith(_podBaseUrl)) {
      return false;
    }
    return super.isIdentifiableIri(subjectIri);
  }

  @override
  IriTerm toIri(ResourceIdentifier identifier) {
    // For Solid, we assume the ResourceIdentifier is a full URL
    final typeIri = identifier.typeIri;
    final String basePath;
    // FIXME: This is soooo ugly! We need to find a better way - at least via the type registry
    final typeUrlPart = base64UrlEncode(utf8.encode(typeIri.value));
    if (typeIri != IdxFullIndex.classIri &&
        typeIri != IdxGroupIndex.classIri &&
        typeIri != IdxShard.classIri &&
        typeIri != IdxGroupIndexTemplate.classIri) {
      basePath = '${_podBaseUrl}data/$typeUrlPart/';
    } else {
      basePath = '${_podBaseUrl}indices/$typeUrlPart/';
    }
    // FIXME: We assume identifier.id to be URL-safe. I think that this is actually
    // a sensible requirement, but we did not enforce it anywhere.
    //final parts = identifier.id.split('/').map(Uri.encodeComponent).join('/');
    final parts = identifier.id;
    return _iriTermFactory(basePath +
        parts +
        (identifier.fragment != null ? '#${identifier.fragment}' : ''));
  }

  ResourceIdentifier fromIri(IriTerm resourceIri, {IriTerm? expectedTypeIri}) {
    final iriValue = resourceIri.value;
    if (!iriValue.startsWith(_podBaseUrl)) {
      throw UnsupportedIriException(
          resourceIri, 'does not belong to Pod base URL $_podBaseUrl');
    }
    final relativePath = iriValue.substring(_podBaseUrl.length);
    final segments = relativePath.split('/');
    if (segments.length < 3) {
      throw UnsupportedIriException(
          resourceIri, 'is not a valid Solid resource IRI');
    }

    final typeUrlPart = segments[1];
    final typeIriValue = utf8.decode(base64Url.decode(typeUrlPart));
    final typeIri = _iriTermFactory(typeIriValue);
    if (expectedTypeIri != null && typeIri != expectedTypeIri) {
      throw UnsupportedIriException(resourceIri,
          'with type ${typeIri.value} does not match expected type IRI ${expectedTypeIri.value}.');
    }
    final idParts = segments.sublist(2);
    final idAndFragment = idParts.join('/').split('#');
    final id = idAndFragment[0];
    final fragment = idAndFragment.length > 1 ? idAndFragment[1] : null;
    return fragment != null
        ? ResourceIdentifier(typeIri, id, fragment)
        : ResourceIdentifier.document(typeIri, id);
  }
}

class SolidRemoteStorage implements RemoteStorage {
  final String webId;
  final SolidClient _client;
  final IriTermFactory _iriTermFactory;
  final SolidProfileParser _profileParser = SolidProfileParser();
  final RdfCore _rdfCore;
  final String _contentType;
  final String _datasetContentType;
  final SolidConfig _config;

  late final Future<String> _podUrlFuture;

  SolidRemoteStorage({
    required this.webId,
    required SolidClient client,
    required IriTermFactory iriTermFactory,
    required RdfCore rdfCore,
    required String contentType,
    required String datasetContentType,
    required SolidConfig config,
  })  : _client = client,
        _iriTermFactory = iriTermFactory,
        _rdfCore = rdfCore,
        _contentType = contentType,
        _datasetContentType = datasetContentType,
        _config = config {
    _podUrlFuture = _resolvePodUrl(webId);
  }

  // Performance reasons suggest to use shard datasets, but that would
  // not be really good Solid practice since solid is based on linked data principles
  // and on the idea that we have resources identified by IRIs described by separate documents.
  @override
  bool get useShardDatasets => _config.useShardDatasets;

  Future<String> _resolvePodUrl(String webId) async {
    final profile = await _client.download(
      webId,
      requiresAuth: true,
      documentIri: IriTerm.validated(webId),
      acceptContentType: 'text/turtle, application/ld+json;q=0.9, */*;q=0.8',
      convert: (data, {documentUrl, mimeType}) => _rdfCore.decode(data,
          contentType: mimeType ?? 'text/turtle', documentUrl: documentUrl),
    );
    if (profile.graph == null) {
      throw StateError('Profile document is empty for WebID: $webId');
    }

    final podUrl = await _profileParser.parseStorageUrl(webId, profile.graph!);
    if (podUrl == null) {
      throw StateError('Could not resolve Pod URL for WebID: $webId');
    }
    return podUrl.endsWith('/') ? podUrl : '$podUrl/';
  }

  @override
  Future<bool> isAvailable() {
    // TODO: implement availability check, maybe by using some API to
    // check for online/offline status or similar.
    return _podUrlFuture.then((_) => true).catchError((e) {
      _log.severe(
          'Error resolving Pod URL for webId=$webId (will disable solid sync): $e');
      return false;
    });
  }

  @override
  RemoteId get remoteId => RemoteId("solid", webId);

  @override
  Future<RemoteSyncStorage> createSyncStorage(SyncEngineConfig config) async {
    // Solid uses Type Index pattern - no backend-specific setup needed
    // Type registrations are handled by the application via Solid Type Index
    final podUrl = await _podUrlFuture; // Ensure Pod URL is resolved

    final iriTranslator = BaseIriTranslator(
        internalResourceLocator:
            LocalResourceLocator(iriTermFactory: _iriTermFactory),
        externalResourceLocator: SolidResourceLocator(
            iriTermFactory: _iriTermFactory, podBaseUrl: podUrl));

    final storage = SolidSyncStorage(
      client: _client,
      contentType: _contentType,
      datasetContentType: _datasetContentType,
      rdfCore: _rdfCore,
      config: _config,
    );

    return IriTranslatingRemoteSyncStorage(
      storage: storage,
      iriTranslator: iriTranslator,
    );
  }

  @override
  Future<void> dispose() {
    // No resources to dispose for Solid remote storage
    return Future.value();
  }

  @override
  String toString() {
    return 'SolidRemoteStorage(webId: $webId, podUrl: ${_podUrlFuture}, config: $_config)';
  }
}

/// Per-sync-session storage for Solid backend.
///
/// Caches the IRI translator to avoid rebuilding it on every upload/download.
class SolidSyncStorage extends RemoteSyncStorage {
  final SolidClient _client;
  final String _contentType;
  final String _datasetContentType;

  final RdfCore _rdfCore;
  final SolidConfig _config;

  SolidSyncStorage({
    required SolidClient client,
    required String contentType,
    required String datasetContentType,
    required RdfCore rdfCore,
    required SolidConfig config,
  })  : _client = client,
        _contentType = contentType,
        _datasetContentType = datasetContentType,
        _rdfCore = rdfCore,
        _config = config;

  @override
  int get maxConcurrentDocumentSyncs => _config.maxConcurrentDocumentSyncs;

  @override
  int get maxConcurrentIndexSyncs => _config.maxConcurrentIndexSyncs;

  @override
  int get maxConcurrentShardSyncs => _config.maxConcurrentShardSyncs;

  @override
  Future<RemoteDownloadResult<RdfGraph>> download(IriTerm documentIri,
          {String? ifNoneMatch}) =>
      _download(
        documentIri,
        ifNoneMatch: ifNoneMatch,
        acceptContentType: _contentType,
        convert: (data, {documentUrl, mimeType}) => _rdfCore.decode(data,
            contentType: mimeType ?? _contentType, documentUrl: documentUrl),
      );

  @override
  Future<RemoteDownloadResult<RdfDataset>> downloadDataset(IriTerm documentIri,
          {String? ifNoneMatch}) =>
      _download(
        documentIri,
        ifNoneMatch: ifNoneMatch,
        acceptContentType: _datasetContentType,
        convert: (data, {documentUrl, mimeType}) => _rdfCore.decodeDataset(data,
            contentType: mimeType ?? _datasetContentType,
            documentUrl: documentUrl),
      );

  Future<RemoteDownloadResult<T>> _download<T>(
    IriTerm documentIri, {
    String? ifNoneMatch,
    required String acceptContentType,
    required T Function(String, {String? documentUrl, String? mimeType})
        convert,
  }) async {
    final podDocumentIri = documentIri;
    final result = await _client.download<T>(
      podDocumentIri.value,
      requiresAuth: true,
      documentIri: documentIri,
      acceptContentType: acceptContentType,
      ifNoneMatch: ifNoneMatch,
      convert: convert,
    );
    if (result.graph != null) {
      return RemoteDownloadResult<T>(
        documentIri: result.documentIri,
        requestETag: result.requestETag,
        graph: result.graph!,
        etag: result.etag,
        notModified: result.notModified,
      );
    }
    return result;
  }

  @override
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfGraph graph,
      {String? ifMatch}) async {
    final podDocumentIri = documentIri;
    final translatedGraph = graph;
    return await _client.upload(
      podDocumentIri.value,
      translatedGraph,
      requiresAuth: true,
      ifMatch: ifMatch,
      documentIri: documentIri,
      convert: (graph) => _rdfCore.encode(graph, contentType: _contentType),
    );
  }

  Future<RemoteUploadResult> uploadDataset(
      IriTerm documentIri, RdfDataset dataset,
      {String? ifMatch}) async {
    final podDocumentIri = documentIri;
    final translatedGraph = dataset;
    return await _client.upload(
      podDocumentIri.value,
      translatedGraph,
      requiresAuth: true,
      ifMatch: ifMatch,
      documentIri: documentIri,
      convert: (dataset) =>
          _rdfCore.encodeDataset(dataset, contentType: _datasetContentType),
    );
  }

  @override
  Future<void> finalizeSync() async {
    // No cleanup needed for Solid backend
  }

  @override
  String toString() {
    return 'SolidSyncStorage(config: $_config)';
  }
}
