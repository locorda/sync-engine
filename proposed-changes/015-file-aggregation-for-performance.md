# 015: Shard-Level File Consolidation for Performance

**Status**: Draft  
**Created**: 2026-02-02  
**Context**: GDrive initial sync performance optimization  
**Builds On**: Existing shard architecture (not a new concept)

## Problem Statement

Current architecture **already uses shards** as the conceptual unit for sync, but stores each individual resource as a separate physical file within those shards. This creates a mismatch:

**Existing Shard Hierarchy (Conceptual):**
```
Type → Index → Shard → Resources
```

**Current File Structure (Physical):**
```
notes/
  index-full-123/
    index                    # Index document
    shard-mod-md5-1-0/       # Shard as folder
      note-uuid-1.ttl        # Individual resource files
      note-uuid-2.ttl
      note-uuid-3.ttl
```

**Performance Impact:**
- Initial sync: ~5 seconds for 22 resource files (168KB total)
- Dominated by HTTP roundtrip latency (150-200ms per file)
- **Sync operates on shards, but downloads individual files**
- Geographic latency to cloud storage APIs (US/Europe)
- Even with perfect parallelization: ~3s baseline

**Root Cause:**
- **Conceptual-physical mismatch**: Shards are logical units but not storage units
- HTTP latency per file, not bandwidth bottleneck
- Cloud storage APIs (GDrive, Solid) optimized for larger files
- Existing sync hierarchy already understands shards - we just don't leverage them for storage

**Baseline Comparison:**
- Local directory backend: 1.36s (no network latency)
- GDrive with mirror: ~5s (HTTP overhead per resource file)
- Target: Store shard = 1 file → fewer HTTP roundtrips → faster sync

## Proposed Solution: Physical Shard Files

### Core Concept

**Align physical storage with logical shard structure**: Make each shard a single file containing all its resources, not a folder of individual files.

**Example Transformation:**
```
Before (folder-based shards):
  notes/index-full-123/
    index                           # Index document  
    shard-mod-md5-1-0/              # Folder per shard
      note-uuid-1.ttl               # Individual files
      note-uuid-2.ttl
      note-uuid-3.ttl
      
After (file-based shards):
  notes/index-full-123/
    index                           # Index document (unchanged)
    shard-mod-md5-1-0.ttl           # Single file per shard
```

**Result:**
- 22 resource files → 3-5 shard files
- Sync already operates on shards → now storage matches
- Fewer HTTP requests → faster initial sync

### Design Principles

1. **Leverage Existing Architecture**: Use existing shard boundaries, don't invent new ones
2. **Backend Agnostic**: Works with GDrive, Solid, Local Dir
3. **CRDT Correct**: Maintains existing merge semantics (already shard-level)
4. **Sync Algorithm Unchanged**: `RemoteSyncOrchestrator` flow stays the same
5. **Atomic Operations**: Shard file = atomic unit (existing guarantee)

## Detailed Design

### 1. Current Sync Flow (Unchanged Conceptually)

**From `RemoteSyncOrchestrator.sync()`:**
```dart
for (final resourceType in syncOrder) {
  // Step 1: Sync Index Documents
  final indices = await _syncIndexDocuments(resourceType, ...);
  
  // Step 2: For each index, sync its shards
  for (final index in indices) {
    final shards = await _buildShardSyncSpecs(index);
    
    // Step 3: For each shard, sync its resources
    for (final shard in shards) {
      await _syncShard(resourceType, index, shard, ...);
    }
  }
}
```

**Key Insight:** Sync **already operates hierarchically on shards**! We just need to change what "sync a shard" means physically.

### 2. Current Implementation: `_syncShard()`

**Today (file-per-resource):**
```dart
Future<void> _syncShard(ShardSyncSpec shard) async {
  final shardIri = shard.shardIri;
  
  // 1. Download shard "document" (currently downloads folder metadata?)
  final shardDoc = await _remoteSyncStorage.download(
    shardIri.getDocumentIri()
  );
  
  // 2. For each resource in shard:
  for (final resourceIri in getResourcesFromShard(shardDoc)) {
    // Download individual resource file
    final resource = await _remoteSyncStorage.download(resourceIri);
    // Merge, upload, etc.
  }
}
```

**Problem:** Shard has document IRI but no actual file - resources are separate files.

### 3. Proposed Implementation: Physical Shard Files

