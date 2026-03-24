# 002a: Pipeline Walkthrough — Concrete Example

This document traces a concrete, fictional sync scenario through all 7 pipeline stages, showing exactly **what** gets loaded **from where** (local DB, remote HTTP, mirror) at each step.

## Setup: The Index Hierarchy

```
IoI-Index (/alice/locorda/index-of-indices)
  └─ IoI-Shard (/alice/locorda/ioi-shard-0)
       ├─ entry: (NotesIndex, clockHash: "abc")
       └─ entry: (TagsIndex, clockHash: "def")
            │
            ├─ NotesIndex (/alice/locorda/notes/index)
            │    ├─ Data Shard A (/alice/locorda/notes/shard-0)
            │    │    ├─ entry: (note-1, clockHash: "n1a")
            │    │    ├─ entry: (note-2, clockHash: "n2a")
            │    │    └─ entry: (note-3, clockHash: "n3a")
            │    └─ Data Shard B (/alice/locorda/notes/shard-1)
            │         ├─ entry: (note-4, clockHash: "n4a")   ← NEW on remote
            │         └─ entry: (note-5, clockHash: "n5a")
            │
            └─ TagsIndex (/alice/locorda/tags/index)
                 └─ Data Shard C (/alice/locorda/tags/shard-0)
                      ├─ entry: (tag-1, clockHash: "t1a")
                      └─ entry: (tag-2, clockHash: "t2a")
```

## Changes Since Last Sync

| Item | What happened | Detail |
|------|--------------|--------|
| note-1 | Remote changed | clockHash remote: "n1b" (was "n1a") |
| note-2 | Local changed | `updatedAt > lastSyncTimestamp` |
| note-3 | Both changed | clockHash remote: "n3b"; local `updatedAt > lastSyncTimestamp` |
| note-4 | New on remote | Not in mirror, not in local DB |
| note-5 | Unchanged | clockHash same, local not updated |
| tag-1, tag-2 | Unchanged | No changes |
| NotesIndex | Unchanged | Same content (still lists shard-0, shard-1) |
| TagsIndex | Unchanged | Same content |
| IoI-Index | Unchanged | Same content |
| IoI-Shard | Unchanged | Same entries |
| Data Shard A | Changed | Because note-1, note-3 changed remotely |
| Data Shard B | Changed | Because note-4 is new |
| Data Shard C | Unchanged | No changes |

## Mirror State (from last sync)

The backend's mirror stores entries per shard from the previous sync:

```
Mirror for IoI-Shard-0:
  (NotesIndex, clockHash: "abc")
  (TagsIndex, clockHash: "def")

Mirror for Data Shard A:
  (note-1, clockHash: "n1a")
  (note-2, clockHash: "n2a")
  (note-3, clockHash: "n3a")

Mirror for Data Shard B:
  (note-5, clockHash: "n5a")
  ← note-4 not in mirror (didn't exist last sync)

Mirror for Data Shard C:
  (tag-1, clockHash: "t1a")
  (tag-2, clockHash: "t2a")
```

## Local DB State

```
Index Entries (active):
  Shard A: (note-1, "n1a"), (note-2, "n2a"), (note-3, "n3a")
  Shard B: (note-5, "n5a")
  Shard C: (tag-1, "t1a"), (tag-2, "t2a")

Documents: note-1..5, tag-1..2, NotesIndex, TagsIndex, IoI-Index (all as Jelly)

ETags (cached):
  IoI-Index:   etag-ioi-v1
  IoI-Shard-0: etag-ioi-s0-v1
  NotesIndex:  etag-ni-v1
  TagsIndex:   etag-ti-v1
  Shard A:     etag-sa-v1
  Shard B:     etag-sb-v1
  Shard C:     etag-sc-v1
  note-1..5:   etag-n1-v1..etag-n5-v1
  tag-1..2:    etag-t1-v1..etag-t2-v1
```

---

## Stage 1: Hierarchical Discovery

Discovery receives: `backend`, `db`
Discovery reads: ETags from local DB, does conditional GETs on remote.

### Level 0: IoI-Index

