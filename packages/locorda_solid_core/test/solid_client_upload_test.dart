import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_solid_core/src/auth/solid_auth_provider.dart';
import 'package:locorda_solid_core/src/solid_backend.dart';
import 'package:test/test.dart';

void main() {
  group('SolidClient.upload', () {
    test('treats 412 precondition failed as conflict', () async {
      final client = SolidClient(
        client: _FakeHttpClient((request) async {
          expect(request.method, 'PUT');
          expect(request.headers['If-None-Match'], '*');
          return http.Response('', 412);
        }),
        authProvider: _FakeSolidAuthProvider(),
      );

      final result = await client.upload(
        'https://pod.example/data/resource',
        const TextContent('payload', contentType: 'text/plain'),
        documentIri: IriTerm.validated('https://pod.example/data/resource'),
      );

      expect(result, isA<ConflictUploadResult>());
      expect(result.documentIri.value, 'https://pod.example/data/resource');
      expect(result.requestETag, isNull);
    });
  });
}

final class _FakeHttpClient extends http.BaseClient {
  final Future<http.Response> Function(http.BaseRequest request) _handler;

  _FakeHttpClient(this._handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _handler(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
      request: request,
    );
  }
}

final class _FakeSolidAuthProvider implements SolidAuthProvider {
  @override
  String? get currentWebId => 'https://pod.example/profile/card#me';

  @override
  AuthValueListenable get isAuthenticatedNotifier => _FakeAuthValueListenable();

  @override
  String? get userDisplayName => 'Test User';

  @override
  Future<({String accessToken, String dPoP})> getDpopToken(
    String url,
    String method,
  ) async =>
      (accessToken: 'token', dPoP: 'proof');

  @override
  Future<bool> isAuthenticated() async => true;

  @override
  Future<void> logout() async {}

  @override
  Future<void> refreshToken({String? reason}) async {}
}

final class _FakeAuthValueListenable implements AuthValueListenable {
  @override
  bool get isAuthenticated => true;

  @override
  void addListener(void Function() listener) {}

  @override
  void removeListener(void Function() listener) {}
}
