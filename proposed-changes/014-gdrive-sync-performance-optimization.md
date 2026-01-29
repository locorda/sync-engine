# Google Drive Sync Performance Optimization

**Status**: Draft  
**Created**: 2026-01-29  
**Problem**: Current implementation performs many sequential file operations, resulting in poor sync performance compared to Solid backend

## 1. Google Drive API Capabilities

### 1.1 Batch Operations
**API**: `batch` endpoint allows combining up to 100 requests
- Multiple GET/POST/PATCH/DELETE in single HTTP request
- Reduces network round-trips from N to ⌈N/100⌉
- Returns multipart response with individual results
- **Limitation**: Each sub-request processed sequentially server-side
- **Use case**: Download/upload multiple small files (shards, indices)

**Implementation requirement**:
- Build batch request body with MIME multipart format
- Parse multipart response, extract individual results
- Handle partial failures (some succeed, some fail)

### 1.2 Changes API
**API**: `changes.list` tracks all file modifications via change tokens
- Returns delta of changes since last sync (created/modified/deleted)
- Eliminates need to check each file individually
- Provides `newStartPageToken` for next sync cycle
- Supports `includeItemsFromAllDrives` and field filtering

**Workflow**:
1. Initial sync: Get `startPageToken` via `changes.getStartPageToken()`
2. Store token locally (per remote)
3. Next sync: `changes.list(pageToken=lastToken)` → only changed files
4. Update local token to `newStartPageToken`

**Benefits**:
- O(changes) instead of O(total_files)
- Server-side filtering by file types/folders
- Automatic deleted file detection

**Limitation**: 
- Requires folder/file ID tracking (not path-based)
- May need initial full scan to populate ID mapping

### 1.3 File Metadata Queries
**API**: `files.list` with `q` parameter and field projection
- Single request returns metadata for all matching files
- Supports complex queries: `'folderId' in parents and modifiedTime > '...'`
- Field selection via `fields` parameter reduces payload size
- Returns `nextPageToken` for pagination (1000 items per page)

**Use case**: 
- List all shards in index folder with ETags
- Check for modifications without downloading content
- Build sync queue efficiently

### 1.4 Partial Update (PATCH)
**API**: `files.update` with `uploadMedia` but limited metadata changes
- Updates file content atomically
- Can update properties in same request
- **Not useful for us**: We need full document replacement (RDF graphs)

### 1.5 Multipart Upload
**API**: `files.create` and `files.update` support multipart uploads
- Single request: metadata + content
- Already used in our implementation
- **Already optimal** for single-file operations

### 1.6 Export/Import Formats
**API**: Convert between Google Workspace formats
- **Not applicable**: We use text/turtle RDF, not Google Docs

## 2. Locorda Sync Architecture Characteristics

### 2.1 Document Structure
- **Framework documents**: Wrap application data with metadata (clock, installation, shards)
- **Immutable**: Once written, documents rarely modified (append-only CRDT)
- **Small size**: Typically < 10 KB per document

### 2.2 Index System
- **FullIndex**: Single index listing all resources of a type
- **GroupIndex**: Partitioned indices (e.g., monthly groups)
- **Index entries**: Point to shards containing actual data
- **Metadata-heavy**: Indices contain headers (IRI, clock, properties) but not full documents

### 2.3 Shard System
- **Shard documents**: Aggregates of multiple resource entries
- **Dynamic composition**: Shard content determined by index configuration
- **Conditional sync**: Only upload if changed (ETag-based)
- **Sparse updates**: Not all shards change in every sync cycle

### 2.4 Sync Algorithm (Phase 0 + A + B)
**Phase 0: Preparation**
- Materialize local shard state (DB → in-memory RDF)
- No network operations

**Phase A: Metadata Reconciliation**
- For each index: GET index document (conditional with ETag)
- CRDT merge if changed
- PUT updated index back (conditional with If-Match)
- Build document sync queue from shard diffs

**Phase B: Document Finalization**
- For each queued shard: GET document (conditional)
- CRDT merge application data
- PUT merged document (conditional)

### 2.5 Backend Abstraction
- **RemoteStorage interface**: Common abstraction for Solid and GDrive
- **Operations**: `download(iri, etag?)`, `upload(iri, graph, etag?)`
- **Document-centric**: Each operation targets single IRI
- **Stateless**: Each sync creates new `RemoteSyncStorage` session

### 2.6 Concurrency Control
- **ETag-based optimistic locking**: Prevent lost updates via If-Match
- **412 Precondition Failed**: Triggers retry loop with fresh GET
- **Atomic operations**: Each document update is isolated

### 2.7 Current GDrive Mapping
- **Type Index document** (`gdrive-index.ttl`): Maps resource types to folder IDs
- **Folder hierarchy**: One folder per resource type
- **File naming**: Path-based (matches Solid IRI structure)
- **Sequential operations**: Each `download()`/`upload()` = separate HTTP request

## 3. Optimization Proposals