```
Step 1.0.1: READ local DB → cached ETag for IoI-Index = "etag-ioi-v1"
Step 1.0.2: GET /alice/locorda/index-of-indices
            If-None-Match: "etag-ioi-v1"
            → 304 Not Modified (IoI hasn't changed)

Step 1.0.3: EMIT DiscoveredDocument(iri: IoI-Index, remoteSource: null, type: ioI)
            (remoteSource is null because 304 — Diff will check for local changes)

Step 1.0.4: Since 304, we don't have fresh remote content to parse.
            QUERY index_shards table → SELECT shard_iri WHERE index_iri = IoI-Index
            → found: [IoI-Shard-0]
            (No remote-only IoI-Shards to union — 304 means remote structure unchanged)
```

**Output so far**: `[DiscoveredDocument(IoI-Index, null, ioI)]`

### Level 1: IoI-Shards

```
Step 1.1.1: READ local DB → cached ETag for IoI-Shard-0 = "etag-ioi-s0-v1"
Step 1.1.2: GET /alice/locorda/ioi-shard-0
            If-None-Match: "etag-ioi-s0-v1"
            → 304 Not Modified (IoI-Shard hasn't changed)

Step 1.1.3: EMIT ShardUnchanged(IoI-Shard-0)
            (Mirror has correct entries — Diff will use mirror for index-level comparison)

Step 1.1.4: EMIT DiscoveryBoundary(ShardComplete(IoI-Shard-0))
```

Now Discovery needs to know which Index IRIs to visit at Level 2. Sources:
```
Step 1.1.5: The IoI-Shard was 304, so we DON'T have fresh remote entries.
            But the mirror should store these entries.
            
            QUESTION: Does Discovery read the mirror here?
            Or does Discovery only use local DB index entries?
            
            Option A — Discovery reads mirror (via backend):
              READ mirror for IoI-Shard-0 → [(NotesIndex, "abc"), (TagsIndex, "def")]
              These are the known remote indices.
              
            Option B — Discovery reads local DB:
              READ local DB → known index document IRIs
              → [NotesIndex, TagsIndex]
              
            Either way, the result is the same set: {NotesIndex, TagsIndex}
            Union remote + local = {NotesIndex, TagsIndex}
```

```
Step 1.1.6: EMIT DiscoveryBoundary(LevelComplete(ioiShard))
```

**Output so far**: `[..., ShardUnchanged(IoI-Shard-0), Boundary(ShardComplete), Boundary(LevelComplete)]`

### Level 2: Indices (NotesIndex, TagsIndex)

These are the **resources** of the IoI-Shards — they are index documents that we sync as CRDT documents AND parse for data shard IRIs.

```
Step 1.2.1: READ local DB → cached ETag for NotesIndex = "etag-ni-v1"
Step 1.2.2: GET /alice/locorda/notes/index
            If-None-Match: "etag-ni-v1"
            → 304 Not Modified

Step 1.2.3: EMIT DiscoveredDocument(iri: NotesIndex, remoteSource: null, type: fullIndex)

Step 1.2.4: NotesIndex is 304 → QUERY index_shards table → SELECT shard_iri WHERE index_iri = NotesIndex
            → found: [Shard-A, Shard-B]

Step 1.2.5: READ local DB → cached ETag for TagsIndex = "etag-ti-v1"
Step 1.2.6: GET /alice/locorda/tags/index
            If-None-Match: "etag-ti-v1"
            → 304 Not Modified

Step 1.2.7: EMIT DiscoveredDocument(iri: TagsIndex, remoteSource: null, type: fullIndex)

Step 1.2.8: TagsIndex is 304 → QUERY index_shards table → SELECT shard_iri WHERE index_iri = TagsIndex
            → found: [Shard-C]
```

Data shard IRIs to visit: {Shard-A, Shard-B, Shard-C} (union remote + local, both same here)

```
Step 1.2.9: EMIT DiscoveryBoundary(LevelComplete(index))
```

### Level 3: Data Shards

