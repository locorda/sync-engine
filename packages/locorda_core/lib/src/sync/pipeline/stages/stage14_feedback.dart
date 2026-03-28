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
import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:logging/logging.dart';

final _log = Logger('Stage14.Feedback');

/// Maximum number of meta-index re-injections before aborting.
const _maxRetries = 4;

/// Returns an asyncExpand function for Stage 14.
///
/// Usage: `stream.asyncExpand(feedback(inputController, storage, contentIndicesFactory))`
///
/// [contentIndicesFactory] is called exactly once (when transitioning from
/// meta to content phase) and must return the full set of content indices
/// with their [IndexInputInfo] (fetch policy + resource type IRI).
///
/// The factory is provided by [StreamingRemoteSyncOrchestrator] and
/// encapsulates the effective config + DB queries needed to enumerate all
/// FullIndex IRIs (from IoI entries) and subscribed GroupIndex IRIs.
Stream<CommittedShardEvent> Function(CommittedShardEvent) feedback(
  // ignore: close_sinks — closed by feedback logic, not by the caller
  StreamSink<SyncInput> inputSink,
  Storage storage,
  Future<Map<IriTerm, IndexInputInfo>> Function() contentIndicesFactory,
) {
  return (CommittedShardEvent event) async* {
    switch (event) {
      case ShardCommitResult():
        yield event;
      case CommittedShardBoundary(:final boundary):
        yield event; // pass through so caller can monitor
        switch (boundary) {
          case ShardComplete():
            _log.warning(
                'Unexpected ShardComplete in stage 14 — only PhaseComplete expected');
          case PhaseComplete():
            final source = boundary.source;

            // Safety net: re-inject indices that had 0 shards.
            if (boundary.zeroShardIndices.isNotEmpty) {
              if (source.retryCount >= _maxRetries) {
                _log.severe(
                    'Indices have no shards after $_maxRetries retries: '
                    '${boundary.zeroShardIndices}');
                inputSink.close();
                return;
              }
              _log.warning(
                  '${boundary.zeroShardIndices.length} indices had 0 shards — '
                  'reinjecting (retry ${source.retryCount + 1})');
              inputSink.add(SyncInput(
                boundary.zeroShardIndices,
                retryCount: source.retryCount + 1,
                indexInfos: {
                  for (final iri in boundary.zeroShardIndices)
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
              final snapshots = source.metaIndexClockHashes!;
              final newHashes = <IriTerm, String>{};
              var anyChanged = false;

              for (final entry in snapshots.entries) {
                final docIri = entry.key;
                final snapshot = entry.value;
                final doc = await storage.getDocument(docIri);
                final currentHash = doc?.document
                        .findSingleObject<LiteralTerm>(
                            docIri, SyncManagedDocument.crdtClockHash)
                        ?.value ??
                    '';
                newHashes[docIri] = currentHash;
                if (currentHash != snapshot) anyChanged = true;
              }

              if (anyChanged) {
                if (source.retryCount >= _maxRetries) {
                  _log.severe(
                      'Meta-indices unstable after $_maxRetries retries');
                  inputSink.close();
                  return;
                }
                _log.fine(
                    'Meta-indices changed — re-injecting (retry ${source.retryCount + 1})');
                inputSink.add(SyncInput(
                  source.indexIris,
                  retryCount: source.retryCount + 1,
                  indexInfos: source.indexInfos,
                  metaIndexClockHashes: newHashes,
                ));
              } else {
                // Meta-indices stable → transition to content phase.
                _log.fine(
                    'Meta-indices stable — transitioning to content phase');

                final contentIndices = await contentIndicesFactory();
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
    }
  };
}
