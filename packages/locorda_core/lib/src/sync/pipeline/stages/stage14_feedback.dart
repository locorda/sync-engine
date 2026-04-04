/// Stage 14: Feedback Stage — orchestrate pipeline phases via inputController.
///
/// Listens for [PhaseComplete] events and decides whether to re-inject (meta-
/// index unstable, zero-shard safety net) or transition phases (meta → content)
/// or close the pipeline (content complete).
///
/// **Implementation**: `asyncExpand` — reacts to [PhaseComplete]; passes
/// [ShardCommitResult] through for monitoring. Side-effects on `inputController`.
///
/// **Input**: `Stream<CommittedShardEvent>`
/// **Output**: `Stream<CommittedShardEvent>` (pass-through)
library;

import 'dart:async' show StreamSink;

import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_core/src/storage/storage_interface.dart' show Storage;
import 'package:locorda_core/src/sync/pipeline/clock_hash_reader.dart';
import 'package:locorda_core/src/sync/pipeline/content_index_resolver.dart';
import 'package:locorda_core/src/sync/pipeline/pipeperf.dart';
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_rdf_core/core.dart' show IriTerm;
import 'package:logging/logging.dart';

final _log = Logger('Stage14.Feedback');

/// Maximum number of meta-index re-injections before aborting.
const _maxRetries = 6;

/// Returns an asyncExpand function for Stage 14.
///
/// Usage: `stream.asyncExpand(feedback(inputController, storage, indexResolver))`
///
/// [indexResolver] is called exactly once (when transitioning from meta to
/// content phase) to resolve the full set of content indices with their
/// [IndexInputInfo] (fetch policy + resource type IRI).
Stream<CommittedShardEvent> Function(CommittedShardEvent) feedback(
  // ignore: close_sinks — closed by feedback logic, not by the caller
  StreamSink<SyncInput> inputSink,
  Storage storage,
  ContentIndexResolver indexResolver, {
  PipeperfCollector? perf,
  String perfStage = 'S14.Feedback',
}) {
  // Accumulated across the phase — cleared after re-injection.
  final conflictedShardIris = <IriTerm>{};

  return (CommittedShardEvent event) async* {
    switch (event) {
      case ShardCommitResult():
        yield event;
      case ConflictedShard():
        conflictedShardIris.add(event.shardIri);
        yield event;
      case PhaseComplete():
        yield event; // pass through so caller can monitor
        final source = event.source;

        // Conflict re-injection takes priority — re-process the entire
        // input so that all indices (including those with conflicted shards)
        // are re-fetched and re-merged with fresh data.
        if (conflictedShardIris.isNotEmpty) {
          final count = conflictedShardIris.length;
          final shardIrisCopy = Set<IriTerm>.of(conflictedShardIris);
          conflictedShardIris.clear();
          if (source.retryCount >= _maxRetries) {
            _log.severe('Shard conflicts persist after $_maxRetries retries '
                '($count conflicted shards)');
            inputSink.close();
            return;
          }
          _log.info('$count shard(s) had conflicts — '
              'reinjecting (retry ${source.retryCount + 1})');
          inputSink.add(SyncInput(
            source.indexIris,
            retryCount: source.retryCount + 1,
            indexInfos: source.indexInfos,
            metaIndexClockHashes: source.metaIndexClockHashes,
            conflictedShardIris: shardIrisCopy,
          ));
          return;
        }

        // Safety net: re-inject indices that had 0 shards.
        // TODO: is this really useful? When would it help? Should we simply remove it?
        if (event.zeroShardIndices.isNotEmpty) {
          if (source.retryCount >= _maxRetries) {
            _log.severe('Indices have no shards after $_maxRetries retries: '
                '${event.zeroShardIndices.map((iri) => iri.debug).join(', ')}');
            inputSink.close();
            return;
          }
          _log.warning(
              '${event.zeroShardIndices.length} indices had 0 shards — '
              'reinjecting (retry ${source.retryCount + 1})');
          inputSink.add(SyncInput(
            event.zeroShardIndices,
            retryCount: source.retryCount + 1,
            indexInfos: {
              for (final iri in event.zeroShardIndices)
                if (source.indexInfos.containsKey(iri))
                  iri: source.indexInfos[iri]!,
            },
            metaIndexClockHashes: source.metaIndexClockHashes,
          ));
          return;
        }

        final isMetaPhase = source.isMetaIndexPhase;

        if (isMetaPhase) {
          // Check stability of ALL meta-index documents.
          final sw = perf?.start(perfStage);
          final snapshots = source.metaIndexClockHashes!;
          final newHashes = await readClockHashes(storage, snapshots.keys);
          // Every key in snapshots had a clock hash when we snapshotted — if
          // one disappears after a pipeline pass that is data corruption, not
          // a normal change.
          final missingKeys =
              snapshots.keys.where((k) => !newHashes.containsKey(k)).toList();
          if (missingKeys.isNotEmpty) {
            sw?.stop();
            throw StateError(
                'Meta-index document(s) lost their clock hash during sync: '
                '$missingKeys');
          }
          final anyChanged =
              snapshots.entries.any((e) => newHashes[e.key] != e.value);

          if (anyChanged) {
            if (source.retryCount >= _maxRetries) {
              _log.severe('Meta-indices unstable after $_maxRetries retries');
              sw?.stop();
              inputSink.close();
              return;
            }
            _log.fine(
                'Meta-indices changed — re-injecting (retry ${source.retryCount + 1})');
            sw?.stop();
            inputSink.add(SyncInput(
              source.indexIris,
              retryCount: source.retryCount + 1,
              indexInfos: source.indexInfos,
              metaIndexClockHashes: newHashes,
            ));
          } else {
            // Meta-indices stable → transition to content phase.
            _log.fine('Meta-indices stable — transitioning to content phase');

            final contentIndices = await indexResolver.resolveContentIndices();
            sw?.stop();
            if (contentIndices.isEmpty) {
              _log.info('No content indices found — closing pipeline');
              inputSink.close();
              return;
            }

            inputSink.add(SyncInput(
              contentIndices.keys.toList(),
              indexInfos: contentIndices,
            ));
          }
        } else {
          // Content phase complete — close the pipeline.
          _log.fine('Content phase complete — closing pipeline');
          inputSink.close();
        }
    }
  };
}