```
Step 1.3.1: READ local DB → cached ETags for all data shards
            Shard-A: "etag-sa-v1", Shard-B: "etag-sb-v1", Shard-C: "etag-sc-v1"

--- Shard A ---
Step 1.3.2: GET /alice/locorda/notes/shard-0
            If-None-Match: "etag-sa-v1"
            → 200 OK (changed! note-1 and note-3 have new clockHashes)
            Body: shard document, ETag: "etag-sa-v2"

Step 1.3.3: PARSE shard document → extract entries:
            [(note-1, "n1b"), (note-2, "n2a"), (note-3, "n3b")]
            ^^^^^ remote clockHashes from the fresh shard download

Step 1.3.4: EMIT DiscoveredShardEntries(
              shardIri: Shard-A,
              entries: [(note-1, "n1b"), (note-2, "n2a"), (note-3, "n3b")],
              etag: "etag-sa-v2"
            )
Step 1.3.5: EMIT DiscoveryBoundary(ShardComplete(Shard-A))

--- Shard B ---
Step 1.3.6: GET /alice/locorda/notes/shard-1
            If-None-Match: "etag-sb-v1"
            → 200 OK (changed! note-4 is new)
            Body: shard document, ETag: "etag-sb-v2"

Step 1.3.7: PARSE shard document → extract entries:
            [(note-4, "n4a"), (note-5, "n5a")]

Step 1.3.8: EMIT DiscoveredShardEntries(
              shardIri: Shard-B,
              entries: [(note-4, "n4a"), (note-5, "n5a")],
              etag: "etag-sb-v2"
            )
Step 1.3.9: EMIT DiscoveryBoundary(ShardComplete(Shard-B))

--- Shard C ---
Step 1.3.10: GET /alice/locorda/tags/shard-0
             If-None-Match: "etag-sc-v1"
             → 304 Not Modified

Step 1.3.11: EMIT ShardUnchanged(Shard-C)
Step 1.3.12: EMIT DiscoveryBoundary(ShardComplete(Shard-C))

Step 1.3.13: EMIT DiscoveryBoundary(LevelComplete(shard))
```

### Complete Discovery Output Stream (in order)

```
 1. DiscoveredDocument(IoI-Index, null, ioI)              ← Level 0
 2. ShardUnchanged(IoI-Shard-0)                           ← Level 1
 3. Boundary(ShardComplete(IoI-Shard-0))
 4. Boundary(LevelComplete(ioiShard))
 5. DiscoveredDocument(NotesIndex, null, fullIndex)        ← Level 2
 6. DiscoveredDocument(TagsIndex, null, fullIndex)
 7. Boundary(LevelComplete(index))
 8. DiscoveredShardEntries(Shard-A, [...], "etag-sa-v2")  ← Level 3
 9. Boundary(ShardComplete(Shard-A))
10. DiscoveredShardEntries(Shard-B, [...], "etag-sb-v2")
11. Boundary(ShardComplete(Shard-B))
12. ShardUnchanged(Shard-C)
13. Boundary(ShardComplete(Shard-C))
14. Boundary(LevelComplete(shard))
```

### Discovery I/O Summary

| I/O Type | Count | What |
|----------|-------|------|
| Local DB read (ETags) | 7 | All hierarchy docs + shards |
| Remote conditional GET | 7 | IoI, IoI-Shard, 2 indices, 3 data shards |
| Remote 304 (no body) | 5 | IoI, IoI-Shard, NotesIndex, TagsIndex, Shard-C |
| Remote 200 (with body) | 2 | Shard-A, Shard-B |
| Local DB read (index_shards queries) | 3 | IoI-Index, NotesIndex, TagsIndex (shard IRI lookup after 304) |
| CPU (shard parsing) | 2 | Shard-A, Shard-B entry extraction |

---

## Stage 2: Diff Transform

Diff receives each Discovery event and produces DiffEvents by comparing against local state + mirror.

### Processing event 1: `DiscoveredDocument(IoI-Index, null, ioI)`

```
remoteSource is null → remote returned 304 (unchanged)
READ local DB → IoI-Index metadata → updatedAt
Is updatedAt > lastSyncTimestamp? → NO (IoI-Index not locally modified)
→ SKIP (both sides unchanged, nothing to do)
```

