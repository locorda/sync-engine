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

We want to be able to embed all resources of a shard together with the shard in one single rdf dataset file where the shard (metadata) itself is the default graph, and the resources are named graphs.

### Two Modes of operation

It is up to the backend to choose which mode of operation it wants. There will now be two possible modes of operation for the backend:

#### 1. One File per resource
In this mode, every root resource (@RootResource) as modelled by the application (e.g. every note, every category etc.) will be stored in a file in the remote storage. This mode of operation has the following characteristics:

* `RootResourceFetchPolicy.onRequest` is fully supported, e.g. the application only fetches those root resources it actually wants/needs
* Might be slower than expected due to latency - if every single http request takes appr. 300ms or more, this does not work well
* Most natural for backends like solid which support linked data - other applications would at least be able to find  and read this data then.

#### 2. One File per shard (RDF Dataset)
In contrast to the other mode, now the backend will store **all** data of a shard including all data of the root resources of the resources it references in one RDF Dataset. The shard metadata (which would be its own file in the other mode) will be the default graph, all root resources of this shard will be named graphs in this dataset. The complete RDF Dataset is stored as a single file by the backend.

* Does not support `RootResourceFetchPolicy.onRequest`. 
  * The application can still use that mode, but it will always get all data of a shard pushed from the backend
  * This also affects all other backends (if multiple backends are configured): before sync the framework has to check if there are unfetched items and has to fetch them - if it can't, then it cannot sync, effectively disabling onRequest for all active backends.
* Should be faster since there are a lot fewer http requests - at the expense of potentially bandwidth though
* The RemoteSyncOrchestrator must coordinate the modes. In Shard Dataset Mode
  * completeness of root resources is enforced (e.g all resources of a shard will always be in local db)
  * sync document of the root resources of a shard will actually skip upload
  * When the shard document is about to be uploaded, all root resources of the shard are collected, put into a dataset and pushed to the backend
* We should implement this such, that each backend chooses per datatype which mode to use - while I do not yet plan to make actually use of this, it seems most natural and potentially powerful.

* Duplicate Data - the same resource which is referenced by multiple shards (during migration, but also due to grouping) might be in multiple shard datasets and might get out of sync
  * TODO: how to ensure at least eventual consistency if the same backend can have a resource in multiple shards - will this simply heal itself over time due to our crdt semantics?

