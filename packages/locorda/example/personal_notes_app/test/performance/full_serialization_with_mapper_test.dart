/// Complete serialization performance test including RdfMapper.
///
/// Tests the full round-trip cost for worker isolate communication:
/// Dart Object → RdfGraph → Turtle → RdfGraph → Dart Object
///
/// This measures the ACTUAL cost of using SyncEngine in a worker,
/// including both RDF serialization AND object mapping overhead.
///
/// Run:
/// ```bash
/// # macOS/Native
/// flutter test test/performance/full_serialization_with_mapper_test.dart
///
/// # Web (Chrome)
/// flutter test --platform chrome test/performance/full_serialization_with_mapper_test.dart
/// ```
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:locorda/test.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_mapper/mapper.dart';
import 'package:personal_notes_app/init_rdf_mapper.g.dart';
import 'package:personal_notes_app/models/category.dart';
import 'package:personal_notes_app/models/comment.dart';
import 'package:personal_notes_app/models/note.dart';
import 'package:personal_notes_app/vocabulary/personal_notes_vocab.dart';

/// Set to true to enable debug output during test development
const _debug = false;

final _print = _debug ? print : (Object? object) {};

void main() {
  late RdfMapper mapper;
  late TurtleCodec turtleCodec;

  setUpAll(() {
    // Initialize mapper exactly as in Locorda.setup()
    final iriTermFactory = IriTerm.validated;

    mapper = createTestMapper(
        resourceTypes: {
          Note: PersonalNotesVocab.PersonalNote,
          Category: PersonalNotesVocab.NotesCategory,
        },
        initRdfMapper: (rdfMapper, indexItemIriFactory, resourceIriFactory,
                resourceRefFactory) =>
            initRdfMapper(
              rdfMapper: rdfMapper,
              $indexItemIriFactory: indexItemIriFactory,
              $resourceIriFactory: resourceIriFactory,
              $resourceRefFactory: resourceRefFactory,
            ));

    turtleCodec = TurtleCodec(iriTermFactory: iriTermFactory);

    _print('\n🎯 Testing FULL worker isolate round-trip cost:');
    _print('   Note → RdfGraph → Turtle → RdfGraph → Note\n');
  });

  group('Single Note - Full Round-Trip', () {
    test('encode Note to Turtle (via RdfMapper)', () {
      final note = _createSimpleNote();

      final (results, dataSize) = _benchmarkEncode(mapper, turtleCodec, note);
      _printResults('Encode Note → Turtle', results, dataSize: dataSize);

      final p95 = _percentile(results, 95);
      expect(p95.inMilliseconds, lessThan(3),
          reason:
              'Should encode Note to Turtle in < 3ms (measured: ${_formatDuration(p95)})');
    });

    test('decode Turtle to Note (via RdfMapper)', () {
      final note = _createSimpleNote();
      final graph = mapper.graph.encodeObject(note);
      final turtle = turtleCodec.encode(graph);

      final results = _benchmarkDecode<Note>(mapper, turtleCodec, turtle, note);
      _printResults('Decode Turtle → Note', results);

      final p95 = _percentile(results, 95);
      expect(p95.inMilliseconds, lessThan(2),
          reason:
              'Should decode Turtle to Note in < 2ms (measured: ${_formatDuration(p95)})');
    });

    test('COMPLETE round-trip: Note → Turtle → Note', () {
      final note = _createSimpleNote();

      final results = _benchmarkRoundTrip<Note>(mapper, turtleCodec, note);
      _printResults('FULL Round-trip (Note)', results);

      final p95 = _percentile(results, 95);
      expect(p95.inMilliseconds, lessThan(3),
          reason:
              'Complete round-trip should take < 3ms (measured: ${_formatDuration(p95)})');
    });
  });

  group('Complex Note - With Comments', () {
    test('complex Note round-trip', () {
      final note = _createComplexNote();

      final results = _benchmarkRoundTrip<Note>(mapper, turtleCodec, note);
      _printResults('Complex Note round-trip', results);

      final p95 = _percentile(results, 95);
      expect(p95.inMilliseconds, lessThan(3),
          reason:
              'Complex note round-trip should take < 3ms (measured: ${_formatDuration(p95)})');
    });
  });

  group('Category Serialization', () {
    test('Category round-trip', () {
      final category = _createCategory();

      final results =
          _benchmarkRoundTrip<Category>(mapper, turtleCodec, category);
      _printResults('Category round-trip', results);

      final p95 = _percentile(results, 95);
      expect(p95.inMilliseconds, lessThan(1),
          reason:
              'Category round-trip should take < 1ms (measured: ${_formatDuration(p95)})');
    });
  });

  group('Batch Performance', () {
    for (final batchSize in [10, 50]) {
      test('batch of $batchSize Notes', () {
        final notes =
            List.generate(batchSize, (i) => _createSimpleNote(id: 'note-$i'));

        final (results, totalBytes) =
            _benchmarkBatch(mapper, turtleCodec, notes);
        _printResults('Batch $batchSize Notes', results,
            dataSize: totalBytes, avgSize: totalBytes ~/ batchSize);

        final p95 = _percentile(results, 95);
        final targetMs = batchSize == 10 ? 10 : 35; // Allow for web overhead
        expect(p95.inMilliseconds, lessThan(targetMs),
            reason:
                'Batch should process in < ${targetMs}ms (measured: ${_formatDuration(p95)})');
      });
    }
  });
}