### Processing event 2: `ShardUnchanged(IoI-Shard-0)`

```
Shard returned 304 → mirror has correct entries.
No entries to diff right now — wait for ShardComplete boundary
to run remaining-items query.
(But since we have no remote entries to compare, we effectively
only look for local-only changes at the boundary.)
```

### Processing event 3: `Boundary(ShardComplete(IoI-Shard-0))`

```
Remaining-items query for IoI-Shard-0:
READ local DB → index entries in IoI-Shard-0 that are NOT in seen-set
                AND have updatedAt > lastSyncTimestamp
→ None found (no indices changed locally)
→ EMIT DiffBoundary(ShardComplete(IoI-Shard-0))
```

### Processing event 4: `Boundary(LevelComplete(ioiShard))`

→ Forward as `DiffBoundary(LevelComplete(ioiShard))`

### Processing event 5: `DiscoveredDocument(NotesIndex, null, fullIndex)`

```
remoteSource is null → remote returned 304
READ local DB → NotesIndex metadata → updatedAt
Is updatedAt > lastSyncTimestamp? → NO
→ SKIP
```

### Processing event 6: `DiscoveredDocument(TagsIndex, null, fullIndex)`

```
Same logic → SKIP (TagsIndex unchanged on both sides)
```

### Processing event 7: `Boundary(LevelComplete(index))`

→ Forward as `DiffBoundary(LevelComplete(index))`

### Processing event 8: `DiscoveredShardEntries(Shard-A, entries, "etag-sa-v2")`

This is where the interesting diffing happens. Diff uses a **three-way comparison**: remote entries (from Discovery), mirror entries (from backend), and local state (from DB).

```
Remote entries (from Discovery event):
  (note-1, clockHash: "n1b")
  (note-2, clockHash: "n2a")
  (note-3, clockHash: "n3b")

READ mirror (via backend) for Shard-A:
  (note-1, clockHash: "n1a")    ← what we last saw remotely
  (note-2, clockHash: "n2a")
  (note-3, clockHash: "n3a")

READ local DB → index entries for Shard-A:
  (note-1, clockHash: "n1a", updatedAt: old)
  (note-2, clockHash: "n2a", updatedAt: RECENT)  ← locally modified!
  (note-3, clockHash: "n3a", updatedAt: RECENT)  ← locally modified!

Per-entry comparison:

  note-1:
    remote clockHash "n1b" ≠ mirror clockHash "n1a" → REMOTE CHANGED
    local updatedAt ≤ lastSyncTimestamp → local NOT changed
    → ConflictCandidate(note-1)  [safe default: always merge when one side changed]
    (Optimization potential: if we verified remote clock subsumes local, 
     this could be RemoteOnlyCandidate)
    
  note-2:
    remote clockHash "n2a" = mirror clockHash "n2a" → remote NOT changed
    local updatedAt > lastSyncTimestamp → LOCAL CHANGED
    → ConflictCandidate(note-2)  [safe default]
    (Optimization potential: LocalOnlyCandidate if local clock subsumes remote)
    
  note-3:
    remote clockHash "n3b" ≠ mirror clockHash "n3a" → REMOTE CHANGED
    local updatedAt > lastSyncTimestamp → LOCAL CHANGED
    → ConflictCandidate(note-3)  [genuine conflict — both sides changed]

Add {note-1, note-2, note-3} to seen-set for Shard-A.

EMIT ConflictCandidate(note-1)
EMIT ConflictCandidate(note-2)
EMIT ConflictCandidate(note-3)
```

### Processing event 9: `Boundary(ShardComplete(Shard-A))`

```
Remaining-items query:
READ local DB → entries in Shard-A NOT in seen-set {note-1, note-2, note-3}
               AND updatedAt > lastSyncTimestamp
→ None (all 3 entries were in the remote shard)
→ EMIT DiffBoundary(ShardComplete(Shard-A))
Clear seen-set for Shard-A.
```

### Processing event 10: `DiscoveredShardEntries(Shard-B, entries, "etag-sb-v2")`

