import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_gdrive/src/gdrive_api.dart';

void main() {
  test('throws AuthException for 401 DetailedApiRequestError', () {
    final error = drive.DetailedApiRequestError(401, 'unauthorized');

    expect(
      () => throwAuthExceptionIfUnauthorized(error),
      throwsA(isA<AuthException>()),
    );
  });

  test('does not throw for non-401 DetailedApiRequestError', () {
    final error = drive.DetailedApiRequestError(403, 'forbidden');

    expect(
      () => throwAuthExceptionIfUnauthorized(error),
      returnsNormally,
    );
  });
}
