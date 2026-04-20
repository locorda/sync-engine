import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_gdrive/src/gdrive_auth.dart';

void main() {
  group('shouldBlockScopeAuthorization', () {
    test('returns true when user interaction is required but not allowed', () {
      final result = shouldBlockScopeAuthorization(
        allowUserInteraction: false,
        requiresUserInteraction: true,
      );

      expect(result, isTrue);
    });

    test('returns false when user interaction is required and allowed', () {
      final result = shouldBlockScopeAuthorization(
        allowUserInteraction: true,
        requiresUserInteraction: true,
      );

      expect(result, isFalse);
    });

    test('returns false when user interaction is not required', () {
      final result = shouldBlockScopeAuthorization(
        allowUserInteraction: false,
        requiresUserInteraction: false,
      );

      expect(result, isFalse);
    });
  });
}