// Test data helpers

Note _createSimpleNote({String id = 'test-note'}) {
  return Note(
    id: id,
    title: 'Test Note',
    content: 'This is a test note with some content for benchmarking.',
    tags: {'test', 'benchmark', 'performance'},
    categoryId: 'category-1',
  );
}

Note _createComplexNote() {
  return Note(
    id: 'complex-note',
    title: 'Complex Test Note',
    content: 'Lorem ipsum dolor sit amet, consectetur adipiscing elit. ' * 10,
    tags: {'tag1', 'tag2', 'tag3', 'tag4', 'tag5'},
    categoryId: 'category-1',
    comments: {
      Comment(id: 'c1', content: 'First comment'),
      Comment(id: 'c2', content: 'Second comment'),
      Comment(id: 'c3', content: 'Third comment'),
    },
  );
}

Category _createCategory() {
  return Category(
    id: 'test-category',
    name: 'Test Category',
    description: 'A test category for benchmarking',
  );
}

// Benchmark helper functions

/// Benchmark encoding: Dart object → RdfGraph → Turtle string
(List<Duration>, int) _benchmarkEncode<T>(
    RdfMapper mapper, TurtleCodec codec, T object) {
  final results = <Duration>[];
  var dataSize = 0;

  // Warm-up
  for (var i = 0; i < 10; i++) {
    final graph = mapper.graph.encodeObject(object);
    codec.encode(graph);
  }

  // Measurements
  for (var i = 0; i < 100; i++) {
    final stopwatch = Stopwatch()..start();
    final graph = mapper.graph.encodeObject(object);
    final turtle = codec.encode(graph);
    stopwatch.stop();
    results.add(stopwatch.elapsed);

    if (i == 0) {
      dataSize = utf8.encode(turtle).length;
    }
  }

  return (results, dataSize);
}

/// Benchmark decoding: Turtle string → RdfGraph → Dart object
List<Duration> _benchmarkDecode<T>(
    RdfMapper mapper, TurtleCodec codec, String turtle, T expectedObject) {
  final results = <Duration>[];

  // Warm-up
  for (var i = 0; i < 10; i++) {
    final graph = codec.decode(turtle);
    mapper.graph.decodeObject<T>(graph);
  }

  // Measurements
  for (var i = 0; i < 100; i++) {
    final stopwatch = Stopwatch()..start();
    final graph = codec.decode(turtle);
    final decoded = mapper.graph.decodeObject<T>(graph);
    stopwatch.stop();
    results.add(stopwatch.elapsed);

    // Sanity check
    if (decoded is Note && expectedObject is Note) {
      expect(decoded.title, equals(expectedObject.title));
    } else if (decoded is Category && expectedObject is Category) {
      expect(decoded.name, equals(expectedObject.name));
    }
  }

  return results;
}