### 3.1 Strategy Overview
**Goal**: Reduce network round-trips while maintaining:
- Solid backend compatibility (no breaking changes to core sync algorithm)
- ETag-based concurrency control
- Document-level abstraction in `RemoteStorage` interface

**Approach**: Introduce **batching layer** in GDrive backend without modifying core sync logic

### 3.2 Proposal A: Batch Download/Upload (Conservative)

#### 3.2.1 Architecture
```
┌─────────────────────────────────────┐
│ RemoteSyncOrchestrator              │
│ (unchanged - sequential calls)      │
└────────┬────────────────────────────┘
         │ download(iri1)
         │ download(iri2)
         │ upload(iri3)
         ↓
┌─────────────────────────────────────┐
│ GDriveSyncStorage                   │
│ + RequestBatcher (new)              │
│                                     │
│ • Collects requests in queue        │
│ • Flushes when: batch full OR       │
│   explicit flush() OR timeout       │
│ • Maps responses back to callers    │
└────────┬────────────────────────────┘
         │ Batch API (100 requests)
         ↓
┌─────────────────────────────────────┐
│ Google Drive API                    │
└─────────────────────────────────────┘
```

#### 3.2.2 Implementation Details
**New class**: `GDriveBatchingSyncStorage implements RemoteSyncStorage`

**State**:
```dart
class GDriveBatchingSyncStorage {
  final List<_PendingRequest> _downloadQueue = [];
  final List<_PendingRequest> _uploadQueue = [];
  final GDriveClient _client;
  
  static const _maxBatchSize = 100;
  static const _flushTimeout = Duration(milliseconds: 50);
}
```

**Operation flow**:
1. `download(iri)` called → add to `_downloadQueue`, return `Future<Result>`
2. Queue reaches 100 OR timeout → flush batch via `_executeBatch()`
3. Parse batch response, complete individual `Future`s
4. `upload()` similar logic with separate queue

**Explicit flush points**:
- After each index sync (before moving to shards)
- At end of Phase A (before Phase B)
- In `finalizeSync()`

**Benefits**:
- 10-20x reduction in HTTP requests for typical sync (50+ files)
- Maintains exact same sync semantics
- Zero changes to core sync algorithm
- Fallback to sequential if batch fails

**Challenges**:
- Async batching complexity (queue management)
- Error handling (partial failures in batch)
- Timeout tuning (balance latency vs batch size)

#### 3.2.3 Solid Compatibility
- Solid backend keeps current implementation
- No interface changes needed
- Optional `flush()` method on `RemoteSyncStorage` (no-op for Solid)

### 3.3 Proposal B: Changes API + Incremental Sync (Aggressive)

#### 3.3.1 Architecture
**New sync mode**: Incremental sync powered by `changes.list`

**First sync** (full):
- Standard Phase 0 + A + B
- Store Drive `pageToken` in local DB
- Map all file IDs to IRIs

**Subsequent syncs** (incremental):
- Call `changes.list(pageToken=lastToken)` → changed file IDs
- Map file IDs to IRIs
- Only sync changed documents (skip unchanged)
- Update `pageToken`

#### 3.3.2 Implementation
**New storage table**: `gdrive_file_mapping`
```sql
CREATE TABLE gdrive_file_mapping (
  document_iri TEXT PRIMARY KEY,
  drive_file_id TEXT NOT NULL,
  remote_id TEXT NOT NULL,
  FOREIGN KEY (remote_id) REFERENCES remote_sync_state(id)
);

CREATE TABLE gdrive_page_token (
  remote_id TEXT PRIMARY KEY,
  page_token TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
```

**Modified sync flow**:
```dart
class GDriveIncrementalSyncStorage {
  Future<Set<IriTerm>> getChangedDocuments() async {
    final token = await _storage.getGDrivePageToken(remoteId);
    if (token == null) {
      // First sync - return null to trigger full sync
      return null;
    }
    
    final changes = await _driveApi.changes.list(
      pageToken: token,
      spaces: 'drive',
      fields: 'newStartPageToken, changes(fileId, removed)',
    );
    
    // Map file IDs to IRIs
    final changedIris = <IriTerm>{};
    for (final change in changes.changes) {
      final iri = await _storage.getIriForFileId(change.fileId);
      if (iri != null) changedIris.add(iri);
    }
    
    // Store new token
    await _storage.updateGDrivePageToken(
      remoteId, 
      changes.newStartPageToken,
    );
    
    return changedIris;
  }
}
```

**Core sync integration**:
- Add optional `getChangedDocuments()` to `RemoteSyncStorage`
- `RemoteSyncOrchestrator` checks for changed set
- If present: only sync those documents
- If absent: full sync (Solid behavior)

#### 3.3.3 Benefits
- O(changes) complexity instead of O(total_files)
- Near-instant sync when no changes (single API call)
- Automatic deleted file detection
- Scales well with large datasets

#### 3.3.4 Challenges
- Requires file ID tracking (adds storage complexity)
- Initial sync overhead (populate mapping table)
- Drive API limitations (tokens expire after ~7 days of inactivity)
- Deleted file handling (must clean up mapping table)
- Multi-device scenario (file created on device B, synced to A)