**Key Insight:** The sync algorithm in `RemoteSyncOrchestrator._syncShard()` already **expects to download individual resource documents**. With physical shard files, we need to:
1. Download shard once (contains all resources)
2. Extract individual resource graphs from shard
3. Run existing CRDT merge logic per resource
4. Upload modified shard (if changes were made)

**Implementation Strategy:**
```dart
Future<void> _syncShard(ShardSyncSpec shard, ...) async {
  final shardIri = shard.shardIri;
  final shardDocumentIri = shardIri.getDocumentIri();
  
  // 1. Download complete shard file (contains all resource documents)
  final originalRemoteShard = await _remoteSyncStorage.download(
    shardDocumentIri,
    ifNoneMatch: lastKnownETag,
  );
  
  if (originalRemoteShard == null) {
    // Shard doesn't exist remotely yet - continue with local data
  }
  
  // 2. Build document queue (resource IRIs that need sync)
  final queue = await _buildDocumentQueue(shard, originalRemoteShard);
  
  // 3. For each resource in queue, extract from shard and merge
  for (final entry in queue) {
    final resourceDocumentIri = entry.resourceIri.getDocumentIri();
    
    // Extract resource graph from shard (if present)
    final remoteResourceGraph = originalRemoteShard == null 
      ? null 
      : _extractResourceFromShard(originalRemoteShard, resourceDocumentIri);
    
    // Run existing CRDT merge logic (unchanged)
    await _syncDocument(resourceDocumentIri, ...);
  }
  
  // 4. If any resources changed locally, rebuild and upload shard
  final localChanges = await _storage.getShardsToUpdate(lastSyncTimestamp);
  if (localChanges.contains(shardIri)) {
    final newShardGraph = await _buildShardGraph(shardIri);
    await _remoteSyncStorage.upload(
      shardDocumentIri,
      newShardGraph,
      ifMatch: originalRemoteShard?.etag,
    );
  }
}
```

**Critical Integration Point:** `RemoteSyncStorage` remains **document-centric** (downloads/uploads document IRIs), but now:
- **Shard document IRI** → physical file containing all resources
- **Resource document IRI** → extracted from shard graph (not separate file)

### 4. RemoteSyncStorage Interface Changes

**Current Interface (Unchanged):**
```dart
abstract class RemoteSyncStorage {
  Future<DownloadResult?> download(IriTerm documentIri, {String? ifNoneMatch});
  Future<UploadResult> upload(IriTerm documentIri, RdfGraph graph, {String? ifMatch});
}
```

**Key Realization:** Interface stays the same! We just change **what files are downloaded**:

**Before (file-per-entity):**
```dart
// Downloading resource document
download(IriTerm('https://example.org/note-123'))
  → reads file: notes/index-full/shard-mod/note-123.ttl
  → returns graph with note-123 resource
```

**After (physical shard files):**
```dart
// Downloading resource document - now extracted from shard
download(IriTerm('https://example.org/note-123'))
  → reads file: notes/index-full/shard-mod.ttl  (SHARD file!)
  → extracts graph for note-123 resource
  → returns graph with note-123 resource

// Downloading shard document
download(IriTerm('https://example.org/shard-mod'))
  → reads file: notes/index-full/shard-mod.ttl
  → returns complete shard graph (all resources)
```

**Implementation Pattern:**
```dart
class GDriveSyncStorage implements RemoteSyncStorage {
  @override
  Future<DownloadResult?> download(IriTerm documentIri, {String? ifNoneMatch}) async {
    // Determine if this is a shard document or resource document
    final resourceLocator = _resourceLocator.locate(documentIri);
    
    if (resourceLocator.isShardDocument) {
      // Download complete shard file
      return await _downloadFile(resourceLocator.filePath, ifNoneMatch);
    } else {
      // Resource document - need to extract from shard
      final shardIri = await _findShardForResource(documentIri);
      final shardGraph = await _downloadFile(
        _resourceLocator.locate(shardIri).filePath,
        ifNoneMatch,
      );
      
      // Extract resource subgraph
      return _extractResourceGraph(shardGraph, documentIri);
    }
  }
}
```

**Upload follows same pattern:** Modified resources trigger shard rebuild + upload.

### 5. Resource Extraction & Shard Building

**Core Operations:**