/// Benchmark complete round-trip: Dart → RDF → Turtle → RDF → Dart
List<Duration> _benchmarkRoundTrip<T>(
    RdfMapper mapper, TurtleCodec codec, T object) {
  final results = <Duration>[];

  // Warm-up
  for (var i = 0; i < 10; i++) {
    final graph = mapper.graph.encodeObject(object);
    final turtle = codec.encode(graph);
    final decodedGraph = codec.decode(turtle);
    mapper.graph.decodeObject<T>(decodedGraph);
  }

  // Measurements
  for (var i = 0; i < 100; i++) {
    final stopwatch = Stopwatch()..start();

    // Encode: Dart → RDF → Turtle
    final graph = mapper.graph.encodeObject(object);
    final turtle = codec.encode(graph);

    // Decode: Turtle → RDF → Dart
    final decodedGraph = codec.decode(turtle);
    final decoded = mapper.graph.decodeObject<T>(decodedGraph);

    stopwatch.stop();
    results.add(stopwatch.elapsed);

    // Sanity check
    if (decoded is Note && object is Note) {
      expect(decoded.title, equals(object.title));
    } else if (decoded is Category && object is Category) {
      expect(decoded.name, equals(object.name));
    }
  }

  return results;
}

/// Benchmark batch processing of multiple objects
(List<Duration>, int) _benchmarkBatch<T>(
    RdfMapper mapper, TurtleCodec codec, List<T> objects) {
  final results = <Duration>[];
  var totalBytes = 0;

  // Warm-up
  for (var i = 0; i < 5; i++) {
    for (final obj in objects) {
      final graph = mapper.graph.encodeObject(obj);
      final turtle = codec.encode(graph);
      final decodedGraph = codec.decode(turtle);
      mapper.graph.decodeObject<T>(decodedGraph);
    }
  }

  // Measurements
  for (var i = 0; i < 20; i++) {
    final stopwatch = Stopwatch()..start();

    for (final obj in objects) {
      final graph = mapper.graph.encodeObject(obj);
      final turtle = codec.encode(graph);
      final decodedGraph = codec.decode(turtle);
      final decoded = mapper.graph.decodeObject<T>(decodedGraph);

      if (i == 0) {
        totalBytes += utf8.encode(turtle).length;
      }

      // Sanity check
      if (decoded is Note && obj is Note) {
        expect(decoded.title, equals(obj.title));
      }
    }

    stopwatch.stop();
    results.add(stopwatch.elapsed);
  }

  return (results, totalBytes);
}

// Benchmark output utilities

void _printResults(String operation, List<Duration> results,
    {int? dataSize, int? avgSize}) {
  if (!_debug) return;

  final mean = _mean(results);
  final p50 = _percentile(results, 50);
  final p95 = _percentile(results, 95);
  final p99 = _percentile(results, 99);
  final max = results.reduce((a, b) => a > b ? a : b);

  _print('\n📊 $operation (${results.length} iterations):');
  if (dataSize != null) {
    if (avgSize != null) {
      _print(
          '  Size: ${_formatBytes(dataSize)} (~${_formatBytes(avgSize)}/item)');
    } else {
      _print('  Size: ${_formatBytes(dataSize)}');
    }
  }
  _print('  Mean: ${_formatDuration(mean)}');
  _print('  P50:  ${_formatDuration(p50)}');
  _print('  P95:  ${_formatDuration(p95)} ⬅ Target metric');
  _print('  P99:  ${_formatDuration(p99)}');
  _print('  Max:  ${_formatDuration(max)}');
}

Duration _mean(List<Duration> durations) {
  final total = durations.fold<int>(0, (sum, d) => sum + d.inMicroseconds);
  return Duration(microseconds: total ~/ durations.length);
}

Duration _percentile(List<Duration> durations, int p) {
  final sorted = List<Duration>.from(durations)..sort();
  final index = (sorted.length * p / 100).ceil() - 1;
  return sorted[index.clamp(0, sorted.length - 1)];
}

String _formatDuration(Duration d) {
  if (d.inMilliseconds > 0) {
    return '${d.inMilliseconds}ms';
  } else {
    return '${d.inMicroseconds}μs';
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '${bytes}B';
  } else if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)}KB';
  } else {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}
