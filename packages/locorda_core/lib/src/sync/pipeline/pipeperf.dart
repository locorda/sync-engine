/// Per-stage performance measurement for the streaming sync pipeline.
///
/// Wraps the stage callbacks (map/expand/asyncMap/asyncExpand) to measure
/// wall-clock time per event and aggregates statistics across the sync run.
/// Transform stages that own their internal batching call [record] directly.
library;

import 'dart:async';

import 'package:logging/logging.dart';

final _log = Logger('perf.pipeline');

/// Collects per-stage timing measurements and reports aggregated statistics.
///
/// Usage:
/// - Orchestrator stages: `perf.timedMap('S03', callback)`
/// - Transform stages: call `perf.record('S02', microseconds)` internally
class PipeperfCollector {
  final Map<String, List<int>> _measurements = {};
  final _wallClock = Stopwatch();

  /// Records a single timing measurement in microseconds.
  void record(String stage, int microseconds) {
    if (!_wallClock.isRunning) _wallClock.start();
    (_measurements[stage] ??= []).add(microseconds);
  }

  // ---------------------------------------------------------------------------
  // Callback wrappers for orchestrator-level stages
  // ---------------------------------------------------------------------------

  /// Wraps a synchronous `map` callback with timing.
  T Function(S) timedMap<S, T>(String stage, T Function(S) fn) {
    return (event) {
      final sw = Stopwatch()..start();
      try {
        return fn(event);
      } finally {
        record(stage, sw.elapsedMicroseconds);
      }
    };
  }

  /// Wraps a synchronous `expand` callback with timing.
  Iterable<T> Function(S) timedExpand<S, T>(
      String stage, Iterable<T> Function(S) fn) {
    return (event) {
      final sw = Stopwatch()..start();
      try {
        return fn(event);
      } finally {
        record(stage, sw.elapsedMicroseconds);
      }
    };
  }

  /// Wraps an `asyncMap` callback with timing.
  Future<T> Function(S) timedAsyncMap<S, T>(
      String stage, FutureOr<T> Function(S) fn) {
    return (event) async {
      final sw = Stopwatch()..start();
      try {
        return await fn(event);
      } finally {
        record(stage, sw.elapsedMicroseconds);
      }
    };
  }

  // ---------------------------------------------------------------------------
  // Transform wrapper
  // ---------------------------------------------------------------------------