**A) Extract Resource from Shard:**
```dart
RdfGraph? _extractResourceFromShard(RdfGraph shardGraph, IriTerm resourceDocumentIri) {
  // Shard contains multiple managed documents:
  // - Each has sync:foafPrimaryTopic pointing to resource IRI
  // - Each has complete CRDT metadata (clocks, tombstones, etc.)
  
  final resourceIri = shardGraph.getSingleObject<IriTerm>(
    resourceDocumentIri, 
    SyncManagedDocument.foafPrimaryTopic,
  );
  
  if (resourceIri == null) {
    return null; // Resource not in shard
  }
  
  // Extract all triples related to this managed document
  final extractedTriples = <Triple>{};
  
  // 1. Document metadata (sync:ManagedDocument)
  extractedTriples.addAll(
    shardGraph.getTriplesForSubject(resourceDocumentIri),
  );
  
  // 2. Resource data (application triples)
  extractedTriples.addAll(
    shardGraph.getTriplesForSubject(resourceIri),
  );
  
  // 3. CRDT clock metadata (algo:HybridLogicalClock)
  final clockIri = shardGraph.getSingleObject<IriTerm>(
    resourceDocumentIri,
    SyncManagedDocument.crdtClock,
  );
  if (clockIri != null) {
    extractedTriples.addAll(
      shardGraph.getTriplesForSubject(clockIri),
    );
  }
  
  // 4. Installation metadata
  final installationIri = shardGraph.getSingleObject<IriTerm>(
    resourceDocumentIri,
    SyncManagedDocument.crdtCreatedByInstallation,
  );
  if (installationIri != null) {
    extractedTriples.addAll(
      shardGraph.getTriplesForSubject(installationIri),
    );
  }
  
  return RdfGraph(extractedTriples);
}
```

**B) Build Shard from Local Resources:**
```dart
Future<RdfGraph> _buildShardGraph(IriTerm shardIri) async {
  // 1. Get all resources belonging to this shard from DB
  final entries = await _storage.getActiveIndexEntriesForShard(shardIri);
  
  if (entries.isEmpty) {
    // Empty shard - just return shard document metadata
    return _emptyShardGraph(shardIri);
  }
  
  // 2. Load each resource document from local storage
  final resourceGraphs = await Future.wait(
    entries.map((entry) async {
      final doc = await _storage.getDocument(entry.resourceIri.getDocumentIri());
      return doc?.document;
    }),
  );
  
  // 3. Merge all resource graphs into single shard graph
  final allTriples = <Triple>{};
  
  // Add shard metadata (idx:Shard declaration)
  allTriples.add(Triple(shardIri, Rdf.type, IdxShard.classIri));
  
  // Add index entry metadata (idx:containsEntry)
  for (final entry in entries) {
    final entryIri = entry.entryIri;
    allTriples.addAll([
      Triple(shardIri, IdxShard.containsEntry, entryIri),
      Triple(entryIri, Rdf.type, IdxShardEntry.classIri),
      Triple(entryIri, IdxShardEntry.resource, entry.resourceIri),
      Triple(entryIri, IdxShardEntry.crdtClockHash, 
        LiteralTerm(entry.clockHash, datatype: Xsd.string)),
    ]);
  }
  
  // Add all resource documents
  for (final graph in resourceGraphs) {
    if (graph != null) {
      allTriples.addAll(graph.triples);
    }
  }
  
  return RdfGraph(allTriples);
}
```

**C) Key Observation from `ShardDocumentGenerator`:**

