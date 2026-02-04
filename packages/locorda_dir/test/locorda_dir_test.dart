import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_dir/locorda_dir.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Mock SharedPreferences for all tests
    SharedPreferences.setMockInitialValues({});
  });

  group('DirAuth', () {
    test('initializes with correct state', () async {
      final auth = await DirAuth.create(
        syncDirectoryPath: '/tmp/test',
        initiallyEnabled: false,
      );

      expect(await auth.isAuthenticated(), false);
      expect(auth.syncDirectoryPath, '/tmp/test');
      expect(auth.userDisplayName, null);
    });

    test('enable changes authentication state', () async {
      final auth = await DirAuth.create(
        syncDirectoryPath: '/tmp/test',
        initiallyEnabled: false,
      );

      await auth.enable();

      expect(await auth.isAuthenticated(), true);
      expect(auth.isAuthenticatedNotifier.isAuthenticated, true);
      expect(auth.userDisplayName, 'Local Directory');
    });

    test('disable changes authentication state', () async {
      final auth = await DirAuth.create(
        syncDirectoryPath: '/tmp/test',
        initiallyEnabled: true,
      );

      expect(await auth.isAuthenticated(), true);

      await auth.disable();

      expect(await auth.isAuthenticated(), false);
      expect(auth.isAuthenticatedNotifier.isAuthenticated, false);
      expect(auth.userDisplayName, null);
    });

    test('logout disables sync', () async {
      final auth = await DirAuth.create(
        syncDirectoryPath: '/tmp/test',
        initiallyEnabled: true,
      );

      await auth.logout();

      expect(await auth.isAuthenticated(), false);
    });

    test('notifies listeners on state change', () async {
      final auth = await DirAuth.create(
        syncDirectoryPath: '/tmp/test',
        initiallyEnabled: false,
      );

      var notificationCount = 0;
      auth.isAuthenticatedNotifier.addListener(() {
        notificationCount++;
      });

      await auth.enable();
      expect(notificationCount, 1);

      await auth.disable();
      expect(notificationCount, 2);
    });
  });

  group('DirMainIntegration', () {
    test('creates with correct properties', () async {
      final integration = await DirMainIntegration.create(
        appName: 'test-app',
        initiallyEnabled: false,
      );

      expect(integration.id, 'local_dir');
      expect(integration.displayName, 'Local Directory');
      expect(integration.workerConnectors, isEmpty);
    },
        skip:
            'Requires path_provider plugin which is not available in unit tests');
  });
}
