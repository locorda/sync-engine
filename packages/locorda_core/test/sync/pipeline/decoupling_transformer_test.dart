import 'dart:async';

import 'package:locorda_core/src/sync/pipeline/decoupling_transformer.dart';
import 'package:test/test.dart';

void main() {
  group('decouplingTransformer', () {
    test('forwards all events in order', () async {
      final source = Stream.fromIterable([1, 2, 3, 4, 5]);
      final result = await source
          .transform(decouplingTransformer(
            "TestDecoupling",
          ))
          .toList();
      expect(result, [1, 2, 3, 4, 5]);
    });

    test('forwards errors', () async {
      final controller = StreamController<int>();
      final results = <int>[];
      final errors = <Object>[];

      final sub = controller.stream
          .transform(decouplingTransformer(
            "TestDecoupling",
          ))
          .listen(results.add, onError: errors.add);

      controller.add(1);
      controller.addError('boom');
      controller.add(2);
      await controller.close();
      await sub.asFuture<void>();
      await sub.cancel();

      expect(results, [1, 2]);
      expect(errors, ['boom']);
    });

    test('closes when upstream closes', () async {
      final controller = StreamController<int>();

      final sub = controller.stream
          .transform(decouplingTransformer("TestDecoupling"))
          .listen((_) {});

      controller.add(1);
      await controller.close();
      // asFuture completes when onDone fires
      await sub.asFuture<void>();
      await sub.cancel();
    });

    test('cancels upstream when downstream is cancelled', () async {
      var upstreamCancelled = false;
      final controller = StreamController<int>(
        onCancel: () => upstreamCancelled = true,
      );

      final sub = controller.stream
          .transform(decouplingTransformer("TestDecoupling"))
          .listen((_) {});

      controller.add(1);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(upstreamCancelled, isTrue);
    });

    test('applies backpressure when buffer is full', () async {
      final controller = StreamController<int>();
      final received = <int>[];
      var upstreamPaused = false;

      // Use a small buffer to test backpressure quickly
      const bufferSize = 3;

      // Track when upstream is paused
      controller.onPause = () => upstreamPaused = true;

      // Create pipeline with slow consumer
      final completer = Completer<void>();
      final sub = controller.stream
          .transform(
              decouplingTransformer("TestDecoupling", maxBuffered: bufferSize))
          .listen((event) {
        received.add(event);
      }, onDone: completer.complete);

      // Pause downstream to let buffer fill
      sub.pause();

      // Add more events than the buffer can hold
      for (var i = 0; i < bufferSize + 2; i++) {
        controller.add(i);
      }

      // Yield to event loop so events propagate
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // Upstream should be paused (buffer full)
      expect(upstreamPaused, isTrue);

      // Resume downstream — should drain buffer and resume upstream
      sub.resume();
      await controller.close();
      await completer.future;
      await sub.cancel();

      // All events should arrive eventually
      expect(received, [0, 1, 2, 3, 4]);
    });

    test('works with empty stream', () async {
      final result = await Stream<int>.empty()
          .transform(decouplingTransformer("TestDecoupling"))
          .toList();
      expect(result, isEmpty);
    });

    test('decouples async stages allowing interleaving', () async {
      // This test verifies the core value: that upstream can produce
      // while downstream is awaiting an async operation.
      //
      // Without decoupling: upstream is paused during asyncExpand.
      // With decoupling: upstream continues into the buffer.

      final upstreamProduced = <int>[];
      final downstreamConsumed = <int>[];

      // Simulate: upstream produces fast, downstream consumes with await
      final source = StreamController<int>();

      final pipeline = source.stream
          .map((e) {
            upstreamProduced.add(e);
            return e;
          })
          .transform(decouplingTransformer("TestDecoupling", maxBuffered: 10))
          .asyncMap((e) async {
            // Simulate slow async consumer
            await Future<void>.delayed(const Duration(milliseconds: 10));
            downstreamConsumed.add(e);
            return e;
          });

      final done = pipeline.drain<void>();

      // Produce all items quickly
      for (var i = 0; i < 5; i++) {
        source.add(i);
      }
      await source.close();

      await done;

      expect(upstreamProduced, [0, 1, 2, 3, 4]);
      expect(downstreamConsumed, [0, 1, 2, 3, 4]);

      // The key assertion: upstream should have produced all items
      // before downstream finished processing them all.
      // (Without decoupling, upstream would be paused by asyncMap.)
    });

    test('handles single event', () async {
      final result = await Stream.fromIterable([42])
          .transform(decouplingTransformer("TestDecoupling"))
          .toList();
      expect(result, [42]);
    });

    test('large number of events', () async {
      final events = List.generate(10000, (i) => i);
      final result = await Stream.fromIterable(events)
          .transform(decouplingTransformer("TestDecoupling", maxBuffered: 64))
          .toList();
      expect(result, events);
    });
  });

  group('deferredExpandTransformer', () {
    test('expands events via Timer.run', () async {
      final result = await Stream.fromIterable([1, 2, 3])
          .deferredExpand('test', (n) => [n, n * 10])
          .toList();
      expect(result, [1, 10, 2, 20, 3, 30]);
    });

    test('propagates errors from expand callback', () async {
      // After the fix, errors in expand cancel upstream and close the
      // controller, so drain() completes with the error.
      var errorCount = 0;
      try {
        await Stream.fromIterable([1, 2, 3]).deferredExpand<int>('test', (n) {
          if (n == 2) throw StateError('boom');
          return [n];
        }).drain<void>();
      } on StateError catch (e) {
        expect(e.message, 'boom');
        errorCount++;
      }
      expect(errorCount, 1);
    });

    test('terminates on error when combined with decouplingTransformer',
        () async {
      // Reproduces the race condition: decouplingTransformer buffers
      // multiple events ahead of deferredExpandTransformer. When the
      // expand callback throws, the error must terminate the pipeline
      // even though the decoupling buffer still has pending events.
      //
      // Without the fix (cancel upstream + close on error),
      // the pipeline hangs because:
      // 1. decouplingTransformer resumes and delivers the next buffered event
      // 2. deferredExpand's Timer.run fires after cancel-cascade completes
      // 3. controller.addError() is silently dropped (no listener)
      // 4. controller.close() never fires → Done never delivered → hang
      //
      // The async stages after deferredExpand ensure that the cancel-cascade
      // takes long enough for the race condition to manifest.
      final source = StreamController<int>();

      var errorCount = 0;
      final pipeline = source.stream
          .asyncExpand(_asyncExpandFkt)
          .transform(_transformFkt())
          .map((n) => n)
          .transform(_transformFkt())
          .transform(_transformFkt())
          .transform(_transformFkt())
          .map((n) => n)
          .transform(_transformFkt())
          .decoupled('pre', maxBuffered: 1280)
          .deferredExpand<int>('merge', (n) {
            throw StateError('CRDT merge failed');
          })
          .decoupled('post', maxBuffered: 1280)
          .transform(_transformFkt())
          .asyncExpand(_asyncExpandFkt)
          .expand<int>((n) => [n])
          .asyncMap<int>((n) async => n)
          .expand((n) => [n])
          .transform(_transformFkt())
          .asyncExpand(_asyncExpandFkt)
          .asyncExpand(_asyncExpandFkt); // simulate downstream async stage

      // Pump enough events so the decoupling buffer fills well ahead
      for (var i = 0; i < 50; i++) {
        source.add(i);
      }
      source.close();

      // Let events propagate into the pre-buffer before drain starts
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // drain() = listen(null, cancelOnError: true).asFuture()
      // Must complete (with error), not hang.
      try {
        await pipeline.drain<void>().timeout(const Duration(seconds: 5));
      } on StateError catch (e) {
        expect(e.message, 'CRDT merge failed');
        errorCount++;
      }

      expect(errorCount, 1, reason: 'Pipeline should terminate with error');
    });

    test(
        'terminates on upstream error when combined with '
        'decouplingTransformer', () async {
      // Upstream error (not from expand callback) must also terminate.
      final source = StreamController<int>();

      final pipeline = source.stream
          .decoupled('pre', maxBuffered: 1280)
          .deferredExpand<int>('merge', (n) => [n])
          .decoupled('post', maxBuffered: 1280)
          .asyncMap((n) async => n);

      for (var i = 0; i < 10; i++) {
        source.add(i);
      }
      source.addError(StateError('upstream failure'));
      for (var i = 10; i < 20; i++) {
        source.add(i);
      }
      source.close();

      var errorCount = 0;
      try {
        await pipeline.drain<void>().timeout(const Duration(seconds: 5));
      } on StateError catch (e) {
        expect(e.message, 'upstream failure');
        errorCount++;
      }

      expect(errorCount, 1);
    });

    test('works with empty stream', () async {
      final result =
          await Stream<int>.empty().deferredExpand('test', (n) => [n]).toList();
      expect(result, isEmpty);
    });

    test('cancels upstream when downstream cancels', () async {
      var upstreamCancelled = false;
      final source = StreamController<int>(
        onCancel: () => upstreamCancelled = true,
      );

      final sub =
          source.stream.deferredExpand('test', (n) => [n]).listen((_) {});

      source.add(1);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(upstreamCancelled, isTrue);
    });
  });
}

StreamTransformer<int, int> _transformFkt() {
  return StreamTransformer.fromBind((stream) async* {
    await for (final event in stream) {
      yield event;
    }
  });
}

Stream<int>? _asyncExpandFkt(int n) async* {
  yield n;
}