Looking at [`shard_document_generator.dart`](locorda_core/lib/src/sync/shard_document_generator.dart#L77-L143), we see this **already exists for local shard generation**:

```dart
Future<DocumentSaveResult?> _syncShardAttempt(...) async {
  // 1. Load all active entries for this shard from DB
  final entries = await _storage.getActiveIndexEntriesForShard(shardIri);
  
  // 2. Generate RDF graph for shard document from entries
  final newTriples = generateShardNodes(...).expand(...);
  
  // 3. Modify shard document via DocumentManager
  final saveResult = await _documentManager.modify(...);
}
```

**This is exactly what we need!** The logic for building shard graphs already exists - we just need to:
1. Use it for **remote** shard uploads (not just local storage)
2. Implement the reverse: **extract** resource from shard on download

### 6. Migration Strategy

**Phase 1: Add Shard File Support (Backward Compatible)**


**Phase 1: Add Shard File Support (Backward Compatible)**

Add configuration flag to enable/disable physical shard files:
```dart
class RemoteSyncConfig {
  final bool usePhysicalShardFiles;
  
  const RemoteSyncConfig({
    this.usePhysicalShardFiles = false, // Default: old behavior
  });
}
```

Implement dual-mode `RemoteSyncStorage`:
```dart
class GDriveSyncStorage implements RemoteSyncStorage {
  final bool _usePhysicalShardFiles;
  
  @override
  Future<DownloadResult?> download(IriTerm documentIri, {String? ifNoneMatch}) async {
    if (_usePhysicalShardFiles) {
      return _downloadFromShardFile(documentIri, ifNoneMatch);
    } else {
      return _downloadIndividualFile(documentIri, ifNoneMatch);
    }
  }
}
```

**Phase 2: Dual-Read Migration Path**

Support reading from **both** old (folder) and new (file) shard structures:
```dart
Future<DownloadResult?> _downloadFromShardFile(IriTerm documentIri, ...) async {
  final resourceLocator = _resourceLocator.locate(documentIri);
  
  // Try new shard file first
  final shardFilePath = _getShardFilePath(resourceLocator);
  final shardResult = await _client.downloadFile(shardFilePath, ifNoneMatch);
  
  if (shardResult != null) {
    // New format exists - extract resource
    return _extractResourceGraph(shardResult, documentIri);
  }
  
  // Fallback to old individual file
  final oldPath = _getIndividualFilePath(resourceLocator);
  return await _client.downloadFile(oldPath, ifNoneMatch);
}
```

**Phase 3: Background Migration Tool**

```dart
class ShardFileMigrator {
  Future<void> migrateRemoteToShardFiles() async {
    for (final typeIri in _registeredTypes) {
      final indices = await _storage.getIndicesForType(typeIri);
      
      for (final indexIri in indices) {
        final shards = await _storage.getShardsForIndex(indexIri);
        
        for (final shardIri in shards) {
          await _migrateShardToFile(shardIri);
        }
      }
    }
  }
  
  Future<void> _migrateShardToFile(IriTerm shardIri) async {
    // 1. Download all individual resource files
    final entries = await _storage.getActiveIndexEntriesForShard(shardIri);
    final resourceGraphs = <RdfGraph>[];
    
    for (final entry in entries) {
      final docIri = entry.resourceIri.getDocumentIri();
      final result = await _remoteSyncStorage.download(docIri);
      if (result != null) {
        resourceGraphs.add(result.graph);
      }
    }
    
    // 2. Build merged shard graph
    final shardGraph = await _buildShardGraph(shardIri);
    
    // 3. Upload as single shard file
    final shardDocIri = shardIri.getDocumentIri();
    await _remoteSyncStorage.upload(shardDocIri, shardGraph);
    
    // 4. Delete old individual files (after successful upload)
    for (final entry in entries) {
      await _client.deleteFile(
        _getIndividualFilePath(entry.resourceIri.getDocumentIri()),
      );
    }
    
    _log.info('Migrated shard ${shardIri.debug} to file format '
        '(${entries.length} resources)');
  }
}
```

**Phase 4: Cleanup & Default Change**

After migration complete:
1. Remove fallback logic (only read shard files)
2. Change default: `usePhysicalShardFiles = true`
3. Eventually deprecate individual file support

### 7. Conflict Resolution

### 7. Conflict Resolution & CRDT Semantics

**Key Insight:** Shard-level conflicts are **naturally handled by existing CRDT merge logic**!

**Scenario:** Two installations modify different resources in same shard concurrently.

**Resolution Flow:**
```dart
// Installation A modifies note-1, Installation B modifies note-2
// Both belong to shard-mod-md5-1-0

// Installation A:
1. Downloads shard-mod-md5-1-0.ttl (contains note-1, note-2)
2. Extracts note-1, merges local changes
3. Rebuilds shard: { note-1 (modified), note-2 (unchanged) }
4. Uploads with ETag check

// Installation B (concurrent):
1. Downloads shard-mod-md5-1-0.ttl (same ETag)
2. Extracts note-2, merges local changes
3. Rebuilds shard: { note-1 (unchanged), note-2 (modified) }
4. Uploads with ETag check → 412 CONFLICT!

// B's retry:
5. Re-downloads shard (now contains A's note-1 changes)
6. Extracts note-2, merges local changes (note-1 preserved from remote)
7. Rebuilds shard: { note-1 (from A), note-2 (from B) }
8. Uploads with new ETag → SUCCESS
```

**Critical Properties:**
- ✅ **CRDT merge semantics preserved**: Resource-level merge unchanged
- ✅ **No data loss**: Concurrent edits to different resources compose
- ✅ **Optimistic locking**: ETags prevent lost updates
- ✅ **Automatic retry**: `retryOnConflict()` in orchestrator handles 412
- ⚠️ **Increased retry likelihood**: Larger shard = more conflict opportunities

**Shard-Level Atomicity:**
```dart
Future<void> _uploadShardWithConflictHandling(
  IriTerm shardIri,
  {int maxRetries = 3}
) async {
  String? currentETag = await _storage.getRemoteETag(_remoteId, shardIri);
  
  for (var attempt = 0; attempt < maxRetries; attempt++) {
    // 1. Download current shard state
    final remoteResult = await _remoteSyncStorage.download(
      shardIri.getDocumentIri(),
      ifNoneMatch: currentETag,
    );
    
    if (remoteResult == null) {
      // Not modified - skip
      return;
    }
    
    // 2. Merge remote changes into local state
    for (final entry in _extractEntries(remoteResult.graph)) {
      await _mergeResource(entry);
    }
    
    // 3. Rebuild shard from updated local state
    final localShardGraph = await _buildShardGraph(shardIri);
    
    // 4. Upload with ETag check
    final uploadResult = await _remoteSyncStorage.upload(
      shardIri.getDocumentIri(),
      localShardGraph,
      ifMatch: remoteResult.etag,
    );
    
    if (uploadResult is SuccessUploadResult) {
      await _storage.setRemoteETag(_remoteId, shardIri, uploadResult.etag);
      return;
    }
    
    // Conflict - retry with fresh download
    currentETag = null; // Force fresh download
  }
  
  throw StateError('Shard upload failed after $maxRetries retries');
}
```

**Comparison to File-Per-Entity:**
- **Before**: Each resource = separate ETag → no cross-resource conflicts
- **After**: Shard = single ETag → conflicts span resources in shard
- **Impact**: More 412 responses, but CRDT merge ensures eventual consistency

## Backend-Specific Considerations

### GDrive
**Compatibility:**
- ✅ **ETag support**: md5Checksum for optimistic locking
- ✅ **Atomic operations**: Single file upload = atomic update
- ✅ **Existing mirror**: Works seamlessly (fewer files to mirror)
- ✅ **Gzip compression**: Already enabled, helps with larger files

**Performance Impact:**
- **Current**: 22 files × 200ms = ~4.4s (parallelized to ~5s actual)
- **With shard files**: 3-5 files × 200ms = ~0.6-1.0s (parallelized)
- **Expected speedup**: ~4-5x for initial sync
- **Trade-off**: Larger file payloads (but compressed, HTTP/2 handles well)

**Implementation Notes:**
```dart
class GDriveSyncStorage implements RemoteSyncStorage {
  final GDriveClient _client;
  final bool _usePhysicalShardFiles;
  
  @override
  Future<DownloadResult?> download(IriTerm documentIri, ...) async {
    if (_usePhysicalShardFiles) {
      // Determine shard for resource, download shard file, extract
      return _downloadFromShardFile(documentIri, ifNoneMatch);
    }
    
    // Legacy: individual file per resource
    return _downloadIndividualFile(documentIri, ifNoneMatch);
  }
}
```

### Solid Pod
**Compatibility:**
- ✅ **LDP compliance**: Shard files are valid LDP resources
- ✅ **ETag support**: Standard HTTP ETags
- ✅ **SPARQL queries**: Work on larger graphs (may be slower)
- ⚠️ **Container structure**: Need to decide folder vs direct file placement

**LDP Considerations:**
```
Current (LDP-compatible):
  /notes/
    index-full-123/         # LDP Container
      shard-mod-md5-1-0/    # LDP Container (folder)
        note-uuid-1.ttl     # LDP Resource
        note-uuid-2.ttl
        
Proposed (still LDP-compatible):
  /notes/
    index-full-123/               # LDP Container
      shard-mod-md5-1-0.ttl       # LDP Resource (file)
```

**Key:** Solid doesn't care about file granularity - LDP spec is content-agnostic.

**SPARQL Impact:**
- **Before**: Queries across multiple small files (federated)
- **After**: Queries on fewer larger files
- **Impact**: Likely neutral (SPARQL engines optimize internally)

### Local Directory
**Compatibility:**
- ✅ **Already fast**: No network latency
- ✅ **Consistent structure**: Same file layout across backends
- ✅ **Development/testing**: Easier to inspect (fewer files)

**Benefit:**
- Minimal performance gain (already optimal)
- Structural consistency with remote backends
- Simplified debugging (fewer files to inspect)

## Performance Projections

### Current Baseline (File-Per-Entity)
```
Initial sync (22 resources, 168KB):
- Local Dir:  1.36s (no network)
- GDrive:     ~5.0s (HTTP latency + mirror)
  
Breakdown per file:
- List operation:  ~50ms  (amortized, paginated)
- Download:       ~200ms  (latency to GDrive API)
- Deserialize:     ~10ms  (Turtle parsing)
```

### Projected with Physical Shards
```
Initial sync (3-5 shards, 168KB):
- Local Dir:  ~1.5s  (slightly slower: larger files to parse)
- GDrive:     ~1.5-2s (fewer HTTP requests!)

Breakdown per shard:
- List operation:  ~50ms  (fewer items to paginate)
- Download:       ~250ms  (latency + larger payload)
- Deserialize:     ~30ms  (larger Turtle document)

Speedup: 5s → 1.5-2s = 2.5-3.3x improvement
```

**Why Not Faster?**
- Still 3-5 HTTP roundtrips (can't eliminate entirely)
- Larger payloads offset some latency savings
- Geographic distance to API still dominates

**Compared to Theoretical Minimum:**
- Single aggregated file: ~1.2s (1 HTTP request)
- 3-5 shard files: ~1.5-2s (reasonable trade-off)
- Shard-based maintains CRDT correctness & scalability

## Implementation Phases

### Phase 1: Foundation (Weeks 1-2)
**Goal:** Add shard file support without breaking existing behavior

**Tasks:**
- [ ] Add `usePhysicalShardFiles` configuration flag
- [ ] Implement `_extractResourceFromShard()` in `RemoteSyncOrchestrator`
- [ ] Implement `_buildShardGraph()` (adapt from `ShardDocumentGenerator`)
- [ ] Update `GDriveSyncStorage.download()` with dual-mode logic
- [ ] Update `GDriveSyncStorage.upload()` for shard files

**Tests:**
- [ ] Extract resource from multi-resource shard graph
- [ ] Build shard graph from multiple local resources
- [ ] Dual-mode download (shard vs individual)
- [ ] Conflict resolution with concurrent shard updates

### Phase 2: Migration (Weeks 3-4)
**Goal:** Provide tool to migrate existing data to shard files

**Tasks:**
- [ ] Create `ShardFileMigrator` class
- [ ] Implement `migrateRemoteToShardFiles()` method
- [ ] Add dual-read fallback (try shard, fallback to individual)
- [ ] Add verification step (compare old vs new graphs)
- [ ] Create migration progress tracking

**Tests:**
- [ ] Migrate small dataset (5 resources → 1 shard)
- [ ] Migrate multi-shard dataset
- [ ] Verify data integrity after migration
- [ ] Test fallback to old format during transition

### Phase 3: Default Switch (Week 5)
**Goal:** Make shard files the default storage format

**Tasks:**
- [ ] Change `usePhysicalShardFiles` default to `true`
- [ ] Update documentation
- [ ] Performance benchmarking (before/after)
- [ ] Integration testing with example app

**Tests:**
- [ ] Full sync cycle with shard files
- [ ] Conflict resolution stress test
- [ ] Multi-installation collaboration test

### Phase 4: Cleanup (Week 6+)
**Goal:** Remove legacy individual file support

**Tasks:**
- [ ] Remove dual-mode logic (shard-only)
- [ ] Deprecate `usePhysicalShardFiles = false`
- [ ] Archive migration tools
- [ ] Performance documentation update

## Open Questions & Discussion Points

### 1. **Shard Granularity**
- **Current**: Shards determined by modulo hash (configurable)
- **Question**: Should shard size be configurable per-backend?
  - GDrive: Larger shards OK (fewer HTTP requests preferred)
  - Solid: Smaller shards? (SPARQL query performance?)
- **Proposal**: Keep existing shard determination logic unchanged (modulo hash)

### 2. **ResourceLocator Changes**
- **Current**: Maps document IRI → individual file path
- **Question**: How does it determine "is this a shard document" vs "resource document"?
- **Proposal**: 
  ```dart
  class ResourceLocation {
    final String filePath;      // Physical file path
    final bool isShardDocument; // true if this is shard, not resource
  }
  ```

### 3. **GDriveLocalMirror Integration**
- **Current**: Mirrors individual files
- **Question**: Does mirror logic need updates for shard files?
- **Answer**: Likely minimal - mirror treats files opaquely, just fewer files to track

### 4. **Index Document Handling**
- **Current**: Index documents (separate from shards) already work
- **Question**: Should indices also be aggregated?
- **Answer**: No - indices are already small, aggregation offers no benefit

### 5. **Deletion Semantics**
- **Current**: Delete resource → tombstone in individual file
- **With shards**: Delete resource → rebuild shard without that resource
- **Question**: How to handle empty shards after all resources deleted?
- **Proposal**: Keep empty shard file with idx:Shard metadata (explicit empty state)

### 6. **Solid-Specific Concerns**
- **Question**: Do Solid Pods have preferences for file vs folder organization?
- **Impact**: SPARQL query performance with larger files?
- **Action**: Need testing with real Solid Pods

### 7. **Backward Compatibility Timeline**
- **Question**: How long should dual-mode support persist?
- **Proposal**: 
  - 6 months: Dual-mode (read both formats)
  - Migration tool provided
  - Deprecation warnings for old format
  - Then: Remove legacy support

## Success Criteria

**Performance:**
- ✅ Initial sync time: 5s → <2s (GDrive, 22 resources)
- ✅ Fewer HTTP requests: 22 files → 3-5 shards
- ✅ Geographic latency still dominant (can't eliminate)

**Correctness:**
- ✅ CRDT semantics preserved (resource-level merge unchanged)
- ✅ Conflict resolution correct (optimistic locking via ETags)
- ✅ No data loss during migration
- ✅ All existing tests pass

**Compatibility:**
- ✅ Works with GDrive, Solid, Local Dir backends
- ✅ Migration path provided (no breaking changes)
- ✅ Dual-mode support during transition

**Developer Experience:**
- ✅ Configuration simple (`usePhysicalShardFiles = true`)
- ✅ Migration tool automated
- ✅ Clear documentation
- ✅ Example app updated

## References

### Existing Code
- [`RemoteSyncOrchestrator`](locorda_core/lib/src/sync/remote_sync_orchestrator.dart) - Hierarchical sync flow
- [`ShardDocumentGenerator`](locorda_core/lib/src/sync/shard_document_generator.dart) - Shard graph generation
- [`RemoteSyncStorage`](locorda_core/lib/src/storage/remote_storage.dart) - Storage interface
- [`GDriveSyncStorage`](locorda_gdrive/lib/src/gdrive_backend.dart) - GDrive implementation

### Related Proposals
- [011: Partial Foreign Shard Sync](011-partial-foreign-shard-sync.md) - Shard-level sync optimization
- [013: Sync Performance Analysis](013-sync-performance-analysis.md) - Initial performance investigation
- [014: GDrive Sync Performance Optimization](014-gdrive-sync-performance-optimization.md) - Current optimizations (local mirror, parallelism)

### Documentation
- [ARCHITECTURE.md](../spec/docs/ARCHITECTURE.md) - System overview (⚠️ outdated)
- [GROUP-INDEXING.md](../spec/docs/GROUP-INDEXING.md) - Shard indexing patterns
- Initial sync: ~5s
- Per-file overhead: ~200ms (HTTP roundtrip)

**Aggregated (3-5 files):**
- Initial sync: ~1.5-2s (projected)
- Reduction: 60-70% faster
- Tradeoff: Larger individual transfers (but compressed)

**Subsequent Syncs:**
- Changes API will dominate (both approaches)
- Aggregation less relevant for incremental updates

## Open Questions

### Q1: Shard Size Limits?
**Concern:** Single shard grows unbounded as entities increase.

**Options:**
- **A) Fixed shard size:** Split into `shard-0.ttl`, `shard-1.ttl`, etc. after N entities
- **B) Hash-based sharding:** Route entities by ID hash (deterministic)
- **C) Time-based sharding:** Shard by creation date

