# 015: Shard-Level File Consolidation for Performance

**Status**: Draft  
**Created**: 2026-02-02  
**Context**: GDrive initial sync from ~5s to <2s

## Problem Statement

**Current:** Sync operates on shards conceptually, but stores each resource as separate file
- 22 resources + 1 shard metadata = **23 files = 23 HTTP requests**
- Initial sync: ~5s (dominated by HTTP latency, not bandwidth)
- Target: <2s

**Root Cause:** Conceptual-physical mismatch
- Sync hierarchy: Type → Index → Shard → Resources
- Storage: Individual files per resource
- HTTP latency per file (~200ms) × 23 = performance bottleneck


## Solution: Physical Shard Files with RDF Datasets

**Align storage with logical shards:** 1 shard = 1 file containing all resources

**Technology: RDF Datasets with Named Graphs**
- **Default Graph**: Shard metadata (idx:Shard, idx:containsEntry, cm:clockHash)
- **Named Graphs**: Individual resource documents (key = documentIri, value = complete resource RdfGraph)
- **Serialization**: N-Quads format

**File Structure Transformation:**
```
Before: 23 files
  PersonalNote/*.ttl (22 files)
  Shard/index-full/shard-*.ttl (1 metadata file)

After: 3-5 files
  Shard/index-full/shard-*.nq (N-Quads datasets)
    # Each .nq file contains:
    # - Default graph: Shard metadata
    # - Named graph <note_xyz#document>: Complete resource 1
    # - Named graph <note_abc#document>: Complete resource 2
    # - ...
```

**Result:** 23 HTTP requests → 3-5 HTTP requests = **~3x faster**

## Architecture: RdfGraph Interface + Dataset Implementation Detail

**Critical Decision:** Dataset handling is GDrive-specific optimization, NOT a framework concern

**RemoteSyncStorage Interface (UNCHANGED):**
```dart
abstract class RemoteSyncStorage {
  Future<RemoteDownloadResult> download(IriTerm documentIri, {String? ifNoneMatch});
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfGraph graph, {String? ifMatch});
}
```

