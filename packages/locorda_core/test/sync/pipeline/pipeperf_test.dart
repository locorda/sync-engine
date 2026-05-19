import 'dart:async';

import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:test/test.dart';

void main() {
  group('PipeperfCollector', () {
    late PipeperfCollector perf;

    setUp(() {
      perf = PipeperfCollector();
    });

    test('record stores measurements', () {
      perf.record('S1', 100);
      perf.record('S1', 200);
      perf.record('S2', 50);
      // report should not throw
      perf.report();
    });

    test('report on empty collector does nothing', () {
      perf.report(); // should not throw
    });

    group('timedMap', () {
      test('wraps synchronous function and records timing', () {
        final fn = perf.timedMap<int, String>('S3', (x) => 'v$x');

        expect(fn(42), equals('v42'));
        perf.report();
      });

      test('records timing even on exception', () {
        final fn = perf.timedMap<int, String>('S3', (x) {
          throw StateError('boom');
        });

        expect(() => fn(1), throwsStateError);
        // Measurement should still have been recorded.
        perf.report();
      });
    });

    group('timedExpand', () {
      test('wraps expand callback and records timing', () {
        final fn = perf.timedExpand<int, int>('S7c', (x) => [x, x * 2]);

        expect(fn(3), equals([3, 6]));
        perf.report();
      });
    });

    group('timedAsyncMap', () {
      test('wraps async function and records timing', () async {
        final fn = perf.timedAsyncMap<int, String>('S11b', (x) async {
          await Future<void>.delayed(Duration(milliseconds: 1));
          return 'async$x';
        });

        expect(await fn(5), equals('async5'));
        perf.report();
      });
    });

    group('timedTransform', () {
      test('wraps a StreamTransformer and records per-event timing', () async {
        final inner = StreamTransformer<int, String>.fromHandlers(
          handleData: (data, sink) => sink.add('t$data'),
        );

        final wrapped = perf.timedTransform('S2', inner);
        final results =
            await Stream.fromIterable([1, 2, 3]).transform(wrapped).toList();

        expect(results, equals(['t1', 't2', 't3']));
        perf.report();
      });

      test('works with batching transforms', () async {
        // Simulates a batching transform that buffers 2 inputs, then flushes.
        final inner = StreamTransformer<int, String>.fromBind((stream) async* {
          final buffer = <int>[];
          await for (final event in stream) {
            buffer.add(event);
            if (buffer.length >= 2) {
              for (final item in buffer) {
                yield 'b$item';
              }
              buffer.clear();
            }
          }
          for (final item in buffer) {
            yield 'b$item';
          }
        });

        final wrapped = perf.timedTransform('S5', inner);
        final results =
            await Stream.fromIterable([1, 2, 3]).transform(wrapped).toList();

        expect(results, equals(['b1', 'b2', 'b3']));
        perf.report();
      });
    });

    group('formatDuration', () {
      // Access via report output — just verify the report doesn't crash
      // with various magnitudes.
      test('handles microseconds, milliseconds, and seconds', () {
        perf.record('fast', 50); // 50µs
        perf.record('medium', 5000); // 5ms
        perf.record('slow', 2500000); // 2.5s
        perf.report();
      });
    });
  });
}