**Recommendation:** Start with single shard, monitor size, add splitting later if needed.

### Q2: Partial Download Optimization?
**Concern:** Download entire shard to read one document.

**Options:**
- **A) Accept tradeoff:** Bandwidth cheap, latency expensive
- **B) Use HTTP Range requests:** Download partial file (requires offset tracking)
- **C) Local mirror caching:** Already mitigates (cached after first sync)

**Recommendation:** Accept tradeoff initially, leverage local mirror.

### Q3: Cross-Backend Consistency?
**Concern:** GDrive uses shards, Solid uses file-per-entity.

**Options:**
- **A) Per-backend strategy:** Different backends can use different strategies
- **B) Unified strategy:** All backends use same approach (easier sync)
- **C) Hybrid mode:** Detect strategy from remote, adapt

**Recommendation:** Per-backend strategy with explicit configuration.

### Q4: Deletion Handling?
**Concern:** Deleting entity requires rewriting entire shard.

**Approach:**
```dart
Future<void> deleteDocument(IriTerm docIri) {
  final shardPath = strategy.getShardPath(docIri, typeIri);
  final current = await storage.downloadFile(shardPath);
  
  // Remove document from shard
  final updated = _removeDocument(current.graph, docIri);
  
  // Upload modified shard
  await storage.uploadFile(shardPath, updated, ifMatch: current.etag);
}
```

