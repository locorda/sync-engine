import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_core/rdf.dart';
import 'solid_profile_parser.dart';
import 'package:logging/logging.dart';

import 'auth/solid_auth_provider.dart';

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

class SolidBackend implements Backend {
  String get name => 'solid';

  // ignore: unused_field
  final SolidAuthProvider _authProvider;
  final IriTermFactory _iriTermFactory;
  final SolidClient _solidClient;
  List<RemoteStorage> _remotes = [];

  SolidBackend({
    required SolidAuthProvider auth,
    required IriTermFactory iriTermFactory,
    required http.Client httpClient,
    required RdfCore rdfCore,
    required String contentType,
  })  : _authProvider = auth,
        _iriTermFactory = iriTermFactory,
        _solidClient = SolidClient(
          client: _createRetryClient(httpClient),
          authProvider: auth,
          rdfCore: rdfCore,
          contentType: contentType,
        ) {
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
    } else {
      _log.info('User logged out: clearing Solid remote storage');
      // User logged out: clear remote storage
      _remotes = [];
    }
  }

  @override
  Future<void> dispose() async {
    _authProvider.isAuthenticatedNotifier.removeListener(_authStateChanged);
  }

  @override
  List<RemoteStorage> get remotes => _remotes;
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

  final String _contentType;

  final DatasetCodecResolver _codecResolver;

  SolidClient(
      {required http.Client client,
      required SolidAuthProvider authProvider,
      required RdfCore rdfCore,
      required String contentType})
      : _client = client,
        _authProvider = authProvider,
        _codecResolver = DatasetCodecResolver.withGraphCodecFallback(rdfCore),
        _contentType = contentType;

  Future<RemoteDownloadResult> download(String url,
      {bool requiresAuth = true, String? ifNoneMatch}) async {
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
            _contentType, // 'text/turtle, application/ld+json;q=0.9, */*;q=0.8',
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
      return RemoteDownloadResult(dataset: null, etag: null);
    }
    if (response.statusCode == 304) {
      // Not modified
      return RemoteDownloadResult.notModified(etag: ifNoneMatch);
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
    final codec = _getCachedCodec(mimeType);
    final dataset = codec.decode(data, documentUrl: url);
    return RemoteDownloadResult(
      dataset: dataset,
      etag: response.headers['etag'],
    );
  }

  RdfCodec<RdfDataset> _getCachedCodec(String mimeType) =>
      _codecResolver.datasetCodec(mimeType);

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

  Future<RemoteUploadResult> upload(String url, RdfDataset dataset,
      {bool requiresAuth = true, String? ifMatch}) async {
    final codec = _getCachedCodec(_contentType); // ensure codec is cached
    final turtle = codec.encode(dataset);
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
      return RemoteUploadResult.conflict();
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

      return RemoteUploadResult.success(etag ?? '');
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

  late final Future<String> _podUrlFuture;

  SolidRemoteStorage({
    required this.webId,
    required SolidClient client,
    required IriTermFactory iriTermFactory,
  })  : _client = client,
        _iriTermFactory = iriTermFactory {
    _podUrlFuture = _resolvePodUrl(webId);
  }

  Future<String> _resolvePodUrl(String webId) async {
    final profile = await _client.download(webId, requiresAuth: true);
    if (profile.dataset == null) {
      throw StateError('Profile document is empty for WebID: $webId');
    }

    final podUrl = await _profileParser.parseStorageUrl(
        webId, profile.dataset!.defaultGraph);
    if (podUrl == null) {
      throw StateError('Could not resolve Pod URL for WebID: $webId');
    }
    return podUrl.endsWith('/') ? podUrl : '$podUrl/';
  }

  @override
  Future<bool> isAvailable() {
    // TODO: implement availability check, maybe by using some API to
    // check for online/offline status or similar.
    return _podUrlFuture.then((_) => true).catchError((_) => false);
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

    return SolidSyncStorage(client: _client, iriTranslator: iriTranslator);
  }
}

/// Per-sync-session storage for Solid backend.
///
/// Caches the IRI translator to avoid rebuilding it on every upload/download.
class SolidSyncStorage extends RemoteSyncStorage {
  final SolidClient _client;
  final IriTranslator _iriTranslator;

  SolidSyncStorage({
    required SolidClient client,
    required IriTranslator iriTranslator,
  })  : _client = client,
        _iriTranslator = iriTranslator;

  @override
  Future<RemoteDownloadResult> download(IriTerm documentIri,
      {String? ifNoneMatch}) async {
    final podDocumentIri = _iriTranslator.internalToExternal(documentIri);
    final result = await _client.download(podDocumentIri.value,
        requiresAuth: true, ifNoneMatch: ifNoneMatch);
    if (result.dataset != null) {
      final translated =
          _iriTranslator.translateDatasetToInternal(result.dataset!);
      return RemoteDownloadResult(
        dataset: translated,
        etag: result.etag,
        notModified: result.notModified,
      );
    }
    return result;
  }

  @override
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfDataset dataset,
      {String? ifMatch}) async {
    final podDocumentIri = _iriTranslator.internalToExternal(documentIri);
    final translatedDataset =
        _iriTranslator.translateDatasetToExternal(dataset);
    return await _client.upload(podDocumentIri.value, translatedDataset,
        requiresAuth: true, ifMatch: ifMatch);
  }

  @override
  Future<void> finalizeSync() async {
    // No cleanup needed for Solid backend
  }
}
