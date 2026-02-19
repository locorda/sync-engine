import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_mapper/mapper.dart';
import 'package:minimal_task_sync/task.dart';
import 'package:minimal_task_sync/task.rdf_mapper.g.dart';
import 'package:test/test.dart';

void main() {
  late RdfMapper mapper;

  setUp(() {
    // Create mapper registry and register TaskMapper
    // Simple IRI mapper for Task resources
    mapper = RdfMapper.withDefaultRegistry()
      ..registerMapper<Task>(TaskMapper(iriMapper: _SimpleTaskIriMapper()));
  });

  group('Task RDF Roundtrip', () {
    test('simple task serialization and deserialization', () {
      final originalTask = Task(
        id: 'task-123',
        title: 'Write unit tests',
        completed: false,
        createdAt: DateTime.utc(2025, 1, 15, 10, 30),
      );

      // Encode: Task → RdfGraph
      final graph = mapper.graph.encodeObject(originalTask);

      expect(graph.triples, isNotEmpty);

      // Decode: RdfGraph → Task
      final decodedTask = mapper.graph.decodeObject<Task>(graph);

      expect(decodedTask.id, equals(originalTask.id));
      expect(decodedTask.title, equals(originalTask.title));
      expect(decodedTask.completed, equals(originalTask.completed));
      expect(decodedTask.createdAt, equals(originalTask.createdAt));
    });

    test('completed task roundtrip', () {
      final originalTask = Task(
        id: 'task-456',
        title: 'Fix bug in sync engine',
        completed: true,
        createdAt: DateTime.utc(2025, 2, 10, 14, 20),
      );

      final graph = mapper.graph.encodeObject(originalTask);
      final decodedTask = mapper.graph.decodeObject<Task>(graph);
      final turtleString = turtle.encode(graph);
      final decodedGraph = turtle.decode(turtleString);
      expect(graph, equals(decodedGraph),
          reason: 'Graph should be the same after Turtle roundtrip');
      expect(decodedTask.id, equals(originalTask.id));
      expect(decodedTask.title, equals(originalTask.title));
      expect(decodedTask.completed, isTrue);
      expect(decodedTask.createdAt, equals(originalTask.createdAt));
    });

    test('task with Turtle serialization roundtrip', () {
      final originalTask = Task(
        id: 'task-789',
        title: 'Add RDF roundtrip test',
        completed: false,
        createdAt: DateTime.utc(2025, 2, 14, 9, 0),
      );

      // Full roundtrip: Task → RdfGraph → Turtle → RdfGraph → Task
      final graph = mapper.graph.encodeObject(originalTask);
      final turtleString = turtle.encode(graph);

      expect(turtleString, contains('Add RDF roundtrip test'),
          reason: 'Turtle should contain task title');

      final decodedGraph = turtle.decode(turtleString);
      final decodedTask = mapper.graph.decodeObject<Task>(decodedGraph);

      expect(decodedTask.id, equals(originalTask.id));
      expect(decodedTask.title, equals(originalTask.title));
      expect(decodedTask.completed, equals(originalTask.completed));
      expect(decodedTask.createdAt, equals(originalTask.createdAt));
    });

    test('task IRI generation uses correct pattern', () {
      final task = Task(
        id: 'my-task-id',
        title: 'Test IRI pattern',
      );

      final graph = mapper.graph.encodeObject(task);
      final taskSubjects = graph.triples
          .where((t) =>
              t.predicate is IriTerm &&
              (t.predicate as IriTerm).value.contains('title'))
          .map((t) => t.subject)
          .toSet();

      expect(taskSubjects, hasLength(1));
      final taskIri = taskSubjects.first as IriTerm;

      expect(taskIri.value, contains('https://locorda.dev/example/minimal'));
      expect(taskIri.value, contains('my-task-id'));
      expect(taskIri.value, endsWith('#it'));
    });
  });
}

/// Simple IRI mapper for Task resources (matches minimal example pattern)
class _SimpleTaskIriMapper implements IriTermMapper<(String,)> {
  @override
  (String,) fromRdfTerm(IriTerm term, DeserializationContext context) {
    // Extract ID from IRI: https://locorda.dev/example/minimal/resources/task-123#it
    final value = term.value;
    final hashIndex = value.indexOf('#');
    final path = hashIndex >= 0 ? value.substring(0, hashIndex) : value;
    final id = path.split('/').last;
    return (id,);
  }

  @override
  IriTerm toRdfTerm((String,) value, SerializationContext context) {
    final (id,) = value;
    return IriTerm('https://locorda.dev/example/minimal/resources/$id#it');
  }
}