**Alternative:** Tombstone approach (mark deleted, periodic compaction).

## Implementation Plan

### Phase 1: Infrastructure (Week 1)
- [ ] Define `ShardingStrategy` interface
- [ ] Implement `FilePerEntityStrategy` (extract current logic)
- [ ] Implement `SingleShardStrategy`
- [ ] Add strategy selection to backend configs
- [ ] Unit tests for both strategies

### Phase 2: Core Integration (Week 2)
- [ ] Refactor `RemoteSyncStorage` to use strategy
- [ ] Implement document extraction from shard
- [ ] Implement shard merge operations
- [ ] Add conflict retry logic
- [ ] Integration tests (GDrive, Local)

### Phase 3: Migration & Compatibility (Week 3)
- [ ] Implement fallback read logic (both strategies)
- [ ] Add migration utility (file-per-entity → shard)
- [ ] Solid backend validation
- [ ] Performance benchmarks
- [ ] Documentation

### Phase 4: Production Rollout (Week 4)
- [ ] Feature flag for strategy selection
- [ ] Monitor performance metrics
- [ ] Gradual rollout to users
- [ ] Feedback collection

## Alternatives Considered

### Alternative 1: Multi-Document Batching API
**Idea:** Extend Drive/Solid APIs to support batch operations.

