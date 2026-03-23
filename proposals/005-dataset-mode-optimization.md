# 005: Dataset Mode Optimization — Bulk Sync with Shard Datasets

## Context

When `useShardDatasets = true`, all resources in a shard are bundled into a single TriG/Jelly file. This is the high-performance mode for backends like Google Drive and local directories where:
- Fewer large files are better than many small files (API quotas, filesystem overhead)
- Bulk download of one shard dataset = all resources in that shard

Dataset mode is particularly relevant for the **15,000 resource initial sync** scenario because it means we only need to download ~4-16 shard files instead of 15,000 individual files.

## Current Dataset Mode Flow

```
1. Download shard dataset (1 TriG file containing ~1000-4000 named graphs)
2. Parse full dataset into RdfDataset object
3. Extract individual named graphs → Map<IriTerm, RdfGraph>
4. For each resource:
   a. Get remote graph from extracted map
   b. Get local graph from DB
   c. CRDT merge
   d. Reconcile shards
5. Build combined storage for Phase 2 merge
6. After merge: rebuild full dataset from canonical graphs
7. Upload entire shard dataset
8. Commit all to DB
```

The problem: step 2-4 materializes the entire dataset in memory, then processes resources one by one. For 15,000 resources across 4 shards, this means ~4,000 RdfGraph objects in memory simultaneously.

## Proposed Dataset Mode Streaming

### Download Phase: Stream Named Graphs from Dataset

Instead of parsing the full dataset into memory, stream individual named graphs as they're decoded:

```dart
/// Stream named graphs from a dataset file as they're decoded.
///
/// Each yielded entry represents one resource, immediately available
/// for processing without waiting for the full dataset to parse.
Stream<RdfNamedGraph> streamDatasetGraphs(
  Uint8List rawBytes, {
  required String contentType,
}) async* {
  // For Jelly binary: stream frames, yield complete graphs
  // For TriG text: stream-parse, yield on graph boundary
  final decoder = _rdfCore.createStreamingDatasetDecoder(contentType);
  await for (final graph in decoder.decode(rawBytes)) {
    yield graph;
  }
}
```

This requires a streaming decoder for the RDF format (Jelly already supports streaming by design; TriG would need a streaming parser).

### Initial Sync Fast Path for Dataset Mode

When syncing to an empty local, the entire flow simplifies dramatically:

```
1. Download shard dataset (1 file)
2. Stream named graphs from dataset
3. For each named graph:
   a. Extract type IRI and clock (minimal parsing)
   b. Determine shard assignments
   c. Buffer into commit batch
4. When batch full: pre-encode + commit to DB
5. After all resources: upload shard dataset back (if needed)
```

No CRDT merge needed. No remote re-upload needed (remote already has the latest). Just parse and store.

```dart
/// Optimized initial sync for dataset mode.
///
/// When local is empty, we know every resource is RemoteOnly.
/// Skip merge entirely, just store.
Future<void> initialSyncDataset(
  IriTerm shardIri,
  RdfDataset remoteDataset,
  DateTime syncTime,
) async {
  final batch = <MergedResource>[];

  for (final namedGraph in remoteDataset.namedGraphs) {
    final documentIri = namedGraph.name;
    final graph = namedGraph.graph;

    // Minimal processing
    final typeIri = _extractTypeIri(graph, documentIri);
    final clock = _hlcService.getCurrentClock(graph, documentIri);
    final shards = await _shardDeterminer.determineShards(...);

    batch.add(MergedResource(
      documentIri: documentIri,
      typeIri: typeIri,
      mergedGraph: graph,
      clock: clock,
      shardIris: shards.shards,
      missingGroupIndices: shards.missingGroupIndices,
      needsUpload: false,  // Remote already has it!
    ));

    if (batch.length >= commitBatchSize) {
      await _commitBatch(batch, syncTime);
      batch.clear();
    }
  }

  if (batch.isNotEmpty) {
    await _commitBatch(batch, syncTime);
  }
}
```

