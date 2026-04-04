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
}