```
Remote entries:
  (note-4, clockHash: "n4a")
  (note-5, clockHash: "n5a")

READ mirror (via backend) for Shard-B:
  (note-5, clockHash: "n5a")
  ← note-4 NOT in mirror (didn't exist last sync)

READ local DB → index entries for Shard-B:
  (note-5, clockHash: "n5a", updatedAt: old)
  ← note-4 NOT in local DB

Per-entry comparison:

  note-4:
    NOT in mirror → remote is new
    NOT in local DB → no local version
    → RemoteOnlyCandidate(note-4)

  note-5:
    remote clockHash "n5a" = mirror clockHash "n5a" → remote NOT changed
    local updatedAt ≤ lastSyncTimestamp → local NOT changed
    → SKIP (both sides unchanged)

EMIT RemoteOnlyCandidate(note-4)
```

### Processing event 11: `Boundary(ShardComplete(Shard-B))`

```
Remaining-items query:
READ local DB → entries in Shard-B NOT in seen-set {note-4, note-5}
               AND updatedAt > lastSyncTimestamp
→ None
→ EMIT DiffBoundary(ShardComplete(Shard-B))
```

### Processing event 12: `ShardUnchanged(Shard-C)`

```
Shard-C returned 304. Mirror has correct entries.
No remote entries to compare — will only check for local-only at boundary.
```

### Processing event 13: `Boundary(ShardComplete(Shard-C))`

```
Remaining-items query:
READ local DB → entries in Shard-C AND updatedAt > lastSyncTimestamp
→ None (tag-1, tag-2 both unchanged)
→ EMIT DiffBoundary(ShardComplete(Shard-C))
```

### Processing event 14: `Boundary(LevelComplete(shard))`

→ Forward as `DiffBoundary`

### Complete Diff Output Stream

```
 1. DiffBoundary(ShardComplete(IoI-Shard-0))
 2. DiffBoundary(LevelComplete(ioiShard))
 3. DiffBoundary(LevelComplete(index))
 4. ConflictCandidate(note-1)                ← remote changed
 5. ConflictCandidate(note-2)                ← local changed
 6. ConflictCandidate(note-3)                ← both changed
 7. DiffBoundary(ShardComplete(Shard-A))
 8. RemoteOnlyCandidate(note-4)              ← new on remote
 9. DiffBoundary(ShardComplete(Shard-B))
10. DiffBoundary(ShardComplete(Shard-C))
11. DiffBoundary(LevelComplete(shard))
```

### Diff I/O Summary

| I/O Type | Count | What |
|----------|-------|------|
| Local DB read (document metadata) | 3 | IoI-Index, NotesIndex, TagsIndex updatedAt check |
| Mirror read (via backend) | 2 | Shard-A entries, Shard-B entries |
| Local DB read (index entries) | 2 | Shard-A entries, Shard-B entries |
| Local DB read (remaining-items) | 4 | IoI-Shard-0, Shard-A, Shard-B, Shard-C boundary queries |
| Remote I/O | 0 | None — Diff is DB-only |

---

## Stage 3: Resource Fetch

Fetch loads content for each sync candidate. Boundaries pass through.

