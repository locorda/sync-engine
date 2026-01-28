// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda/locorda.dart';
import 'package:personal_notes_app/screens/notes_list_screen.dart';
import 'package:personal_notes_app/services/categories_service.dart';
import 'package:personal_notes_app/services/notes_service.dart';
//import 'package:locorda_worker/worker_main.dart';
import 'services/mock_category_repository.dart';
import 'services/mock_note_repository.dart';
import 'services/mock_solid_crdt_sync.dart';

class MockAuthValueListenable implements AuthValueListenable {
  @override
  bool get isAuthenticated => false;

  @override
  void addListener(void Function() listener) {}

  @override
  void removeListener(void Function() listener) {}
}

class MockAuth implements Auth {
  @override
  Future<bool> isAuthenticated() => Future.value(false);

  @override
  AuthValueListenable get isAuthenticatedNotifier => MockAuthValueListenable();

  @override
  Future<void> logout() => Future.value();

  @override
  String? get userDisplayName => null;
}

class MockRemoteMainHandler implements RemoteMainHandler, RemoteUiAdapter {
  @override
  final String id;

  MockRemoteMainHandler(this.id);

  @override
  String get displayName => id;

  @override
  IconData get icon => Icons.cloud;

  @override
  Auth get auth => MockAuth();

  @override
  List<WorkerPluginFactory> get workerConnectors => [];

  @override
  Future<bool> showLogin(BuildContext context) => Future.value(false);
}

void main() {
  testWidgets('Personal Notes App starts up', (WidgetTester tester) async {
    // Set a larger screen size to accommodate the AppBar with all actions
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Create mock repositories and services for testing
    final mockCategoryRepo = MockCategoryRepository();
    final mockNoteRepo = MockNoteRepository();
    final mockNotesService = NotesService(mockNoteRepo);
    final mockCategoriesService = CategoriesService(mockCategoryRepo);

    // Create mock sync system
    final mockSyncManager = MockSyncManager();

    // Create mock plugin registry
    final mockSolidPlugin = MockRemoteMainHandler('solid');
    final mockGDrivePlugin = MockRemoteMainHandler('gdrive');
    final mockPluginRegistry = UiAdapterRegistry.withRemotes([
      mockSolidPlugin,
      mockGDrivePlugin,
    ]);

    // Build our app with mock services
    await tester.pumpWidget(
      MaterialApp(
        title: 'Personal Notes',
        localizationsDelegates: [
          ...GlobalMaterialLocalizations.delegates,
          SolidAuthLocalizations.delegate,
          LocordaUILocalizations.delegate,
          GDriveLocalizations.delegate,
        ],
        supportedLocales: SolidAuthLocalizations.supportedLocales
            .toSet()
            .intersection(GDriveLocalizations.supportedLocales.toSet())
            .intersection(LocordaUILocalizations.supportedLocales.toSet()),
        home: NotesListScreen(
          notesService: mockNotesService,
          categoriesService: mockCategoriesService,
          uiAdapterRegistry: mockPluginRegistry,
          syncManager: mockSyncManager,
        ),
      ),
    );

    // Verify that the app shows the notes list screen
    expect(find.byType(NotesListScreen), findsOneWidget);
  });
}