**GDrive Backend (Datasets are Implementation Detail):**
```dart
class GDriveShardBasedSyncStorage implements RemoteSyncStorage {
  final Directory _localCacheDir; // Persistent disk cache!
  final GDriveDirtyTracker _dirtyTracker; // Tracks which shards need upload
  
  @override
  Future<RemoteDownloadResult> download(IriTerm documentIri, ...) {
    if (_isShardDocument(documentIri)) {
      // Download shard dataset (.nq file) to disk
      final dataset = await _downloadNQuads(documentIri);
      await _writeToDiskCache(documentIri, dataset); // Persist to disk
      return RemoteDownloadResult(graph: dataset.defaultGraph); // Return metadata graph
    } else {
      // Extract resource from disk-cached shard dataset
      final shardIri = _findShardForResource(documentIri);
      final cachedDataset = await _readFromDiskCache(shardIri); // Read from disk
      final resourceGraph = cachedDataset.namedGraphs[documentIri];
      return RemoteDownloadResult(graph: resourceGraph);
    }
  }
  
  @override
  Future<RemoteUploadResult> upload(IriTerm documentIri, RdfGraph graph, ...) {
    // Resource upload: Write to disk cache, mark dirty
    await _writeResourceToDiskCache(documentIri, graph); // Persist!
    await _dirtyTracker.markDirty(documentIri);
    return RemoteUploadResult.success(); // Fake success (like GDriveLocalMirror)
    
    // Real upload happens in finalize(): build complete shard dataset from disk
  }
  
  Future<void> finalize() {
    // Build complete shard datasets from disk cache + pending uploads
    for (final shardIri in _dirtyTracker.dirtyShards) {
      final dataset = await _buildShardDatasetFromDiskCache(shardIri);
      await _uploadNQuads(shardIri, dataset);
      await _dirtyTracker.markClean(shardIri); // Success: clear dirty flag
    }
  }
  
  Future<RdfDataset> _buildShardDatasetFromDiskCache(IriTerm shardIri) async {
    final shardDocIri = shardIri.getDocumentIri();
    
    // TWO CACHE LAYERS:
    // - _readGraphFromDiskCache: Internal cache for framework-uploaded graphs (not on GDrive in shard mode)
    // - _readDatasetFromDiskCache: GDrive mirror cache (actual .nq files from remote)
    
    // 1. Default graph: Read from internal graph cache (framework uploaded via upload(shardIri, graph))
    final defaultGraph = await _readGraphFromDiskCache(shardDocIri);
    if (defaultGraph == null) {
      throw StateError('Shard graph not in cache: $shardDocIri');
    }
    
    // 2. Locally changed resource graphs from internal cache
    final namedGraphs = <IriTerm, RdfGraph>{};
    final dirtyResources = await _dirtyTracker.getDirtyResourcesForShard(shardIri);
    for (final docIri in dirtyResources) {
      final graph = await _readGraphFromDiskCache(docIri); // Internal cache
      if (graph != null) {
        namedGraphs[docIri] = graph;
      }
    }
    
    // 3. Missing resources? Determine from shard metadata (idx:containsEntry in default graph)
    final allResourceIris = _extractResourceIrisFromShardGraph(defaultGraph);
    final missingResourceIris = allResourceIris.where((docIri) => !namedGraphs.containsKey(docIri));
    
    if (missingResourceIris.isNotEmpty) {
      // Try to get from GDrive mirror cache first (actual .nq files downloaded earlier)
      var cachedDataset = await _readDatasetFromDiskCache(shardDocIri); // Mirror cache!
      
      // If not in mirror cache, download from remote
      if (cachedDataset == null) {
        cachedDataset = await _downloadNQuads(shardDocIri);
        await _writeToDiskCache(shardDocIri, cachedDataset); // Cache in mirror
      }
      
      // Fill in missing resources from mirror cache/downloaded dataset
      for (final docIri in missingResourceIris) {
        final remoteGraph = cachedDataset.namedGraphs[docIri];
        if (remoteGraph != null) {
          namedGraphs[docIri] = remoteGraph; // Use remote for unfetched
        }
      }
    }
    
    return RdfDataset(defaultGraph: defaultGraph, namedGraphs: namedGraphs);
  }
}
```

**Key Pattern:** "Mark Dirty + Finalize" with **Disk Persistence** (same as GDriveLocalMirror)
- `upload(resourceIri, graph)`: **Write to disk cache**, mark dirty in persistent tracker
- `finalize()`: Read from disk, build complete shard datasets, upload to remote
- **On failure**: Disk cache + dirty flags persist → Resume on next sync

## RemoteSyncOrchestrator Flow (UNCHANGED)

```dart
Future<void> _syncShard(ShardSyncSpec shard) async {
  // 1. Download shard (backend returns default graph, caches dataset internally)
  final shardMetadata = await _remoteSyncStorage.download(shardIri);
  
  // 2. Build queue (compare local vs remote clockHashes)
  final queue = await _buildDocumentQueue(shard, shardMetadata);
  
  // 3. Sync resources (backend extracts from cached dataset, marks dirty on upload)
  for (final entry in queue) {
    await _syncDocument(entry.resourceIri, ...);
  }
  
  // 4. Upload happens in finalize() (backend builds complete shard dataset)
}
```

**Critical:** Orchestrator unchanged, backend handles datasets transparently!


## Lazy Fetch Solution: Conditional Remote Shard Download

**Problem:** With `OnRequest` fetch policy, app DB only has fetched resources, but shard upload needs ALL resources.

**Solution:** Use cached shard dataset (from `initialize()`) or download if missing during `finalize()`