```
ConflictCandidate(note-1):
  REMOTE: GET /alice/locorda/notes/note-1  (If-None-Match: etag-n1-v1)
          → 200 OK, body: Turtle/Jelly bytes, ETag: "etag-n1-v2"
  LOCAL:  READ local DB → note-1 document (Jelly bytes)
  EMIT FetchedResource(note-1, remote: BinaryGraphSource, local: BinaryGraphSource)

ConflictCandidate(note-2):
  REMOTE: GET /alice/locorda/notes/note-2  (If-None-Match: etag-n2-v1)
          → 304 Not Modified (remote hasn't changed — only local changed)
          
  WAIT — this is a problem! Remote returned 304 but we classified it
  as ConflictCandidate. The Diff stage decided "always load both sides"
  but the remote didn't change. What happens?
  
  The remote returned 304, but Fetch NEEDS the content for CRDT merge.
  Two options:
  (a) Fetch must do an unconditional GET (no If-None-Match)
  (b) Fetch uses the cached ETag to detect 304, then loads from mirror/DB
  
  For the safe default: Fetch sends request WITHOUT If-None-Match
  for ConflictCandidate, forcing a full download.
  
  REMOTE: GET /alice/locorda/notes/note-2  (no If-None-Match — force download)
          → 200 OK, body: unchanged content, ETag: "etag-n2-v1"
  LOCAL:  READ local DB → note-2 document (Jelly bytes)
  EMIT FetchedResource(note-2, remote: BinaryGraphSource, local: BinaryGraphSource)

ConflictCandidate(note-3):
  REMOTE: GET /alice/locorda/notes/note-3  (no If-None-Match — force download)
          → 200 OK, body: new content, ETag: "etag-n3-v2"
  LOCAL:  READ local DB → note-3 document (Jelly bytes)
  EMIT FetchedResource(note-3, remote: BinaryGraphSource, local: BinaryGraphSource)

RemoteOnlyCandidate(note-4):
  REMOTE: GET /alice/locorda/notes/note-4  (no cached ETag — first time)
          → 200 OK, body: content, ETag: "etag-n4-v1"
  LOCAL:  — (no local version)
  EMIT FetchedResource(note-4, remote: BinaryGraphSource, local: null)
```

### Fetch I/O Summary

| I/O Type | Count | What |
|----------|-------|------|
| Remote download | 4 | note-1, note-2, note-3, note-4 |
| Local DB read (document content) | 3 | note-1, note-2, note-3 |
| Remote 304 | 0 | (ConflictCandidates force unconditional download) |

---

## Stage 4: CRDT Merge (Pure CPU — no I/O)

```
note-1 (ConflictCandidate, but only remote actually changed):
  DECODE remote BinaryGraphSource → RdfGraph
  DECODE local BinaryGraphSource → RdfGraph
  CRDT MERGE → result = remote version wins (local hadn't changed)
  ENCODE result → Jelly bytes
  EMIT MergedResource(note-1, DecodedGraphSource(merged, originalSource: jelly),
       needsUpload: false, newClockHash: "n1b")
  (needsUpload: false because local was unchanged — remote version accepted)

note-2 (ConflictCandidate, but only local actually changed):
  DECODE both → CRDT MERGE → result = local version wins
  ENCODE result → Jelly bytes  
  EMIT MergedResource(note-2, DecodedGraphSource(merged, originalSource: jelly),
       needsUpload: true, newClockHash: "n2b")
  (needsUpload: true because local changed — must push to remote)

note-3 (genuine conflict — both changed):
  DECODE both → CRDT MERGE → merged result (property-level LWW)
  ENCODE result → Jelly bytes
  EMIT MergedResource(note-3, DecodedGraphSource(merged, originalSource: jelly),
       needsUpload: true, newClockHash: "n3c")
  (needsUpload: true — merged state differs from both sides)

note-4 (RemoteOnly):
  DECODE remote → extract typeIri, clock, shard assignments
  ENCODE → Jelly bytes
  EMIT MergedResource(note-4, DecodedGraphSource(graph, originalSource: jelly),
       needsUpload: false, newClockHash: "n4a")
```

### Merge Output Stream (data events only)

```
MergedResource(note-1, needsUpload: false)
MergedResource(note-2, needsUpload: true)
MergedResource(note-3, needsUpload: true)
MergedResource(note-4, needsUpload: false)
+ boundaries forwarded
```

---

## Stage 5: Upload Transform (Pure Remote I/O)

```
note-1: needsUpload: false → pass through (no upload)
note-2: needsUpload: true →
  PUT /alice/locorda/notes/note-2
  Body: Jelly bytes from MergedResource.graphSource
  → 200 OK, ETag: "etag-n2-v2"
  EMIT UploadedResource(note-2, etag: "etag-n2-v2")

note-3: needsUpload: true →
  PUT /alice/locorda/notes/note-3
  Body: Jelly bytes
  → 200 OK, ETag: "etag-n3-v3"
  EMIT UploadedResource(note-3, etag: "etag-n3-v3")

note-4: needsUpload: false → pass through
```

