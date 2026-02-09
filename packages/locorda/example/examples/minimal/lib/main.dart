/// Minimal Locorda example - Task sync app.
library;

import 'package:flutter/material.dart';
import 'package:locorda/locorda.dart';
import 'package:locorda_dir/locorda_dir.dart';

import '../../../init_rdf_mapper.g.dart';
import 'task.dart';
import 'task_repository.dart';
import 'worker.dart';

// InMemoryStorage doesn't need plugins, just an empty handler
class InMemoryStorageMainHandler extends StorageMainHandler {
  @override
  List<MainHandlerFactory> create() => [];
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MinimalTaskApp());
}

// #docregion locorda-setup
/// Initialize Locorda with worker architecture.
Future<Locorda> setupLocorda() async {
  return Locorda.create(
    // Worker handles heavy operations (CRDT, HTTP, storage)
    workerSetup: setupWorkerEngine,

    // Local Dir for testing/debugging (not for production!)
    remotes: [
      await DirMainIntegration.create(
        id: 'local_dir',
        displayName: 'Local Directory (Testing)',
      ),
    ],

    // InMemoryStorage requires empty main handler
    storage: InMemoryStorageMainHandler(),

    // RDF mapper for Task model (generated)
    mapperInitializer: (context) => initRdfMapper(
      rdfMapper: context.baseRdfMapper,
      $resourceIriFactory: context.resourceIriFactory,
    ),

    // Configure Task resource with CRDT mapping
    config: LocordaConfig(
      resources: [
        ResourceConfig(
          type: Task,
          crdtMapping: Uri.parse(
              'https://locorda.dev/example/minimal/mappings/task-v1.ttl'),
          indices: [FullIndex()], // Simple: fetch all tasks
        ),
      ],
    ),
  );
}
// #enddocregion locorda-setup

class MinimalTaskApp extends StatefulWidget {
  const MinimalTaskApp({super.key});

  @override
  State<MinimalTaskApp> createState() => _MinimalTaskAppState();
}

class _MinimalTaskAppState extends State<MinimalTaskApp> {
  Locorda? _locorda;
  TaskRepository? _taskRepo;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final locorda = await setupLocorda();
      final taskRepo = await TaskRepository.create(locorda.syncEngine);

      setState(() {
        _locorda = locorda;
        _taskRepo = taskRepo;
      });
    } catch (e) {
      setState(() => _errorMessage = 'Init failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return MaterialApp(
        home: Scaffold(
          body: Center(child: Text(_errorMessage!)),
        ),
      );
    }

    if (_taskRepo == null) {
      return const MaterialApp(
        home: Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return MaterialApp(
      title: 'Minimal Task Sync',
      home: TaskListScreen(repository: _taskRepo!),
    );
  }

  @override
  void dispose() {
    _taskRepo?.dispose();
    _locorda?.close();
    super.dispose();
  }
}

// #docregion ui
class TaskListScreen extends StatefulWidget {
  final TaskRepository repository;
  const TaskListScreen({required this.repository, super.key});

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen> {
  final _controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tasks')),
      body: StreamBuilder<List<Task>>(
        stream: widget.repository.watchAll(),
        initialData: widget.repository.getAll(),
        builder: (context, snapshot) {
          final tasks = snapshot.data ?? [];
          return ListView.builder(
            itemCount: tasks.length,
            itemBuilder: (context, i) => CheckboxListTile(
              value: tasks[i].completed,
              title: Text(tasks[i].title),
              onChanged: (val) => widget.repository.save(
                tasks[i].copyWith(completed: val ?? false),
              ),
              secondary: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () => widget.repository.delete(tasks[i].id),
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () => _showAddDialog(),
      ),
    );
  }

  void _showAddDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Task'),
        content: TextField(controller: _controller),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final title = _controller.text.trim();
              if (title.isNotEmpty) {
                widget.repository.save(Task(
                  id: 'task_${DateTime.now().millisecondsSinceEpoch}',
                  title: title,
                ));
              }
              _controller.clear();
              Navigator.pop(context);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
// #enddocregion ui
