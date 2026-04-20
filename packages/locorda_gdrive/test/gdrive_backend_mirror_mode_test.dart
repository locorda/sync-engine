import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_gdrive/src/gdrive_backend.dart';

void main() {
  group('shouldUseLocalMirror', () {
    test('returns false when running on web', () {
      final result = shouldUseLocalMirror(
        mirrorEnabled: true,
        isWeb: true,
      );

      expect(result, isFalse);
    });

    test('returns true when mirror is enabled and not on web', () {
      final result = shouldUseLocalMirror(
        mirrorEnabled: true,
        isWeb: false,
      );

      expect(result, isTrue);
    });

    test('returns false when mirror is disabled', () {
      final result = shouldUseLocalMirror(
        mirrorEnabled: false,
        isWeb: false,
      );

      expect(result, isFalse);
    });
  });
}
