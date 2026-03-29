/// Optional extension of [RemoteSyncStorage] for the streaming sync pipeline.
///
/// Provides the four backend-owned stream transformers for Stages 2, 6, 8, 12.
/// Implementations may share internal state across transformers (e.g. a
/// per-shard resource cache populated in Stage 2, consumed in Stage 6).
library;

import 'dart:async';

import 'package:locorda_core/src/sync/pipeline/pipeline_types.dart';

/// Optional interface for [RemoteSyncStorage] implementations that support
/// the streaming sync pipeline.
///
/// Backends implement this alongside [RemoteSyncStorage]. The pipeline
/// orchestrator checks for this interface at runtime to select the streaming
/// pipeline over the legacy orchestrator.
///
/// ## Stream element types
///
/// Each transformer receives a stream where data events are the documented
/// input type and [Boundary] events ([ShardComplete], [PhaseComplete]) flow
/// inline. Backend stages must:
/// - Pass [Boundary] events through unchanged (after flushing any in-flight
///   operations when receiving boundaries).
/// - Process only events of the documented input type.
abstract interface class RemoteSyncPipelineSupport {
  /// Stage 2: Shard Fetch — conditionally download shard documents.
  ///
  /// Input: [ShardRefEvent] ([ShardRef] data + [PhaseComplete] boundary).
  /// Output: [FetchedShardEvent] ([FetchedShard] variants + [PhaseComplete] boundary).
  ///
  /// Must buffer boundary events until all in-flight fetches complete, then forward.
  StreamTransformer<ShardRefEvent, FetchedShardEvent> shardFetch();

  /// Stage 6: Resource Fetch — download resource graphs.
  ///
  /// Input: [LoadedCandidateEvent] ([LoadedCandidate] data + [PhaseComplete]/[ShardComplete] boundaries).
  /// Output: [FetchedCandidateEvent] ([FetchedCandidate] data + [PhaseComplete]/[ShardComplete] boundaries).
  ///
  /// `remoteOnly` / `conflictCandidate` → fetch from remote (using [LoadedCandidate.storedRemoteEtag] for conditional GET).
  /// `localOnly` / `remoteRemoved` → pass through as [FetchedCandidate] without fetch.
  StreamTransformer<LoadedCandidateEvent, FetchedCandidateEvent>
      resourceFetch();

  /// Stage 8: Resource Upload — upload merged resources.
  ///
  /// Input: [MergedResourceEvent] ([MergeResult] data + [PhaseComplete]/[ShardComplete] boundaries).
  /// Output: [UploadedResourceEvent] ([UploadResult] data + [PhaseComplete]/[ShardComplete] boundaries).
  ///
  /// `needsUpload == true` → encode and upload to remote.
  /// Otherwise → pass through as [UploadResult].
  StreamTransformer<MergedResourceEvent, UploadedResourceEvent>
      resourceUpload();

  /// Stage 12: Shard Upload — upload merged shard documents.
  ///
  /// Input: [MergedShardEvent] ([MergedShard] data + [PhaseComplete] boundary).
  /// Output: [UploadedShardEvent] ([UploadedShard] data + [PhaseComplete] boundary).
  StreamTransformer<MergedShardEvent, UploadedShardEvent> shardUpload();
}