#### 3.3.5 Solid Compatibility
- Solid backend returns `null` from `getChangedDocuments()` → full sync
- Optional feature (no breaking changes)

### 3.4 Proposal C: Hybrid Approach (Recommended)

#### 3.4.1 Combine A + B for Maximum Benefit
1. **Use Changes API** when available (Proposal B)
   - Reduces scope of sync to changed documents
   
2. **Apply batching** to remaining operations (Proposal A)
   - Downloads/uploads for changed documents batched

#### 3.4.2 Implementation Phases
**Phase 1: Batching (Proposal A)**
- Immediate performance win with low complexity
- Foundation for future optimizations
- Estimated: 10-20x speedup on typical syncs

**Phase 2: Changes API (Proposal B)**
- Requires more design work (storage schema)
- Adds incremental sync capability
- Estimated: Additional 5-10x speedup for "no changes" case

**Phase 3: Metadata-only queries**
- Use `files.list` to fetch all ETags in single request
- Skip downloads for documents with matching ETags
- Estimated: 2-3x speedup when many docs unchanged

#### 3.4.3 Migration Path
1. Implement `GDriveBatchingSyncStorage` (no DB changes)
2. Test thoroughly with existing app
3. Add `gdrive_file_mapping` table (migration)
4. Implement `GDriveIncrementalSyncStorage`
5. Add feature flag to toggle batching/incremental modes
6. Monitor performance metrics, tune batch sizes

### 3.5 Alternative: Compress Folder Structure

#### 3.5.1 Current Structure
```
/locorda/
  /<resource-type-1>/
    /shard-1.ttl
    /shard-2.ttl
  /<resource-type-2>/
    /shard-3.ttl
```

**Problem**: Many small files → many HTTP requests

#### 3.5.2 Proposed: Bundle Format
```
/locorda/
  /<resource-type-1>.bundle
  /<resource-type-2>.bundle
```

**Bundle format**: Concatenated Turtle with delimiters
```turtle
# Document: https://example.org/shard-1
# ETag: abc123
# ---
@prefix schema: <http://schema.org/> .
...

# Document: https://example.org/shard-2
# ETag: def456
# ---
@prefix schema: <http://schema.org/> .
...
```

**Benefits**:
- Single file per resource type
- One download gets all shards
- Still text-based (diffable, inspectable)

**Challenges**:
- Breaks ETag-based concurrency (entire bundle has one ETag)
- Lost: per-document conflict detection
- Complex: partial updates require rewriting entire bundle
- **Incompatible with Solid** (would require parallel storage formats)

**Verdict**: ❌ Not recommended - violates document-level semantics

## 4. Recommendation

**Implement Proposal C (Hybrid Approach) in two phases**:

### Phase 1: Batching Layer (Immediate - Est. 1-2 weeks)
- Implement `GDriveBatchingSyncStorage` with `RequestBatcher`
- Add explicit flush points in sync algorithm
- Expected speedup: **10-20x** for typical syncs with 20-100 files
- Risk: Low (no storage changes, fallback to sequential)

### Phase 2: Changes API Integration (Future - Est. 2-3 weeks)
- Add `gdrive_file_mapping` and `gdrive_page_token` tables
- Implement `getChangedDocuments()` in GDrive backend
- Optional feature behind configuration flag
- Expected additional speedup: **5-10x** for no-change syncs
- Risk: Medium (requires storage migration, token management)

### Why This Approach?
1. **Incremental delivery**: Get immediate performance wins, refine later
2. **Solid compatibility**: No changes to core sync algorithm or interfaces
3. **Risk mitigation**: Phase 1 low-risk, Phase 2 builds on proven foundation
4. **Resource allocation**: Can stop after Phase 1 if performance acceptable

## 5. Open Questions

1. **Batch error handling**: If 1 of 100 requests fails, retry entire batch or just failed item?
2. **Timeout tuning**: What's optimal flush delay? (needs benchmarking)
3. **Changes API reliability**: How often do tokens expire? What's recovery strategy?
4. **Multi-device handling**: Does Changes API detect files created by other devices? (Yes - need to verify)
5. **Drive quota**: Do batch requests count as 1 or N quota units? (N - but faster overall)

## 6. Future Enhancements (Post-Phase 2)

- **Parallel uploads**: Multiple concurrent PUT requests (careful: may hit rate limits)
- **Compression**: gzip Turtle content (Drive supports transparent encoding)
- **Prefetching**: Predictive download of likely-needed shards during idle time
- **Local caching**: Cache folder ID mappings to skip type index lookup
- **WebSocket streaming**: Monitor Drive changes in real-time (Drive doesn't support - would need polling)

## 7. Performance Baseline (To Measure)

Before implementing optimizations, establish metrics:
- [ ] Avg sync time with 10/50/100/500 files
- [ ] Network request count per sync
- [ ] Bandwidth consumed (request + response sizes)
- [ ] CPU time in serialization vs network wait
- [ ] Solid backend sync time for comparison

Measure again after each phase to validate improvements.
