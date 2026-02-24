# Partial Foreign Shard Sync

## Current Implementation Status

We currently sync only configured/subscribed indices and their complete shard sets.
This approach is insufficient - we also need partial sync for foreign indices.

## 1. Foreign Index Sync Requirements

Items may belong to multiple indices (configured + foreign).

We must sync shards from foreign indices when:
- They contain items we modified locally (dirty entries need upload)
- They contain items present in our local DB not yet covered by any synced shard

## 2. Partial Index Sync Strategy

For foreign indices (not explicitly configured/subscribed):

### a) Index Metadata Discovery ✅ IMPLEMENTED

- Index documents obtained via index-of-indices with filtered prefetch
- Enables shard-to-index association for items

### b) Selective Shard Sync ⚠️ TODO - NOT IMPLEMENTED

Sync only shards containing specific items from our index items table.

**Shard selection criteria:**
- Shards with dirty entries (local changes need upload)
- Shards with entries present in local DB not yet covered by any synced shard

**Important:** Among multiple foreign indices containing same item, syncing one shard is sufficient (avoid redundant syncs)

## 3. Implementation Requirements

### a) Query Strategy
Query index items table for all referenced shards (not just configured indices)

### b) Sync Modes
Distinguish sync modes per index:

- **Full sync:** All shards, with `RootResourceFetchPolicy` (download new remote items)
- **Partial sync:** Selected shards only, no `RootResourceFetchPolicy` (upload-only for known items)

### c) Coverage Tracking
Track which items are already covered by synced shards to avoid redundant syncs

## 4. Data Model Extension

**Current representation:**
```dart
(IriTerm indexIri, RootResourceFetchPolicy fetchPolicy)
```
This implies full shard sync.

**Proposed design:**
```dart
/// Represents the synchronization mode for an index
sealed class IndexSyncMode {
  /// The IRI of the index to sync
  final IriTerm indexIri;
  
  const IndexSyncMode(this.indexIri);
}

/// Full index sync: Download all shards and apply fetch policy for new items
final class FullIndexSync extends IndexSyncMode {
  /// Policy determining which items to download from remote
  final RootResourceFetchPolicy fetchPolicy;
  
  const FullIndexSync({
    required super.indexIri,
    required this.fetchPolicy,
  });
}

/// Partial index sync: Upload-only for specific shards containing known items
final class PartialIndexSync extends IndexSyncMode {
  /// Map of shard IRIs to the set of resource IRIs we need to sync in that shard
  /// Only these specific items will be synced (upload local changes, no remote downloads)
  final Map<IriTerm /*shardIri*/, Set<IriTerm /*resourceIri*/>> shardItems;
  
  const PartialIndexSync({
    required super.indexIri,
    required this.shardItems,
  });
}
```

**Rationale:**

1. **Index IRI included**: Each sync mode knows which index it refers to
2. **Shard-to-items mapping**: `PartialIndexSync` uses `Map<IriTerm, Set<IriTerm>>` because:
   - We need to know which shards to sync (map keys)
   - For each shard, which specific items need syncing (map values)
   - This enables efficient shard-level sync decisions
3. **Sealed class hierarchy**: Type-safe discrimination between full/partial modes
4. **Clear semantics**: 
   - `FullIndexSync`: "Sync all shards, download new items per policy"
   - `PartialIndexSync`: "Sync only these shards, only for these items, upload-only"
  