  /// Wraps a [StreamTransformer] with per-event timing.
  ///
  /// Measures wall-clock time each event spends inside the transform by
  /// timestamping input events and attributing output events to them.
  /// For batching transforms (N inputs → N outputs after flush), the total
  /// batch processing time is distributed across output events.
  StreamTransformer<S, T> timedTransform<S, T>(
      String stage, StreamTransformer<S, T> inner) {
    return StreamTransformer.fromBind((inputStream) {
      // Track cumulative time inside the transform via a running stopwatch
      // that runs while the transform is "working" (between input and output).
      var pendingInputs = 0;
      Stopwatch? batchSw;

      final timedInput = inputStream.map((event) {
        pendingInputs++;
        // Start timing when first input of a batch enters.
        batchSw ??= Stopwatch()..start();
        return event;
      });

      return inner.bind(timedInput).map((event) {
        if (batchSw != null) {
          // Attribute the elapsed time to this output event.
          final elapsed = batchSw!.elapsedMicroseconds;
          if (pendingInputs <= 1) {
            // Last (or only) output for this batch — record full elapsed time.
            record(stage, elapsed);
            batchSw = null;
            pendingInputs = 0;
          } else {
            pendingInputs--;
          }
        }
        return event;
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Report
  // ---------------------------------------------------------------------------

  /// Logs aggregated per-stage statistics.
  void report() {
    if (_measurements.isEmpty) return;
    _wallClock.stop();

    final totalEvents =
        _measurements.values.fold<int>(0, (sum, m) => sum + m.length);

    _log.info('');
    _log.info('═══ Pipeline Stats ($totalEvents events) ═══');
    _log.info(_header());

    final keys = _measurements.keys.toSet();

    // Top-level: no other key is a strict dot-separated prefix of this key.
    final topLevelKeys = keys
        .where((k) => !keys.any((other) => other != k && k.startsWith('$other.')))
        .toSet();

    final sortedEntries = _measurements.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in sortedEntries) {
      _log.info(_formatRow(_displayKey(entry.key, topLevelKeys), entry.value));
    }

    // Overlap summary: top-level stage totals vs wall-clock.
    final topLevelKeysList = topLevelKeys.toList();
    final sequentialUs = topLevelKeysList.fold<int>(
        0, (sum, k) => sum + _measurements[k]!.fold(0, (a, b) => a + b));
    final wallUs = _wallClock.elapsedMicroseconds;
    final overlapUs = sequentialUs - wallUs;
    final overlapPct =
        sequentialUs > 0 ? overlapUs * 100 / sequentialUs : 0.0;
    _log.info(
        'Sequential: ${_formatDuration(sequentialUs)}  '
        'Wall-clock: ${_formatDuration(wallUs)}  '
        'Overlap: ${_formatDuration(overlapUs)} (${overlapPct.toStringAsFixed(0)}%)');

    _log.info('');
  }

  // ---------------------------------------------------------------------------
  // Formatting helpers
  // ---------------------------------------------------------------------------

  /// For top-level keys returns the key unchanged.
  /// For sub-stage keys, replaces the longest matching top-level prefix with
  /// `  ...` so the remaining path shows what the sub-stage adds.
  static String _displayKey(String key, Set<String> topLevelKeys) {
    String? longestPrefix;
    for (final topLevel in topLevelKeys) {
      if (key.startsWith('$topLevel.')) {
        if (longestPrefix == null || topLevel.length > longestPrefix.length) {
          longestPrefix = topLevel;
        }
      }
    }
    if (longestPrefix == null) return key;
    return '  ...${key.substring(longestPrefix.length + 1)}';
  }

  static String _header() {
    final stage = 'Stage'.padRight(28);
    final count = 'count'.padLeft(6);
    final total = 'total'.padLeft(9);
    final min = 'min'.padLeft(9);
    final avg = 'avg'.padLeft(9);
    final p90 = 'p90'.padLeft(9);
    final p95 = 'p95'.padLeft(9);
    final p99 = 'p99'.padLeft(9);
    final max = 'max'.padLeft(9);
    return '$stage$count$total$min$avg$p90$p95$p99$max';
  }

  static String _formatRow(String stage, List<int> measurements) {
    final sorted = List<int>.from(measurements)..sort();
    final count = sorted.length;
    final total = sorted.fold<int>(0, (a, b) => a + b);
    final min = sorted.first;
    final max = sorted.last;
    final avg = total ~/ count;
    final p90 = sorted[((count - 1) * 0.9).round()];
    final p95 = sorted[((count - 1) * 0.95).round()];
    final p99 = sorted[((count - 1) * 0.99).round()];

    final stagePad = stage.padRight(28);
    final countPad = '$count'.padLeft(6);
    final totalPad = _formatDuration(total).padLeft(9);
    final minPad = _formatDuration(min).padLeft(9);
    final avgPad = _formatDuration(avg).padLeft(9);
    final p90Pad = _formatDuration(p90).padLeft(9);
    final p95Pad = _formatDuration(p95).padLeft(9);
    final p99Pad = _formatDuration(p99).padLeft(9);
    final maxPad = _formatDuration(max).padLeft(9);

    return '$stagePad$countPad$totalPad$minPad$avgPad$p90Pad$p95Pad$p99Pad$maxPad';
  }

  static String _formatDuration(int microseconds) {
    if (microseconds < 1000) return '${microseconds}µs';
    if (microseconds < 1000000) {
      final ms = microseconds / 1000;
      return ms < 10 ? '${ms.toStringAsFixed(1)}ms' : '${ms.round()}ms';
    }
    final s = microseconds / 1000000;
    return '${s.toStringAsFixed(2)}s';
  }
}
