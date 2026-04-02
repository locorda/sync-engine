/// Unified stream-based backend for remote sync storage.
///
/// Replaces the former FPR/SDS backend split with a single
/// interface that works with raw content (text or binary). The pipeline
/// adapters ([FilePerResourceRemoteSyncStorage],
/// [ShardDatasetRemoteSyncStorage]) handle RDF encoding/decoding (CPU work),
/// while the backend handles only I/O.
///
/// Backends control parallelism themselves — whether sequential, pooled,
/// or using transport-level batching (e.g. Solid bulk endpoints).
library;

import 'dart:typed_data';

import 'package:locorda_core/src/storage/remote_storage.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_jelly/jelly.dart';

// ---------------------------------------------------------------------------
// Content-type helpers
// ---------------------------------------------------------------------------

/// Whether [contentType] is a binary RDF format (Jelly).
bool isBinaryContentType(String contentType) =>
    contentType == jellyGraph.primaryMimeType ||
    contentType == jelly.primaryMimeType;

/// Whether [contentType] encodes an RDF dataset (quads) rather than a graph.
bool isDatasetContentType(String contentType) =>
    contentType == trig.primaryMimeType ||
    contentType == nquads.primaryMimeType ||
    contentType == jelly.primaryMimeType;

// ---------------------------------------------------------------------------
// Raw content — opaque to the backend, just bytes/text with content type.
// ---------------------------------------------------------------------------

/// Transport-level content passed between pipeline adapters and backends.
///
/// The backend receives [RawContent] for uploads and returns it for downloads.
/// It never interprets the payload — encoding/decoding is the pipeline
/// adapter's responsibility.
sealed class RawContent {
  /// MIME type of the content (e.g. `text/turtle`, `application/x-jelly-rdf`).
  String get contentType;

  const RawContent();
}

/// Text-based content (Turtle, JSON-LD, N-Triples, TriG, …).
class TextContent extends RawContent {
  final String text;

  @override
  final String contentType;

  const TextContent(this.text, {required this.contentType});
}

/// Binary content (Jelly, CBOR-LD, …).
class BinaryContent extends RawContent {
  final Uint8List bytes;

  @override
  final String contentType;

  const BinaryContent(this.bytes, {required this.contentType});
}

// ---------------------------------------------------------------------------
// Unified backend interface
// ---------------------------------------------------------------------------

/// Stream-based remote sync backend — pure I/O, no RDF knowledge.
///
/// Implementations receive a stream of requests and emit results **in the
/// same order**. The backend controls parallelism internally:
///
/// - Sequential backends use `asyncMap` on each request.
/// - Concurrent backends maintain an internal pool (e.g. 5 parallel HTTP
///   connections).
/// - Batching backends buffer requests with a timeout and flush as
///   transport-level batch requests.
///
/// The pipeline never sends boundary events to the backend — boundaries are
/// handled by the adapter layer that drains outstanding results before
/// forwarding the boundary downstream.
abstract interface class RemoteSyncBackend {
  /// Download documents from remote storage.
  ///
  /// Results must be emitted in the same order as the input requests.
  /// For conditional downloads, [RemoteDownloadRequest.ifNoneMatch] carries
  /// the stored ETag; backends should return
  /// [RemoteDownloadResult.notModified] when appropriate.
  Stream<RemoteDownloadResult<RawContent>> download(
      Stream<RemoteDownloadRequest> requests);

  /// Upload documents to remote storage.
  ///
  /// Results must be emitted in the same order as the input requests.
  /// For conditional uploads, [RemoteUploadRequest.ifMatch] carries the
  /// expected ETag; backends should return [RemoteUploadResult.conflict]
  /// on precondition failure.
  Stream<RemoteUploadResult> upload(
      Stream<RemoteUploadRequest<RawContent>> requests);
}
