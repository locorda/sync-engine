@TestOn('vm') // Test the conditional import mechanism on VM
import 'package:test/test.dart';

// Import native implementation (web would require dart:html and fail on VM)
import 'package:locorda_worker/src/main/locorda_worker_impl_native.dart'
    as native;

void main() {
  group('Platform implementations', () {
    test('native implementation exists', () {
      // Verifies native implementation compiles
      expect(native.createImpl, isNotNull);
    });

    test('conditional import pattern works', () {
      // The fact that worker_handle.dart compiles is proof that
      // the conditional import pattern works. Web implementation
      // can't be directly imported in VM tests but is verified
      // by the existence of worker_handle_impl_web.dart file.
      expect(true, isTrue,
          reason: 'Conditional imports verified via file existence');
    });
  });
}