```dart
Future<RdfDataset> _buildShardDatasetFromDiskCache(IriTerm shardIri) async {
  // 1. Default graph: Read cached shard graph (framework uploaded it!)
  final defaultGraph = await _readGraphFromDiskCache(shardIri.getDocumentIri());
  
  // 2. Locally changed resource named graphs (from disk cache)
  final namedGraphs = await _getLocalChangedResourceGraphs(shardIri);
  
  // 3. Missing resources? Parse shard metadata to find them
  final allResourceIris = _extractResourceIrisFromShardGraph(defaultGraph);
  final missingResourceIris = allResourceIris.where((docIri) => !namedGraphs.containsKey(docIri));
  
  if (missingResourceIris.isNotEmpty) {
    // Check mirror cache first (likely already downloaded in initialize())
    var dataset = await _readDatasetFromDiskCache(shardIri);
    if (dataset == null) {
      // Not cached - download from remote (rare: only if initialize() didn't get it)
      dataset = await _downloadNQuads(shardIri);
    }
    for (final docIri in missingResourceIris) {
      namedGraphs[docIri] = dataset.namedGraphs[docIri]!;
    }
  }
  
  return RdfDataset(defaultGraph: defaultGraph, namedGraphs: namedGraphs);
}
```

**Key Points:**
- ✅ **Cache check first**: `initialize()` downloads new/updated shards → usually cached by `finalize()`
- ✅ **Conditional download**: Only download if not in cache (rare case: shard created between initialize/finalize)
- ✅ **0-1 HTTP request**: 0 if cached from initialize(), 1 if missing
- ✅ **Shard graph from framework**: Backend reads cached shard graph that framework uploaded
- ✅ **No framework access**: Backend only reads its own disk cache + downloads from remote
- ✅ **Still faster**: 0-1 shard download << 22 resource downloads

**Mirror implication:** Mirror can stay lazy! Don't need to download everything eagerly.

## Backend-Specific Implementation

### GDrive: Shard-Based (Performance)
- N-Quads format (.nq files)
- Dataset cache with named graphs
- "Mark dirty + finalize" pattern
- Target: 23 files → 3-5 files = **~3x speedup**

### Solid: Resource-Based (Unchanged)
- Turtle format (.ttl files)
- Individual resource URIs (LDP, SPARQL, ACLs)
- No changes needed

### Local Dir: Configurable (Testing)
- Both modes supported
- Test shard logic without GDrive API

## Performance Projections

**Current (resource-based):**
- 22 resources + 1 shard = 23 HTTP requests × 200ms = **~5s**

**Proposed (shard-based):**
- 3-5 shards × 250ms = **~1.5-2s**

**Speedup:** 2.5-3.3x improvement

## Implementation Plan (4 Weeks, Pre-Alpha)

**Week 1:** GDriveShardBasedSyncStorage
- Disk-based cache (`_localCacheDir`, `_dirtyTracker` with persistent state)
- Download: Cache dataset to disk, return/extract graphs
- Upload: Write to disk, mark dirty in persistent tracker
- Finalize: Build dataset (framework metadata + local changes + remote fill)
- Lazy remote fetch: Download remote shard only if missing resources
- Failure handling: Resume from disk cache + dirty flags

**Week 2:** RemoteSyncOrchestrator Integration
- Verify flow unchanged with new backend
- Test shard download → resource extraction → upload cycle
- Conflict resolution with concurrent shards

**Week 3:** Local Dir Shard Mode
- Add `DirSyncStorage.shardBased()` factory
- Test N-Quads locally without GDrive API

**Week 4:** Performance Validation
- Benchmark: resource-based vs shard-based
- Verify: <2s initial sync, CRDT correctness, multi-installation sync

**Migration:** Pre-alpha = delete remote + re-sync (no migration needed)

## Success Criteria

- ✅ Initial sync: <2s (from ~5s)
- ✅ CRDT merge correctness preserved
- ✅ Conflict resolution works (optimistic locking)
- ✅ GDrive (shard-based) + Solid (resource-based) coexist
- ✅ All existing tests pass

---

**Status:** Ready for implementation  
**Next Steps:** RdfGraph interface reversion, then GDriveShardBasedSyncStorage implementation