### Upload I/O Summary

| I/O Type | Count | What |
|----------|-------|------|
| Remote PUT | 2 | note-2, note-3 |
| Pass-through | 2 | note-1, note-4 |

---

## Stage 6: DB Commit (Atomic DB Write)

Collects into batch, then single atomic transaction:

```
BEGIN TRANSACTION
  -- Core writes:
  WRITE document note-1 (Jelly bytes, clock, typeIri)
  WRITE document note-2 (Jelly bytes, clock, typeIri)
  WRITE document note-3 (Jelly bytes, clock, typeIri)
  WRITE document note-4 (Jelly bytes, clock, typeIri)
  
  WRITE index entry (note-1, Shard-A, clockHash: "n1b")    ← updated
  WRITE index entry (note-2, Shard-A, clockHash: "n2b")    ← updated
  WRITE index entry (note-3, Shard-A, clockHash: "n3c")    ← updated
  WRITE index entry (note-4, Shard-B, clockHash: "n4a")    ← new
  
  WRITE ETag note-1 → "etag-n1-v2"   (from Fetch download)
  WRITE ETag note-2 → "etag-n2-v2"   (from Upload response)
  WRITE ETag note-3 → "etag-n3-v3"   (from Upload response)
  WRITE ETag note-4 → "etag-n4-v1"   (from Fetch download)
  
  -- Backend mirror callback:
  backend.onCommit(batch):
    UPDATE mirror Shard-A:
      (note-1, "n1b")    ← was "n1a"
      (note-2, "n2b")    ← was "n2a" — now reflects uploaded version
      (note-3, "n3c")    ← was "n3a" — now reflects merged+uploaded version
    UPDATE mirror Shard-B:
      (note-4, "n4a")    ← new entry
      (note-5, "n5a")    ← unchanged
COMMIT TRANSACTION

EMIT CommitEvent(note-1), CommitEvent(note-2), CommitEvent(note-3), CommitEvent(note-4)
```

---

## Stage 7: Shard Finalize

Collects committed items per shard. At `ShardComplete` boundary, generates and uploads shard documents.

```
At ShardComplete(Shard-A):
  Committed items in Shard-A: {note-1, note-2, note-3}
  READ local DB → all current index entries for Shard-A
    → [(note-1, "n1b"), (note-2, "n2b"), (note-3, "n3c")]
  GENERATE shard document from entries
  PUT /alice/locorda/notes/shard-0
  Body: generated shard document
  → 200 OK, ETag: "etag-sa-v3"
  WRITE ETag Shard-A → "etag-sa-v3"

At ShardComplete(Shard-B):
  Committed items in Shard-B: {note-4}
  READ local DB → all current index entries for Shard-B
    → [(note-4, "n4a"), (note-5, "n5a")]
  GENERATE shard document
  PUT /alice/locorda/notes/shard-1
  Body: generated shard document
  → 200 OK, ETag: "etag-sb-v3"
  WRITE ETag Shard-B → "etag-sb-v3"

At ShardComplete(Shard-C):
  No committed items for Shard-C → SKIP (no regeneration needed)

At ShardComplete(IoI-Shard-0):
  Were any indices committed? → NO (IoI-Index, NotesIndex, TagsIndex all skipped)
  → SKIP (no IoI-Shard regeneration needed)
```

### Finalize I/O Summary

| I/O Type | Count | What |
|----------|-------|------|
| Local DB read (index entries) | 2 | Shard-A, Shard-B current entries |
| Remote PUT (shard upload) | 2 | Shard-A, Shard-B |
| CPU (shard generation) | 2 | Build shard RDF documents |
| DB write (ETag update) | 2 | Shard-A, Shard-B new ETags |

---

## Complete I/O Summary Across All Stages

### Remote HTTP Requests (total: 13)

