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
/// - 401 Unauthorized (auth issues handled via [AuthException])
/// - 404 Not Found
/// - 409 Conflict (optimistic locking)
http.Client _createRetryClient(http.Client inner) {
  return RetryClient(
    inner,
    retries: 3,
    when: (response) =>
        response.statusCode == 503 || response.statusCode == 408,
    whenError: (error, stackTrace) {
      _log.fine('Network error, will retry: $error');
      return true;
    },
    delay: (retryCount) {
      final delay = Duration(milliseconds: 500 * (1 << retryCount));
      _log.fine('Retry attempt $retryCount, waiting ${delay.inMilliseconds}ms');
      return delay;
    },
  );
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

// ---------------------------------------------------------------------------
// SolidBackend
// ---------------------------------------------------------------------------

/// [PipelineBackend] implementation that syncs to a Solid Pod.
///
/// Listens for auth-state changes from [SolidAuthProvider] and exposes
/// [SolidRemoteStorage] instances that translate internal locorda IRIs to
/// Pod-native URLs via [SolidResourceLocator].
class SolidBackend implements PipelineBackend {
  @override
  String get name => 'solid';

  final SolidAuthProvider _authProvider;
  final IriTermFactory _iriTermFactory;
  final SolidClient _solidClient;
  final RdfCore _rdfCore;
  final SolidConfig _config;
  final BackendStorageAccessFactory _storageAccessFactory;

  List<PipelineRemoteStorage> _remotes = [];
  late final BehaviorSubject<List<PipelineRemoteStorage>>
      _remotesChangedSubject;

  SolidBackend({
    required SolidAuthProvider auth,
    required IriTermFactory iriTermFactory,
    required http.Client httpClient,
    required RdfCore rdfCore,
    SolidConfig config = const SolidConfig(),
    required BackendStorageAccessFactory storageAccessFactory,
  })  : _authProvider = auth,
        _iriTermFactory = iriTermFactory,
        _solidClient = SolidClient(
          client: _createRetryClient(httpClient),
          authProvider: auth,
        ),
        _rdfCore = rdfCore,
        _config = config,
        _storageAccessFactory = storageAccessFactory {
    _remotesChangedSubject = BehaviorSubject<List<PipelineRemoteStorage>>();
    auth.isAuthenticatedNotifier.addListener(_authStateChanged);
    _authStateChanged();
  }

  void _authStateChanged() {
    _log.info('Authentication state changed: '
        'isAuthenticated=${_authProvider.isAuthenticatedNotifier.isAuthenticated}, '
        'webId=${_authProvider.currentWebId}');
    if (_authProvider.isAuthenticatedNotifier.isAuthenticated) {
      final webId = _authProvider.currentWebId;
      if (webId == null) {
        throw StateError(
            'User is authenticated but currentWebId is null in SolidBackend');
      }
      if (_remotes.length == 1 &&
          _remotes.first is SolidRemoteStorage &&
          (_remotes.first as SolidRemoteStorage).webId == webId) {
        _log.fine('No change in Solid remote storage for webId=$webId');
        return;
      }
      _log.info(
          'User logged in: initializing Solid remote storage for webId=$webId');
      _remotes = [
        SolidRemoteStorage(
          webId: webId,
          client: _solidClient,
          iriTermFactory: _iriTermFactory,
          rdfCore: _rdfCore,
          config: _config,
          storageAccessFactory: _storageAccessFactory,
          onAuthFailure: () async {
            _log.info('Auth failure detected, requesting token refresh');
            await _authProvider.refreshToken(
                reason: 'Authentication failed during sync operation');
          },
        )
      ];
      _remotesChangedSubject.add(_remotes);
    } else {
      _log.info('User logged out: clearing Solid remote storage');
      _remotes = [];
      _remotesChangedSubject.add(_remotes);
    }
  }

  @override
  Future<void> dispose() async {
    _authProvider.isAuthenticatedNotifier.removeListener(_authStateChanged);
    await _remotesChangedSubject.close();
  }

  @override
  List<PipelineRemoteStorage> get pipelineRemotes => _remotes;

  @override
  Stream<List<PipelineRemoteStorage>> get pipelineRemotesChanged =>
      _remotesChangedSubject.stream;

  @override
  String toString() => 'SolidBackend(config: $_config)';
}

// ---------------------------------------------------------------------------
// SolidRemoteStorage
// ---------------------------------------------------------------------------

/// [PipelineRemoteStorage] for a single Solid Pod identified by WebID.
///
/// Resolves the Pod base URL from the WebID profile document asynchronously
/// at construction time so that [createPipelineSyncStorage] has a concrete
/// URL available when the pipeline starts.
class SolidRemoteStorage implements PipelineRemoteStorage {
  final String webId;
  final SolidClient _client;
  final IriTermFactory _iriTermFactory;
  final SolidProfileParser _profileParser = SolidProfileParser();
  final RdfCore _rdfCore;
  final SolidConfig _config;
  final BackendStorageAccess _storageAccess;
  final Future<void> Function() _onAuthFailure;

  final RemoteId _remoteId;
  late final Future<String> _podUrlFuture;

  SolidRemoteStorage({
    required this.webId,
    required SolidClient client,
    required IriTermFactory iriTermFactory,
    required RdfCore rdfCore,
    required SolidConfig config,
    required BackendStorageAccessFactory storageAccessFactory,
    required Future<void> Function() onAuthFailure,
  })  : _client = client,
        _iriTermFactory = iriTermFactory,
        _rdfCore = rdfCore,
        _config = config,
        _storageAccess =
            storageAccessFactory.forRemote(RemoteId('solid', webId)),
        _onAuthFailure = onAuthFailure,
        _remoteId = RemoteId('solid', webId) {
    _podUrlFuture = _resolvePodUrl(webId);
  }

  @override
  RemoteId get remoteId => _remoteId;

  @override
  Future<bool> isAvailable() =>
      _podUrlFuture.then((_) => true).catchError((Object e) {
        _log.severe(
            'Error resolving Pod URL for webId=$webId (will disable solid sync): $e');
        return false;
      });

  @override
  Future<PipelineRemoteSyncStorage> createPipelineSyncStorage(
      SyncEngineConfig config) async {
    final podUrl = await _podUrlFuture;
    final layout = _config.layout;
    final isBinary =
        _rdfCore.contentTypeInfo(layout.contentType)?.isBinary ?? false;

    final iriTranslator = BaseIriTranslator(
      internalResourceLocator:
          LocalResourceLocator(iriTermFactory: _iriTermFactory),
      externalResourceLocator: SolidResourceLocator(
        iriTermFactory: _iriTermFactory,
        podBaseUrl: podUrl,
      ),
    );
    final backend = SolidSyncBackend(
      client: _client,
      contentType: layout.contentType,
      isBinary: isBinary,
      onAuthFailure: _onAuthFailure,
      documentUrlMapper: SolidPhysicalDocumentUrlMapper(
        appendFileExtension: layout is! FilePerResource,
        fileExtension: layout.fileExtension,
      ),
    );
    return RemoteSyncStorages.createIriTranslated(
      layout: layout,
      backend: backend,
      rdfCore: _rdfCore,
      storageAccess: _storageAccess,
      translator: iriTranslator,
    );
  }

  @override
  Future<void> dispose() => Future.value();

  Future<String> _resolvePodUrl(String webId) async {
    final result = await retryOnAuthFailure(
      config: const AuthRetryConfig.retryOnce(),
      onAuthFailure: _onAuthFailure,
      operation: () => _client.downloadRaw(
        webId,
        requiresAuth: true,
        documentIri: IriTerm.validated(webId),
        acceptContentType: 'text/turtle, application/ld+json;q=0.9, */*;q=0.8',
      ),
    );
    if (result is! SuccessDownloadResult<RawContent>) {
      throw StateError('Profile document not available for WebID: $webId');
    }
    final content = result.graph;
    if (content is! TextContent) {
      throw StateError('Unexpected binary profile content for WebID: $webId');
    }
    final profileGraph = _rdfCore.decode(content.text,
        contentType: content.contentType, documentUrl: webId);
    final podUrl = await _profileParser.parseStorageUrl(webId, profileGraph);
    if (podUrl == null) {
      throw StateError('Could not resolve Pod URL for WebID: $webId');
    }
    return podUrl.endsWith('/') ? podUrl : '$podUrl/';
  }

  @override
  String toString() => 'SolidRemoteStorage(webId: $webId, config: $_config)';
}

// ---------------------------------------------------------------------------
// SolidSyncBackend
// ---------------------------------------------------------------------------

/// Stream-based [RemoteSyncBackend] for Solid Pod HTTP I/O.
///
/// Handles DPoP-authenticated GET/PUT requests and retries once on
/// [AuthException] by invoking [onAuthFailure] (which refreshes the token)
/// before the retry attempt.
class SolidSyncBackend implements RemoteSyncBackend {
  final SolidClient _client;
  final String _contentType;
  final bool _isBinary;
  final Future<void> Function() _onAuthFailure;
  final SolidPhysicalDocumentUrlMapper _documentUrlMapper;

  SolidSyncBackend({
    required SolidClient client,
    required String contentType,
    required bool isBinary,
    required Future<void> Function() onAuthFailure,
    required SolidPhysicalDocumentUrlMapper documentUrlMapper,
  })  : _client = client,
        _contentType = contentType,
        _isBinary = isBinary,
        _onAuthFailure = onAuthFailure,
        _documentUrlMapper = documentUrlMapper;

  @override
  Stream<RemoteDownloadResult<RawContent>> download(
      Stream<RemoteDownloadRequest> requests) async* {
    await for (final request in requests) {
      try {
        final url = _documentUrlMapper.toDocumentUrl(request.documentIri);
        yield await retryOnAuthFailure(
          config: const AuthRetryConfig.retryOnce(),
          onAuthFailure: _onAuthFailure,
          operation: () => _client.downloadRaw(
            url,
            requiresAuth: true,
            documentIri: request.documentIri,
            ifNoneMatch: request.ifNoneMatch,
            acceptContentType: _contentType,
            isBinary: _isBinary,
          ),
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

  @override
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> requests) async* {
    await for (final request in requests) {
      try {
        final url = _documentUrlMapper.toDocumentUrl(request.documentIri);
        yield await retryOnAuthFailure(
          config: const AuthRetryConfig.retryOnce(),
          onAuthFailure: _onAuthFailure,
          operation: () => _client.upload(
            url,
            request.document,
            requiresAuth: true,
            ifMatch: request.ifMatch,
            documentIri: request.documentIri,
          ),
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

  @override
  Future<void> finalize(SyncFinalizationState state,
      {PipeperfCollector? perf}) async {}
}

/// Maps semantic document IRIs to physical Solid document URLs.
///
/// For file-per-resource layouts this is identity mapping.
/// For dataset layouts this appends the configured file extension.
class SolidPhysicalDocumentUrlMapper {
  final bool _appendFileExtension;
  final String _fileExtension;

  SolidPhysicalDocumentUrlMapper({
    required bool appendFileExtension,
    required String fileExtension,
  })  : _appendFileExtension = appendFileExtension,
        _fileExtension = fileExtension;

  String toDocumentUrl(IriTerm documentIri) {
    final url = documentIri.value;
    if (!_appendFileExtension || _fileExtension.isEmpty) {
      return url;
    }

    final uri = Uri.parse(url);
    final suffix = '.$_fileExtension';
    if (uri.path.endsWith(suffix)) {
      return url;
    }
    return uri.replace(path: '${uri.path}$suffix').toString();
  }
}

// ---------------------------------------------------------------------------
// SolidClient
// ---------------------------------------------------------------------------

/// Low-level HTTP client for Solid Pod communication with DPoP authentication.
class SolidClient {
  final http.Client _client;
  final SolidAuthProvider _authProvider;

  SolidClient({
    required http.Client client,
    required SolidAuthProvider authProvider,
  })  : _client = client,
        _authProvider = authProvider;

  /// Downloads a resource, returning raw [RawContent] (text or binary).
  ///
  /// Passing [isBinary] = true returns [BinaryContent] (from response bytes);
  /// otherwise [TextContent] (from response body decoded as UTF-8 or per
  /// charset header) is returned. The [acceptContentType] header is sent
  /// verbatim.
  Future<RemoteDownloadResult<RawContent>> downloadRaw(
    String url, {
    bool requiresAuth = true,
    String? ifNoneMatch,
    required IriTerm documentIri,
    required String acceptContentType,
    bool isBinary = false,
  }) async {
    final dpop = requiresAuth
        ? await _authProvider.getDpopToken(_prepareUrlForDpopToken(url), 'GET')
        : null;

    _log.fine(
        'GET $url auth=$requiresAuth ifNoneMatch=$ifNoneMatch accept=$acceptContentType isBinary=$isBinary');

    final response = await _client.get(
      Uri.parse(url),
      headers: {
        'Accept': acceptContentType,
        if (dpop != null) 'Authorization': 'DPoP ${dpop.accessToken}',
        if (dpop != null) 'DPoP': dpop.dPoP,
        if (ifNoneMatch != null) 'If-None-Match': ifNoneMatch,
      },
    );

    _log.fine('Response status: ${response.statusCode}');

    if (response.statusCode == 401) {
      _log.warning('401 Unauthorized for $url');
      throw AuthException(
        'Solid Pod authentication failed for $url',
        cause: 'HTTP 401 Unauthorized',
      );
    }
    if (response.statusCode == 404) {
      return NotFoundDownloadResult<RawContent>(
        documentIri: documentIri,
        requestETag: ifNoneMatch,
      );
    }
    if (response.statusCode == 304) {
      return NotModifiedDownloadResult<RawContent>(
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
    final mimeType = contentType.split(';').first.trim();
    final RawContent content = isBinary
        ? BinaryContent(response.bodyBytes, contentType: mimeType)
        : TextContent(response.body, contentType: mimeType);

    return SuccessDownloadResult<RawContent>(
      documentIri: documentIri,
      requestETag: ifNoneMatch,
      graph: content,
      etag: response.headers['etag'] ?? '',
    );
  }

  /// Uploads [content] to [url] using HTTP PUT with DPoP authentication.
  ///
  /// Uses [content.contentType] as the `Content-Type` header, fixing the
  /// previous hardcoded `text/turtle` limitation.
  Future<RemoteUploadResult> upload(
    String url,
    RawContent content, {
    bool requiresAuth = true,
    String? ifMatch,
    required IriTerm documentIri,
  }) async {
    final dpop = requiresAuth
        ? await _authProvider.getDpopToken(_prepareUrlForDpopToken(url), 'PUT')
        : null;

    _log.fine(
        'PUT $url auth=$requiresAuth ifMatch=$ifMatch contentType=${content.contentType}');

    final response = await _client.put(
      Uri.parse(url),
      body: switch (content) {
        TextContent(:final text) => text,
        BinaryContent(:final bytes) => bytes,
      },
      headers: {
        'Content-Type': content.contentType,
        if (dpop != null) 'Authorization': 'DPoP ${dpop.accessToken}',
        if (dpop != null) 'DPoP': dpop.dPoP,
        if (ifMatch != null) 'If-Match': ifMatch,
        if (ifMatch == null) 'If-None-Match': '*',
      },
    );

    _log.fine('Response status: ${response.statusCode}');

    if (response.statusCode == 401) {
      _log.warning('401 Unauthorized for $url');
      throw AuthException(
        'Solid Pod authentication failed for $url',
        cause: 'HTTP 401 Unauthorized',
      );
    }
    if (response.statusCode == 404) {
      throw NotFoundException('Resource not found at $url');
    }
    if (response.statusCode == 409) {
      // 409 Conflict is not an ETag mismatch — it signals a persistent
      // server-side conflict (e.g. WebDAV lock, invalid resource state).
      // Retrying will not help, so treat as an error.
      throw SolidClientException('Failed to upload to $url: 409 Conflict');
    }
    if (response.statusCode == 412) {
      // 412 Precondition Failed: If-Match ETag mismatch — optimistic locking
      // conflict. The resource was modified concurrently; caller should
      // re-read, re-merge and retry.
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

  // Important: '=' characters in URLs must be percent-encoded here
  // because they will be automatically percent-encoded when the url is sent
  // to the server and the challenge verification will fail otherwise.
  //
  // Those '=' characters often appear due to base64 encoding of the iri type in the pod URL.
  String _prepareUrlForDpopToken(String url) => url.replaceAll('=', '%3D');

  /// Fetches current ETag via HEAD request; returns null if unavailable.
  Future<String?> _fetchETag(String url, {bool requiresAuth = true}) async {
    final dpop = requiresAuth
        ? await _authProvider.getDpopToken(_prepareUrlForDpopToken(url), 'HEAD')
        : null;

    _log.fine('HEAD $url auth=$requiresAuth');

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
}

// ---------------------------------------------------------------------------
// SolidResourceLocator
// ---------------------------------------------------------------------------

// FIXME: A proper resource locator for Solid would need to:
// - Read from the user's profile to find the type index
// - Ask the user to edit the type index if necessary
// - Allow the user to decline type index editing
// - Handle changing configurations - maybe by maintaining a database
//   mapping from internal resource IRIs to Pod URLs - possibly supported
//   by embedding the internal resource IRI in the document itself.
//
// For now, we just hardcode the logic for the paths.

/// Maps internal locorda resource identifiers to Solid Pod URLs.
///
/// Internal IRIs of the form `tag:locorda.org,2025:l:<type>:<id>` are mapped
/// to `{podBaseUrl}data/{base64url(typeIri)}/{id}` for domain objects, or
/// `{podBaseUrl}indices/{base64url(typeIri)}/{id}` for index types.
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
