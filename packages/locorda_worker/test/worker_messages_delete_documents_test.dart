import 'package:locorda_worker/src/shared/worker_messages.dart';
import 'package:test/test.dart';

void main() {
  group('DeleteDocuments messages', () {
    test('round-trips request via deserializeMessage', () {
      final request = DeleteDocumentsRequest(
        'req-1',
        'https://schema.org/Note',
        ['note-1', 'note-2'],
      );

      final decoded = deserializeMessage(request.toJson());

      expect(decoded, isA<DeleteDocumentsRequest>());
      final typed = decoded as DeleteDocumentsRequest;
      expect(typed.requestId, equals('req-1'));
      expect(typed.typeIri, equals('https://schema.org/Note'));
      expect(typed.externalIris, equals(['note-1', 'note-2']));
    });

    test('round-trips response via deserializeMessage', () {
      final response = DeleteDocumentsResponse(
        'req-2',
        success: true,
      );

      final decoded = deserializeMessage(response.toJson());

      expect(decoded, isA<DeleteDocumentsResponse>());
      final typed = decoded as DeleteDocumentsResponse;
      expect(typed.requestId, equals('req-2'));
      expect(typed.success, isTrue);
      expect(typed.error, isNull);
    });

    test('response includes error payload when provided', () {
      final response = DeleteDocumentsResponse(
        'req-3',
        success: false,
        error: 'boom',
      );

      final decoded = deserializeMessage(response.toJson());

      expect(decoded, isA<DeleteDocumentsResponse>());
      final typed = decoded as DeleteDocumentsResponse;
      expect(typed.requestId, equals('req-3'));
      expect(typed.success, isFalse);
      expect(typed.error, equals('boom'));
    });
  });
}
