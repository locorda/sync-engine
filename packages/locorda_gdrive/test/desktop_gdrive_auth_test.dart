import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_gdrive/src/gdrive_auth.dart';
import 'package:locorda_gdrive/src/auth/desktop_gdrive_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopGDriveAuth', () {
    const clientId = 'test_client_id';
    const clientKey = 'test_client_key';
    const scopes = ['https://www.googleapis.com/auth/drive.appdata'];

    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('initializes with no persisted credentials as unauthenticated',
        () async {
      final auth = await DesktopGDriveAuth.create(
        clientId: clientId,
        clientKey: clientKey,
        scopes: scopes,
      );

      expect(auth.scopes, scopes);
      expect(await auth.isAuthenticated(), isFalse);
      expect(auth.isAuthenticatedNotifier.isAuthenticated, isFalse);
      expect(auth.userId, null);
      expect(auth.userDisplayName, null);
    });

    test('loads persisted credentials on creation', () async {
      final expiry = DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .toIso8601String();
      SharedPreferences.setMockInitialValues({
        'flutter.locorda_gdrive_access_token': 'fake_access_token',
        'flutter.locorda_gdrive_refresh_token': 'fake_refresh_token',
        'flutter.locorda_gdrive_expiry': expiry,
        'flutter.locorda_gdrive_scopes': scopes,
        'flutter.locorda_gdrive_user_id': 'user_123',
        'flutter.locorda_gdrive_user_display_name': 'Test User',
      });

      final auth = await DesktopGDriveAuth.create(
        clientId: clientId,
        clientKey: clientKey,
        scopes: scopes,
      );

      expect(await auth.isAuthenticated(), isTrue);
      expect(auth.isAuthenticatedNotifier.isAuthenticated, isTrue);
      expect(auth.userId, 'user_123');
      expect(auth.userDisplayName, 'Test User');
      expect(await auth.getAccessToken(), 'fake_access_token');
    });

    test('logout clears credentials', () async {
      final expiry = DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .toIso8601String();
      SharedPreferences.setMockInitialValues({
        'flutter.locorda_gdrive_access_token': 'fake_access_token',
        'flutter.locorda_gdrive_refresh_token': 'fake_refresh_token',
        'flutter.locorda_gdrive_expiry': expiry,
        'flutter.locorda_gdrive_scopes': scopes,
        'flutter.locorda_gdrive_user_id': 'user_123',
        'flutter.locorda_gdrive_user_display_name': 'Test User',
      });

      final auth = await DesktopGDriveAuth.create(
        clientId: clientId,
        clientKey: clientKey,
        scopes: scopes,
      );

      expect(await auth.isAuthenticated(), isTrue);

      await auth.logout();

      expect(await auth.isAuthenticated(), isFalse);
      expect(auth.userId, isNull);
      expect(auth.userDisplayName, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('locorda_gdrive_access_token'), isFalse);
      expect(prefs.containsKey('locorda_gdrive_refresh_token'), isFalse);
      expect(prefs.containsKey('locorda_gdrive_user_id'), isFalse);
    });

    test('GDriveAuth.create returns DesktopGDriveAuth on desktop platform',
        () async {
      // FIXME: this is a bad / stupid test - you are ignoring mac for example.
      // Since our test runs on the host OS (Linux), GDriveAuth.create should return a DesktopGDriveAuth
      final auth = await GDriveAuth.create(
        clientId: clientId,
        clientKey: clientKey,
        scopes: scopes,
      );

      expect(auth, isA<DesktopGDriveAuth>());
    });
  });
}
