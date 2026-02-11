/// Personal Notes App - Simple offline-first application using locorda.
///
/// Demonstrates:
/// - Offline-first operation (works offline)
/// - Optional Solid Pod connection
/// - CRDT conflict resolution
/// - Simple, clean UI
library;

import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:locorda/locorda.dart';
import 'package:locorda_dir/locorda_dir.dart';
import 'package:locorda_rdf_terms_schema/schema.dart';
import 'package:personal_notes_app/init_locorda.g.dart';
import 'package:personal_notes_app/locorda_worker.manifest.dart';
import 'package:personal_notes_app/models/category.dart';
import 'package:personal_notes_app/models/note.dart';
import 'package:personal_notes_app/models/note_group_key.dart';
import 'package:personal_notes_app/models/note_index_entry.dart';
import 'package:personal_notes_app/vocabulary/personal_notes_vocab.dart';

import 'screens/notes_list_screen.dart';
import 'services/categories_service.dart';
import 'services/notes_service.dart';
import 'storage/database.dart' show AppDatabase;
import 'storage/repositories.dart' show CategoryRepository, NoteRepository;
import 'utils/logging_setup.dart';

const appBaseUrl = 'https://locorda.dev/example/personal_notes_app';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set up beautiful console logging for development
  setupMainLogging();

  runApp(const PersonalNotesApp());
}

/// Initialize the CRDT sync system with worker-based architecture.
///
/// This configures:
/// - Worker isolate/thread for heavy operations (CRDT, DB, HTTP, DPoP)
/// - RDF mapper with user dependencies (runs on main thread)
/// - All resources (Note, Category) with their paths, indices, and CRDT mappings
/// - Auth bridge to sync credentials from main thread to worker
/// - Returns a fully configured sync system
Future<Locorda> initializeLocorda() async {
  // Setup sync system with worker
  return initLocorda(
    onWorkerSpawn: setupWorkerLogging,

    // Provide remotes - those must be configured correspondingly in setupWorkerEngine as well
    remotes: [
      if (DirMainIntegration.isPlatformSupported) ...[
        await DirMainIntegration.create(),
        await DirMainIntegration.create(
            id: dirDatasetPerShardRemoteId,
            displayName: 'Local Directory (Sharded)'),
      ],
      await SolidMainIntegration.create(
          // SECURITY: This example demonstrates secure redirect URI configuration.
          // - appUrlScheme provides secure custom URI scheme for mobile/macOS
          // - frontendRedirectUrl provides secure HTTPS redirect for web
          // See spec/docs/SECURITY.md for detailed security considerations
          oidcClientId: '$appBaseUrl/auth/client-config.json',
          appUrlScheme: 'dev.locorda.example.personalNotesApp',
          frontendRedirectUrl: Uri.parse(
              '${kDebugMode ? 'http://localhost:3815' : appBaseUrl}/redirect.html'),
          config: SolidConfig(useShardDatasets: false)),
      await GDriveMainIntegration.create(
          config: GDriveConfig(
              useShardDatasets: true,
              localMirrorConfig: GDriveLocalMirrorConfig(enabled: true))),
    ],

    // Provide storage - web options are sent to worker via connector
    storage: DriftMainHandler(
      webOptions: LocordaDriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
      ),
    ),

    /* resource-focused configuration */
    config: LocordaConfig(
      resources: [
        // Configure Note resource with grouping index by category
        ResourceConfig(
          type: Note,
          crdtMapping: Uri.parse('$appBaseUrl/mappings/note-v1.ttl'),
          indices: [
            GroupIndex(NoteGroupKey,
                item: IndexItem(NoteIndexEntry, {
                  SchemaNoteDigitalDocument.name,
                  SchemaNoteDigitalDocument.dateCreated,
                  SchemaNoteDigitalDocument.dateModified,
                  SchemaNoteDigitalDocument.keywords,
                  PersonalNotesVocab.belongsToCategory
                }),
                groupingProperties: [
                  GroupingProperty(SchemaNoteDigitalDocument.dateCreated,
                      transforms: [
                        RegexTransform(r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*',
                            r'${1}-${2}')
                      ])
                ]),
          ],
        ),

        // Configure Category resource with full index
        ResourceConfig(
          type: Category,
          crdtMapping: Uri.parse('$appBaseUrl/mappings/category-v1.ttl'),
          indices: [FullIndex(itemFetchPolicy: ItemFetchPolicy.prefetch)],
        ),
      ],
    ),
  );
}

class PersonalNotesApp extends StatelessWidget {
  const PersonalNotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Personal Notes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
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
      home: const AppInitializer(),
    );
  }
}

class AppInitializer extends StatefulWidget {
  const AppInitializer({super.key});

  @override
  State<AppInitializer> createState() => _AppInitializerState();
}

class _AppInitializerState extends State<AppInitializer>
    with WidgetsBindingObserver {
  Locorda? locorda;
  AppDatabase? appDatabase;
  CategoryRepository? categoryRepository;
  NoteRepository? noteRepository;
  NotesService? notesService;
  CategoriesService? categoriesService;
  String? errorMessage;
  bool isInitializing = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
  }

  /// Clean up all app resources
  Future<void> _cleanupResources() async {
    categoryRepository?.dispose();
    noteRepository?.dispose();
    await appDatabase?.close();
    await locorda?.close();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Clean up resources when the widget is disposed
    _cleanupResources();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Close resources when the app is being terminated
    if (state == AppLifecycleState.detached) {
      _cleanupResources();
    }
  }

  Future<void> _initializeApp() async {
    try {
      final DriftWebOptions webOptions = DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
      );

      // Initialize the CRDT sync system with worker architecture
      // This runs heavy operations (CRDT, DB, HTTP, DPoP) in separate isolate/worker
      final locorda = await initializeLocorda();

      // Initialize app database (Drift)
      final appDb = AppDatabase(web: webOptions);

      // Initialize repositories with database DAOs, cursor DAO, and sync system, hydrating existing data
      final categoryRepo = await CategoryRepository.create(
          appDb.categoryDao, appDb.cursorDao, locorda.syncEngine);
      final noteRepo = await NoteRepository.create(
          appDb.noteDao,
          appDb.commentDao,
          appDb.noteIndexEntryDao,
          appDb.cursorDao,
          locorda.syncEngine);

      // Initialize services with repositories
      final notesSvc = NotesService(noteRepo);
      final categoriesSvc = CategoriesService(categoryRepo);

      setState(() {
        this.locorda = locorda;
        appDatabase = appDb;
        categoryRepository = categoryRepo;
        noteRepository = noteRepo;
        notesService = notesSvc;
        categoriesService = categoriesSvc;
        isInitializing = false;
      });
    } catch (e) {
      setState(() {
        errorMessage = 'Failed to initialize app: $e';
        isInitializing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isInitializing) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text(
                'Initializing Personal Notes...',
                style: TextStyle(fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    if (errorMessage != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: 64,
                color: Colors.red,
              ),
              const SizedBox(height: 16),
              Text(
                errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    errorMessage = null;
                    isInitializing = true;
                  });
                  _initializeApp();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    // Successfully initialized - show the main app
    return NotesListScreen(
      notesService: notesService!,
      categoriesService: categoriesService!,
      uiAdapterRegistry: locorda!.uiAdapterRegistry,
      syncManager: locorda!.syncManager,
    );
  }
}
