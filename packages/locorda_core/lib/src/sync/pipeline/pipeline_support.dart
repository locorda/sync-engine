/// Optional extension of [RemoteSyncStorage] for the streaming sync pipeline.
///
/// Provides the four backend-owned stream transformers for Stages 2, 5, 8, 12.
/// Implementations may share internal state across transformers (e.g. a
/// per-shard resource cache populated in Stage 2, consumed in Stage 5).
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
  /// Input stream elements: [ShardRef] data events + [PhaseComplete] boundaries.
  /// Output stream elements: [FetchedShard] variants + [PhaseComplete] boundaries.
  ///
  /// Must buffer [PhaseComplete] boundaries until all in-flight fetches
  /// complete, then forward.
  StreamTransformer<Object, Object> shardFetch();

  /// Stage 5: Resource Fetch — download resource graphs.
  ///
  /// Input stream elements: [SyncCandidate] data + [ShardComplete] + [PhaseComplete].
  /// Output stream elements: [FetchedCandidate] data + [ShardComplete] + [PhaseComplete].
  ///
  /// `remoteOnly` / `conflictCandidate` → fetch from remote.
  /// `localOnly` / `remoteRemoved` → pass through as [FetchedCandidate] without fetch.
  StreamTransformer<Object, Object> resourceFetch();

  /// Stage 8: Resource Upload — upload merged resources.
  ///
  /// Input stream elements: [MergeResult] data + [ShardComplete] + [PhaseComplete].
  /// Output stream elements: [UploadResult] data + [ShardComplete] + [PhaseComplete].
  ///
  /// `needsUpload == true` → encode and upload to remote.
  /// Otherwise → pass through as [UploadResult].
  StreamTransformer<Object, Object> resourceUpload();

  /// Stage 12: Shard Upload — upload merged shard documents.
  ///
  /// Input stream elements: [MergedShard] data + [PhaseComplete].
  /// Output stream elements: [UploadedShard] data + [PhaseComplete].
  StreamTransformer<Object, Object> shardUpload();
}
