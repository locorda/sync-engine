/// A [StreamTransformer] that decouples upstream production from downstream
/// consumption by inserting a buffered [StreamController] between them.
///
/// In a Dart stream chain, `asyncExpand` / `asyncMap` pause their upstream
/// subscription while processing. This back-pressure propagates through all
/// synchronous operators (`map`, `expand`, `where`) back to the previous
/// async barrier — preventing any interleaving of IO and CPU work.
///
/// Inserting a [DecouplingTransformer] breaks that pause-propagation chain:
/// while downstream awaits IO (yielding to the event loop), upstream can
/// continue producing into the buffer. The event loop schedules both sides
/// cooperatively, achieving true concurrency on a single isolate.
///
/// Back-pressure is maintained via [maxBuffered]: when the buffer reaches
/// capacity, the upstream subscription is paused until downstream catches up.
library;

import 'dart:async';

/// Creates a [StreamTransformer] that decouples upstream from downstream.
///
/// Events are buffered in an internal [StreamController]. When the buffer
/// reaches [maxBuffered] events, upstream is paused until downstream
/// consumes enough to drop below the threshold.
///
/// The transformer preserves event ordering and propagates errors and
/// completion in both directions. Cancelling the downstream subscription
/// cancels the upstream subscription.
StreamTransformer<T, T> decouplingTransformer<T>({int maxBuffered = 64}) {
  return StreamTransformer<T, T>.fromBind((Stream<T> input) {
    final controller = StreamController<T>();
    StreamSubscription<T>? subscription;
    var buffered = 0;
    var upstreamDone = false;

    void resumeIfNeeded() {
      if (buffered < maxBuffered && !upstreamDone) {
        subscription?.resume();
      }
    }

    controller.onListen = () {
      subscription = input.listen(
        (event) {
          controller.add(event);
          buffered++;
          if (buffered >= maxBuffered) {
            subscription!.pause();
          }
        },
        onError: controller.addError,
        onDone: () {
          upstreamDone = true;
          controller.close();
        },
      );
    };

    controller.onCancel = () {
      final sub = subscription;
      subscription = null;
      return sub?.cancel() ?? Future.value();
    };

    controller.onPause = () {
      // Downstream paused — don't need to pause upstream here,
      // the controller itself buffers. But if we're already at capacity,
      // upstream is already paused.
    };

    controller.onResume = () {
      // Downstream resumed — if upstream was paused due to backpressure,
      // resume it.
      resumeIfNeeded();
    };

    // Track consumption via a wrapper stream that decrements the counter.
    return controller.stream.transform(
      StreamTransformer<T, T>.fromBind((Stream<T> bufferedStream) {
        return bufferedStream.map((event) {
          buffered--;
          resumeIfNeeded();
          return event;
        });
      }),
    );
  });
}
