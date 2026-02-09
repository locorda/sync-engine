/// Simplified RDF Serialization Performance Test
///
/// Tests only the core RDF serialization performance without full app setup.
/// This gives us a lower bound on performance costs.
///
/// Run:
/// ```bash
/// # macOS/Native
/// flutter test test/performance/rdf_serialization_simple_test.dart
///
/// # Web (Chrome)
/// flutter test --platform chrome test/performance/rdf_serialization_simple_test.dart
/// ```
library;

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_rdf_core/core.dart';

/// Set to true to enable debug output during test development
const _debug = false;

final _print = _debug ? print : (Object? object) {};

void main() {
  late TurtleCodec codec;
  late RdfGraph smallGraph;
  late RdfGraph mediumGraph;
  late RdfGraph largeGraph;
  late String smallTurtle;
  late String mediumTurtle;
  late String largeTurtle;

  setUpAll(() {
    codec = TurtleCodec(iriTermFactory: IriTerm.validated);

    // Create test graphs of different sizes
    smallGraph = _createTestGraph(triples: 10);
    mediumGraph = _createTestGraph(triples: 100);
    largeGraph = _createTestGraph(triples: 1000);

    // Pre-encode for decode tests
    smallTurtle = codec.encode(smallGraph);
    mediumTurtle = codec.encode(mediumGraph);
    largeTurtle = codec.encode(largeGraph);

    _print('\n📦 Test Data Sizes:');
    _print(
        '  Small (10 triples):   ${_formatBytes(utf8.encode(smallTurtle).length)}');
    _print(
        '  Medium (100 triples): ${_formatBytes(utf8.encode(mediumTurtle).length)}');
    _print(
        '  Large (1000 triples): ${_formatBytes(utf8.encode(largeTurtle).length)}');
  });

  group('RdfGraph → Turtle Encoding', () {
    test('small graph (10 triples)', () {
      final results =
          _benchmark(() => codec.encode(smallGraph), iterations: 100);
      _printResults('Encode 10 triples', results);

      expect(results.p95.inMilliseconds, lessThanOrEqualTo(1),
          reason:
              'Should encode small graph in <= 1ms (measured: ${_formatDuration(results.p95)})');
    });

    test('medium graph (100 triples)', () {
      final results =
          _benchmark(() => codec.encode(mediumGraph), iterations: 50);
      _printResults('Encode 100 triples', results);

      expect(results.p95.inMilliseconds, lessThanOrEqualTo(3),
          reason:
              'Should encode medium graph in <= 3ms (measured: ${_formatDuration(results.p95)})');
    });

    test('large graph (1000 triples)', () {
      final results =
          _benchmark(() => codec.encode(largeGraph), iterations: 20);
      _printResults('Encode 1000 triples', results);

      expect(results.p95.inMilliseconds, lessThanOrEqualTo(25),
          reason:
              'Should encode large graph in <= 25ms (measured: ${_formatDuration(results.p95)})');
    });
  });

  group('Turtle → RdfGraph Decoding', () {
    test('small turtle (10 triples)', () {
      final results =
          _benchmark(() => codec.decode(smallTurtle), iterations: 100);
      _printResults('Decode 10 triples', results);

      expect(results.p95.inMilliseconds, lessThanOrEqualTo(1),
          reason:
              'Should decode small turtle in <= 1ms (measured: ${_formatDuration(results.p95)})');
    });

    test('medium turtle (100 triples)', () {
      final results =
          _benchmark(() => codec.decode(mediumTurtle), iterations: 50);
      _printResults('Decode 100 triples', results);

      expect(results.p95.inMilliseconds, lessThanOrEqualTo(3),
          reason:
              'Should decode medium turtle in <= 3ms (measured: ${_formatDuration(results.p95)})');
    });

    test('large turtle (1000 triples)', () {
      final results =
          _benchmark(() => codec.decode(largeTurtle), iterations: 20);
      _printResults('Decode 1000 triples', results);

      expect(results.p95.inMilliseconds, lessThanOrEqualTo(10),
          reason:
              'Should decode large turtle in <= 10ms (measured: ${_formatDuration(results.p95)})');
    });
  });

  group('Round-trip Performance', () {
    test('small graph round-trip', () {
      final results = _benchmark(() {
        final turtle = codec.encode(smallGraph);
        return codec.decode(turtle);
      }, iterations: 100);
      _printResults('Round-trip 10 triples', results);

      expect(results.p95.inMilliseconds, lessThanOrEqualTo(2),
          reason:
              'Should round-trip small graph in <= 2ms (measured: ${_formatDuration(results.p95)})');
    });

    test('medium graph round-trip', () {
      final results = _benchmark(() {
        final turtle = codec.encode(mediumGraph);
        return codec.decode(turtle);
      }, iterations: 50);
      _printResults('Round-trip 100 triples', results);

      expect(results.p95.inMilliseconds, lessThanOrEqualTo(5),
          reason:
              'Should round-trip medium graph in <= 5ms (measured: ${_formatDuration(results.p95)})');
    });
  });
}

// Helper: Create test graph with specified number of triples
RdfGraph _createTestGraph({required int triples}) {
  final subject = IriTerm.validated('http://example.org/resource/1');
  final statements = <Triple>[];

  for (var i = 0; i < triples; i++) {
    final predicate = IriTerm.validated('http://example.org/prop$i');
    final object = i % 3 == 0
        ? LiteralTerm('Value $i')
        : i % 3 == 1
            ? IriTerm.validated('http://example.org/ref$i')
            : LiteralTerm.integer(i);

    statements.add(Triple(subject, predicate, object));
  }

  return RdfGraph.fromTriples(statements);
}

// Benchmark helper
BenchmarkResults _benchmark(Function() fn, {required int iterations}) {
  final durations = <Duration>[];

  // Warm-up
  for (var i = 0; i < 10; i++) {
    fn();
  }

  // Actual measurement
  for (var i = 0; i < iterations; i++) {
    final sw = Stopwatch()..start();
    fn();
    sw.stop();
    durations.add(sw.elapsed);
  }

  return BenchmarkResults(durations);
}

class BenchmarkResults {
  final List<Duration> durations;

  BenchmarkResults(this.durations);

  Duration get mean {
    final total = durations.fold<int>(0, (sum, d) => sum + d.inMicroseconds);
    return Duration(microseconds: total ~/ durations.length);
  }

  Duration get min => durations.reduce((a, b) => a < b ? a : b);
  Duration get max => durations.reduce((a, b) => a > b ? a : b);

  Duration get p50 => _percentile(50);
  Duration get p95 => _percentile(95);
  Duration get p99 => _percentile(99);

  Duration _percentile(int p) {
    final sorted = List<Duration>.from(durations)..sort();
    final index = (sorted.length * p / 100).ceil() - 1;
    return sorted[index.clamp(0, sorted.length - 1)];
  }
}

void _printResults(String operation, BenchmarkResults results) {
  if (!_debug) return;

  _print('\n📊 $operation:');
  _print('  Mean: ${_formatDuration(results.mean)}');
  _print('  P50:  ${_formatDuration(results.p50)}');
  _print('  P95:  ${_formatDuration(results.p95)} ⬅ Target metric');
  _print('  P99:  ${_formatDuration(results.p99)}');
  _print('  Max:  ${_formatDuration(results.max)}');
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
