import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_gdrive/src/auth/gdrive_auth_provider.dart';

void main() {
  test('GDriveUserInteractionRequired returns message', () {
    const message = 'User interaction required';
    final error = GDriveUserInteractionRequired(message);

    expect(error.toString(), message);
  });
}