**Key insight**: `needsUpload: false` — for initial sync from remote, we don't need to re-upload anything! This eliminates half the I/O.

### Byte Pass-Through for DB Storage

If the remote sends Jelly-encoded data and the DB stores Jelly-encoded data, we can skip the decode-then-re-encode cycle entirely for the DB write:

```dart
/// Extract individual resource bytes from a Jelly dataset
/// without decoding to RdfGraph objects.
///
/// Returns: stream of (documentIri, rawJellyBytes) pairs
Stream<(IriTerm, Uint8List)> extractRawGraphs(Uint8List datasetBytes) {
  // Jelly format: sequence of named graph frames
  // Each frame has: graph name IRI + encoded triples
  // We can extract the IRI from the header and pass through the bytes
}
```

This is the most aggressive optimization: for initial sync in dataset mode, the pipeline becomes:

```
Download shard bytes → extract raw graph bytes → store raw bytes in DB
```

No RDF parsing at all for the DB write path. We still need to parse minimally (type IRI, clock hash) for index entries, but the full graph decode is deferred until hydration time.

### Initial Push Fast Path for Dataset Mode

When pushing to an empty remote (e.g., after Matrix import), dataset mode offers a natural optimization: instead of uploading 15K individual resources, build the shard datasets directly from local DB state and upload 4 dataset files:

```dart
/// Optimized initial push for dataset mode.
///
/// When remote is empty, we know every resource needs uploading.
/// Skip per-resource download (all 404), merge contracts, and
/// individual uploads. Instead, build datasets from local state
/// and upload as shard datasets.
Future<void> initialPushDataset(
  List<ShardSyncSpec> shards,
  DateTime syncTime,
) async {
  for (final shard in shards) {
    // Get all local resources for this shard from index entries
    final entries = await _storage.getActiveIndexEntriesForShard(shard.shardIri);
    if (entries.isEmpty) continue;

    // Load all local documents in batch
    final documentIris = entries.map((e) => e.resourceIri.getDocumentIri()).toList();
    final documents = await _storage.getDocumentsByIri(documentIris);

    // Build dataset directly from local graphs
    final namedGraphs = <RdfNamedGraph>[];
    for (final entry in entries) {
      final docIri = entry.resourceIri.getDocumentIri();
      final doc = documents[docIri];
      if (doc != null) {
        namedGraphs.add(RdfNamedGraph(docIri, doc.document));
      }
    }

    // Build shard document + dataset, upload as single file
    final dataset = _buildShardDataset(shard.shardIri, namedGraphs);
    await _remoteSyncStorage.uploadDataset(
      shard.shardIri.getDocumentIri(), dataset);
  }
}
```

**Key insight**: For initial push in dataset mode, we can skip the entire per-resource sync pipeline and go directly from DB → dataset → upload. This reduces the problem from "sync 15K resources" to "upload 4 files".

### Shard Re-upload Optimization

After merging, the shard dataset needs re-uploading. Currently, this involves:
1. Regenerating the shard document (entries list)
2. Collecting all canonical resource graphs
3. Building a full RdfDataset with all named graphs
4. Encoding to TriG/Jelly
5. Uploading

Optimization: if only some resources changed (or none, in initial sync), diff the shard and upload only if there are actual changes:

```dart
/// Check if shard document needs re-upload.
///
/// Compare the shard entries (resource IRIs + clock hashes) before and after merge.
/// If identical, skip the expensive dataset serialization + upload.
bool shardNeedsUpload(
  Map<IriTerm, String> originalEntries,
  Map<IriTerm, String> mergedEntries,
) {
  if (originalEntries.length != mergedEntries.length) return true;
  for (final entry in originalEntries.entries) {
    if (mergedEntries[entry.key] != entry.value) return true;
  }
  return false;
}
```

## Memory Management

For 15,000 resources in dataset mode:

### Current Memory Profile
- Full dataset in memory: ~100-500MB depending on resource size
- All extracted named graphs: same data, second copy
- All merged graphs: third copy
- Pre-encoded bytes for DB: fourth copy

### Streaming Memory Profile
- One batch of resources (1000): ~10-30MB
- Pre-encoded bytes for current batch: ~10-30MB
- Previous batch bytes freed after commit
- Peak memory: ~2 batches = ~40-60MB

The streaming approach reduces peak memory by ~5-10×.

## Performance Estimate for Dataset Mode

### Current — Empty Local, Full Remote (15,000 resources, 4 shard datasets)
```
Download 4 datasets:       ~0.5s
Parse 4 full datasets:     ~2s
Extract 15K named graphs:  ~0.5s
CRDT merge 15K resources:  ~3s  (all trivial accept-remote)
Rebuild 4 datasets:        ~2s
Upload 4 datasets:         ~0.5s
DB commit 15K resources:   ~3s
Total:                     ~12s
```

### Current — Empty Remote, Full Local (15,000 resources, 4 shard datasets)
```
Download 4 datasets:       ~0.1s  (all return 404)
Download 15K as datasets:  ~0.1s  (all return 404 — pure waste)
Load 15K from DB:          ~1-2s
Merge contract loading:    ~1-2s  (unnecessary — nothing to merge)
Rebuild 4 datasets:        ~2s
Upload 4 datasets:         ~0.5s
DB commit 15K resources:   ~3s
Total:                     ~8-10s
```

### Streaming Dataset Mode — Empty Local (pull)
```
Download 4 datasets:       ~0.5s  (parallel)
Stream + store 15K:        ~2s    (parse + DB write, pipelined)
Shard finalize:            ~0.3s  (re-upload only if changed — typically not)
Total:                     ~2-3s
```

### Streaming Dataset Mode — Empty Remote (push)
```
Download 4 datasets:       ~0.1s  (all 404, detected immediately)
Load 15K from DB:          ~0.5s  (batch read)
Build 4 datasets:          ~1s    (from local graphs)
Upload 4 datasets:         ~0.5s  (parallel)
DB commit ETags:           ~0.3s  (update ETag cache only)
Total:                     ~2-3s
```

### Streaming Dataset Mode (incremental sync, 100 changed)
```
Download 4 datasets:       ~0.5s  (parallel, most return 304)
Compare entries:           ~0.1s  (clock hash comparison)
Merge 100 conflicts:       ~0.2s
Rebuild 1 dataset:         ~0.5s  (only changed shard)
Upload 1 dataset:          ~0.2s
DB commit 100 resources:   ~0.1s
Total:                     ~1-2s
```

## Implementation Notes

### Jelly Streaming Decoder

The Jelly codec (used for both remote and DB storage) is frame-based, which naturally supports streaming. The key addition is a streaming decoder that yields complete named graphs without buffering the entire dataset:

```dart
abstract class StreamingDatasetDecoder {
  /// Decode a byte stream into individual named graphs.
  Stream<RdfNamedGraph> decodeStream(Stream<List<int>> bytes);
}
```

This would need to be implemented in the `locorda_rdf_jelly` package.

### TriG Streaming Parser

For text-based TriG (used by some backends), a streaming parser that yields on `GRAPH { ... }` boundaries. This is lower priority since Jelly is the preferred codec.

### Dataset-Aware Commit

The commit stage needs to know it's operating in dataset mode so it can:
- Skip per-resource remote uploads (the dataset upload handles this)
- Track which shards contain which committed resources
- Build the shard dataset for upload after commit

```dart
class DatasetCommitStage extends CommitStage {
  /// Commits resources to DB only (no individual remote uploads).
  /// Returns committed resources grouped by shard for dataset upload.
  Future<Map<IriTerm, List<CommittedResource>>> commitForDataset(
    Stream<MergedResource> merged, {
    required DateTime syncTime,
    int batchSize = 1000,
  });
}
```