| Request | Stage | Result |
|---------|-------|--------|
| GET IoI-Index (conditional) | Discovery | 304 |
| GET IoI-Shard-0 (conditional) | Discovery | 304 |
| GET NotesIndex (conditional) | Discovery | 304 |
| GET TagsIndex (conditional) | Discovery | 304 |
| GET Shard-A (conditional) | Discovery | 200 |
| GET Shard-B (conditional) | Discovery | 200 |
| GET Shard-C (conditional) | Discovery | 304 |
| GET note-1 (unconditional for conflict) | Fetch | 200 |
| GET note-2 (unconditional for conflict) | Fetch | 200 |
| GET note-3 (unconditional for conflict) | Fetch | 200 |
| GET note-4 (first time) | Fetch | 200 |
| PUT note-2 | Upload | 200 |
| PUT note-3 | Upload | 200 |
| PUT Shard-A | Finalize | 200 |
| PUT Shard-B | Finalize | 200 |

### Local DB Reads (total: ~16)

| Read | Stage |
|------|-------|
| 7× ETag lookups | Discovery |
| 3× index_shards queries (IoI, NotesIndex, TagsIndex — shard IRI lookup after 304) | Discovery |
| 3× Document metadata (updatedAt check for hierarchy docs) | Diff |
| 2× Mirror reads (Shard-A, Shard-B entries) | Diff |
| 2× Index entry reads (Shard-A, Shard-B local entries) | Diff |
| 4× Remaining-items queries (at ShardComplete boundaries) | Diff |
| 3× Document content reads (note-1, note-2, note-3 for merge) | Fetch |
| 2× Index entry reads (Shard-A, Shard-B for finalize) | Finalize |

### Local DB Writes

| Write | Stage |
|-------|-------|
| 4× Document writes | Commit |
| 4× Index entry writes | Commit |
| 4× ETag writes (resources) | Commit |
| Mirror updates (Shard-A, Shard-B) | Commit (backend callback) |
| 2× ETag writes (shards) | Finalize |

---

## Open Questions Highlighted by This Walkthrough

### Q1: Where do IoI-Shard child IRIs come from when the shard is 304?

In Step 1.1.5, the IoI-Shard returned 304. Discovery needs to know which Index IRIs to visit at Level 2. Since we don't have fresh remote content, the options are:

- **Mirror**: Backend stores parsed shard entries → Discovery asks backend for known child IRIs
- **Local DB**: Discovery queries for known index documents directly

Both yield the same result for an unchanged shard. The local DB approach is simpler (no mirror dependency in Discovery), but loses the information about which children exist *remotely* vs. *locally-only*. However: since the shard is 304, the remote children haven't changed since the mirror was last written — so the mirror's child set equals the local DB's child set (for this shard). **Local DB is sufficient.**

### Q2: ConflictCandidate when only one side changed — wasted remote download?

In the Fetch stage, note-2 is a ConflictCandidate (only local changed), yet Fetch downloads it from remote anyway (unconditional GET). This is a redundant download — the remote content is identical to what we already have locally from the mirror era.

This is the cost of the "safe default" approach. The alternative optimization (verify via clock subsumption that a one-sided accept is safe) would eliminate this download. For a small number of such cases, the overhead is acceptable. For a scenario where 1000 resources changed locally but not remotely, this would mean 1000 unnecessary downloads — worth optimizing later.

### Q3: Fetch must distinguish conditional vs. unconditional GETs

For `RemoteOnlyCandidate` and `ConflictCandidate`, Fetch must download from remote. But:
- RemoteOnly: Can use If-None-Match (should get 200 — Discovery already confirmed change)
- Conflict: Must force download (no If-None-Match) because the shard-level change detection doesn't guarantee this specific resource changed remotely

Actually this distinction is subtle. For ConflictCandidate from shard entries where remote clockHash ≠ mirror clockHash, the remote DID change — an unconditional GET would also return 200. The problematic case is ConflictCandidate where only local changed (remote clockHash = mirror clockHash). Here, a conditional GET with cached ETag would return 304 — but we need the content for merge.

**Simplest approach**: Always use unconditional GET for ConflictCandidate. The overhead of re-downloading unchanged content is small (we're already downloading changed content for genuine conflicts). Optimize later if profiling shows this matters.