**Pros:**
- Keep file-per-entity isolation
- Reduce roundtrips via batching

**Cons:**
- Google Drive Batch API deprecated/removed
- Solid has no batch standard
- API-specific implementation

**Verdict:** Not viable (no API support).

### Alternative 2: Local Mirror Only
**Idea:** Keep remote granular, optimize via local caching.

**Pros:**
- No remote structure change
- Works for subsequent syncs

**Cons:**
- Initial sync still slow (no cached data yet)
- Doesn't solve cold-start problem

**Verdict:** Already implemented, not sufficient alone.

### Alternative 3: Compression + HTTP/2
**Idea:** Rely on gzip + HTTP/2 multiplexing.

**Pros:**
- No code changes
- Standard web optimizations

**Cons:**
- Already using gzip (minimal impact)
- HTTP/2 helps but doesn't eliminate latency
- Tested: Only ~0.5s improvement

**Verdict:** Insufficient for target performance.

## Success Criteria

- [ ] Initial sync time: < 2s (from ~5s)
- [ ] No regressions in Solid backend performance
- [ ] CRDT merge correctness maintained
- [ ] Backward compatible migration path
- [ ] No data loss during migration

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Concurrent shard writes cause conflicts | Medium | Optimistic locking + retry logic |
| Large shards slow down sync | Low | Monitor size, add splitting if needed |
| Migration corrupts data | High | Thorough testing, rollback mechanism |
| Solid incompatibility | Medium | Extensive testing, feature flag |
| CRDT semantics violated | High | Formal verification, property tests |

## Related Work

- `001-framework-app-data-separation.md`: Data isolation patterns
- `013-sync-performance-analysis.md`: Performance profiling
- `014-gdrive-sync-performance-optimization.md`: Local mirror implementation
- Git packfiles: Inspiration for aggregation strategy

---

**Next Steps:**
1. Review & discuss this proposal
2. Prototype `ShardingStrategy` interface
3. Implement basic shard operations
4. Benchmark against current approach
5. Refine based on results
