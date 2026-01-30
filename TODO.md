# TODO

## Up Next

### Priority 1: Document Persistence (Core Foundation)
- [x] Storage Layer: save documents
- [x] SyncEngine: save base implementation
- [x] merge-contract: Implement loading and merging the mappings documents and make them usable via dart classes
- [x] merge-contract: In-memory caching of loaded merge contracts (LRU cache to avoid repeated expensive loading on every save)
- [x] Use data from mapping documents to build the stop-word list to correctly separate appGraph from framework data in processing of the old stored document
- [x] Implement context-identification for blank nodes 
- [x] Association of merge contract rules: if we do not find a rule, and the type is not specified, we should use type inference and look up the predicate rule within the class rules, assuming the type automatically. This is probably also a spec change proposal
- [x] We need to implement the type-specific stop traversal as well
- [x] rdf canonicalization 
- [x] fix w3id.org redirects
- [x] Create a unique identifier IRI for identified blank nodes
- [x] Do not use blank nodes for framework metadata, use fragments with #lcrd- prefix instead. Fix the corresponding FIXMEs to create predictable, hash based fragments
- [x] Setup Testing Framework similar to official RDF Canonicalization test where there is a csv/json file describing the test cases and referencing input/output files. 
- [x] Installation document is needed and installation id generating (needs to be controlled/overridden in tests though)
- [x] check hlc clock handling and creation - the hlc clock in the expected test data looks dubious
- [x] shall we keep the clock entries as blank nodes, or identify them? If we keep them as blank nodes, then they probably need to be detected and merged as ibn - but that would add extra meta data so it is rather suboptimal. I tend to think that framework data must not be blank nodes, so clock entries would become identifiable iris as well. or we need special handling - doing special handling for clock entries seems sensible anyways, right?
- [x] Implement clock hash computation
- [x] Store Blank Node identifier IRI mapping in the document metadata, merging in the old data on save (?)
- [x] Use context-identification (aka identified blank node) as a base for `List<PropertyChange>` passed to storage layer instead of IriTerm for resource identification
- [x] Create tombstones on save where needed (e.g. change detection)
- [x] What about tombstones for blank nodes - only possible for identified, exceptions else
- [x] Tests for error cases
- [x] test clock merge during save (e.g. when a foreign clock entry existed) => save_11 test
- [x] Use the testing framework to thoroughly test SyncEngine.save()
- [x] Concept addition: I think we need to revisit the identified blank node concept - Pure, path based should work as well => proposal 008 and impl.
- [x] Implement resource identity
- [x] Implement (optional) external IRI for better DX 
- [x] Change 008 proposal slightly again: we really should use the path identification by default
- [x] Implement something like `IriStrategy(provideAs: "documentIri")` in rdf_mapper_*, so that we can have sub-annotations here that work together smoothly, just marking as PodResource and PodSubResource. But beware: the IRI of the root resource is not 100% what we want, unless we actually have an extra IriStrategy.relative() with separate templates.
- [x] Locorda: Make sure that all patterns like IRI-Identified Sub-Resources, identified blank nodes and unidentified blank nodes are shown. Ideas: Weblink in Note for (classical) identified blank node, Comment in Note for IRI-Identified sub-content, CategoryDisplaySettings in Category for single-path-identified blank node
- [x] Storage Layer: save locorda indices
- [x] Implement locorda index files in db and fill/update them on save
- [x] Implement saving/loading/merging documents with local storage persistence
  - Currently `save()` just emits hydration events without storage persistence
  - Need CRDT merging logic and actual storage operations => Real CRDT merging is not part of local document persistence
  - This unblocks the example app's core functionality
- [x] Implement IndexManager.determineShards for FullIndex 
- [x] Implement IndexManager.determineShards for GroupIndexTemplate - this implies creation of group indexes. 
- [x] Complete full index, group index and shard creation 
- [x] More tests in all_tests.json, especially for testing the shard and index handling
- [x] I think we need some concept to switch between strict and lenient for document structure errors - sometimes we throw exceptions on structural errors, sometimes we only log and continue. A consistent tooling would be great here, that allows us to run in either strict or lenient mode - ideally not as static utility, but that is probably unrealistic, so a static utility would be better than nothing still.

### Priority 2: SyncManager with Status Stream
- [x] Create SyncManager with status stream and automatic sync triggering
  - Essential for user-facing sync control and feedback
  - Enables manual/automatic sync triggering
  - Foundation for all higher-level sync operations
- [x] global resource annotation for Index entries (e.g. NoteIndexEntry in the example app)
- [x] Rename @PodResource and @PodSubResource annotations to something more appropriate, like @LocordaResource and @LocordaSubResource
 
### Priority 3: Index Processing
- [x] Implement index entry hydration (hydrateStream for indices)
  - Loads shard documents and extracts index entries
  - Provides lightweight resource views with indexed properties only
- [x] Complete index subscription handling (full and group)
  - Complete group subscription logic
  - Currently stubbed in `configureGroupIndexSubscription()`
  - Needed for efficient data organization and sync
- [x] Optimize index entry hydration performance
  - **Entry-level change tracking:** ✅ **IMPLEMENTED**
  - **Solution:** Progressive cursor tracking in `watchIndexEntries()` - maintains a per-stream cursor
    that filters entries by `updatedAt`, emitting only entries that have changed since the last emission.
  - **Implementation details:**
    - Uses `StreamController` with manual cursor tracking
    - Filters entries on Dart side after Drift watch triggers
    - Minimal memory overhead (one int per stream)
    - Works seamlessly with existing batch loading phase
  - **Completed optimizations:**
    - ✅ Track entry-specific cursors (via updatedAt per entry)
    - ✅ Entry-level batching respecting initialBatchSize
    - ✅ Efficient change detection using timestamps (no diff algorithms needed)
  - **Result:** Only changed entries are re-emitted, not entire shards
- [x] Adjust example app and Locorda to semantic changes wrt index item graphs - they now use the resource iri, not the entry iri!


### Priority 4: Backend Implementations
- [x] Refine concept for actual sync algorithm
- [x] We need prefetch_filtered fetching in addition to prefetch and onRequest
- [x] We need an index of indices (full and group templates)
- [x] Implement in-memory backend for testing and development
  - Simpler to implement than Solid backend
  - Enables testing without external dependencies
  - Good foundation for understanding backend interface
- [x] Fix the ShardDeterminer to use the actual full index and group index documents instead of the configuration as a base
- [x] RemoteSyncOrchestrator: the sync loop needs to run per resource type, not try to sync all at once, fully syncing index of indices (and thus all indices) first
- [x] undeletions in OR-Sets: OrSet muss in localValueChange prüfen, ob es tombstones für die neuen Werte gibt, und ggf. diese Tombstones entfernen (achtung:  die statements nur wenn sie nicht für andere predicates benutzt werden - sonst nur die crdt:deletedAt values), 
- [x] RemoteSyncOrchestrator: 
  - Ensure that the shards are calculated by the ShardDeterminer based on the merged document before proceeding
  - store locally in _syncDocument, calling the indexManager to update shards
- [x] save in _syncDocument: 
  - shards berechnen für merged_doc, 
  - merged_doc_new durch Ersetzen von shards mit neuer shard liste, 
  - crdt_types.localValueChange anwenden (bzw. reduzierte Version von CrdtDocumenManager._generateCrdtMetadataForChanges) - das muss ggf. alte tombstones wieder entfernen
  - diese Version für upload und lokales speicher nutzen
- [x] SEHR Wichtig: conditional save! So wie wir etags nutzen um sicherzustellen, dass unsere uploads sich auf den korrekten state beziehen, müssen wir das auch für save machen! Und achtung: Reihenfolge bei sync zw. remote und local nochmal prüfen/diskutieren
- [x] RemoteSyncOrchestrator: Restructure to reduce memory overhead and complexity, make sure to process each resource type / index / shard / document hierarchical
- [x] RemoteSyncOrchestrator: Review and implement TODOs/FIXMEs - the LLM used to generate some code
- [x] on save metadata computation: Don't we have to check for existing tombstone entries and remove them ? What happens to those? will we get endless tombstone chains? => should be fixed by revised OrSet implementation
- [x] Implement Partial Index Sync (items in our indexed items table that are from foreign shards ) see [001-partial-foreign-shard-sync.md]
- [x] Should we prepare the remote sync code for the possibility to have different remotes? Maybe by prefixing the etags? => yes, it is remote specific now
- [x] How do we get foreign shard indices to our DB? Are we missing something here? Actually, I think no: we only want to sync those entries from foreign indices that we already know about, and those will eventually end up in the documentsToSync queue. And when the documents are synced, their shards (old and new) are updated in our DB - so our DB index entries should be correct and up-to-date.
- [x] Is our physical timestamp handling in _syncDocument in the remote_sync_orchestrator correct? => should be now - index entries get their timestamps from the indexed document, physical clock always is "ours" setting remote-only values to zero
- [x] Implement real CRDT Merge 
- [x] Implement actual syncing to a backend
- [x] Implement basic Solid backend with actual Pod storage operations (hard-coded storage locations)
- [x] Implement tests for real CRDT Merge 
- [x] Example App Responsiveness: offload syncing from ui thread to isolate on native
- [x] API Improvements: use EngineParams as parameter for Locorda.create (and maybe SyncEngine.create) and rename engineParamsFactory in Locorda.createWithWorker to engineParamsFactory
- [x] Rework "plugin/provider": Rename to sender/receiver (Main thread sends data, worker receives)
- [x] Token refresh?
- [x] UI: User is stuck with refresh button
- [x] Remove extraOidcScopes from notes_list_screen (and client profile jsonld) again and verify it still works correctly
- [x] Example App Responsiveness: offload syncing from ui thread to web worker on web
- [x] Implement basic GDrive Backend
- [ ] GDrive Backend: proper e-tag support (with custom http.Client wrapper)
- [ ] GDrive Backend: is there a way to get the token expiry time so we can make use of it e.g. in UpdateAuthMessage?
- [ ] GDrive Backend: we have to search by name all the time - this seems very inefficient, especially for group indices and shards where the id is a relative path. Is there some better solution? Can/Should we store the path/id relationships in our DB?
- [ ] GDrive: behaviour regarding oauth scopes - explain the user before calling google what we need and why, and if we did not get it, then tell the user that we cannot store to GDrive due to missing permissions and log the user out again. Plus: can we get rid of the automatic email/profile scopes which seem to be added by google for openid? Maybe we can do without openid scope?
- [ ] Sync: implement support for "change streams" or  such for faster continuous synchronization, implement at least for gdrive.
- [ ] AutoSync - throttle sync after authorization (login)
- [ ] AutoSync - throttled sync after changes (save)
- [ ] Optimize: check after merge if merged result differs from remote and upload only if it does
- [ ] build_runner: dirty detection for worker.dart.js is not working correctly - it will only detect changes to worker.dart itself, but not to  transitive changes - can this be fixed somehow?
- [ ] Fix "Could not find statement subject in document" => apparently we are removing statement subjects, but keep the hasStatement triples during merges - we have to fix this and find out if this only affects statements, or if this can happen to any subject
- [ ] Streamline web worker experience - it should be built and deployed automatically, at least in the example app
- [ ] Fix bugs in the group index template document 
- [ ] Implement ensure
- [ ] Thoroughly test, for example
  - Foreign indices/shards that are referenced, but not yet downloaded when an item is saved!
- [ ] Move Sync into a Background worker, use DriftIsolate to put DB-Operations into a single isolate. https://gemini.google.com/share/d862857eb169
- [ ] Example App: I think that the synchronization takes a lot longer than I expected - why? Can I improve?
- [ ] Rework "sender/receiver": provide a cleaner API to those classes (better encapsulation of the messaging)

### Priority 4.b: Improve solid support
- [ ] Solid: use solid type registry
- [ ] Solid: write solid type registry if user allows - maybe even allow user to edit settings?
- [ ] Solid: do we need more dialogs to inform expert users?
- [ ] Solid: find a robust way for mapping interal/external IRIs that cannot be broken by changes to the type registry
- [ ] Solid: not really pure solid, but maybe allow the user to use app-specific storage location after all? 

### Priority 5: Implement Delete
- [ ] Deletion support is part of the concept and the example app has deletion usecases, but it is not fully implemented yet
- [ ] Implement proper index entry deletion tracking
  - **Problem:** When an entry is removed from a shard's `idx:containsEntry` OR-Set,
    it currently just stops appearing in updates without explicit deletion notification.
  - **Challenges:**
    - Tombstones are for entries, not for the referenced resources
    - Tombstones don't carry the `idx:resource` property by default
    - Entries can "disappear" due to re-sharding (moving to different shard), not true deletion
  - **Possible solutions:**
    - Enhance tombstone structure to include `idx:resource` reference
    - Track entry removals separately from resource deletions
    - Distinguish between "entry removed due to re-sharding" vs "resource deleted"
    - Maintain a separate deletion stream based on tombstone analysis
    - Include both the resource predicate and some special deletion marker in the entry tombstone to mark this as the tombstone for deleting the resource, not only the shard entry
  - **Impact:** Applications currently need to handle missing entries gracefully,
    treating absence as implicit deletion. Explicit deletion events would improve UX.

### Priority 6: Ensure full Offline-First Support
- [ ] merge-contract: Build-time asset bundling (essential for offline-first: bundle all referenced merge contracts as assets so apps work offline from first launch)

### Priority 7: Performance & Efficiency Optimizations
- [ ] merge-contract: RdfGraphFetcher caching with etag support (HTTP best practices, benefits all RDF loading)
- [ ] merge-contract: Local database caching (persistence across app restarts)
- [ ] rdf_vocabulary_to_dart: failed to load RDF graph for graphs marked as skipped must not be an error, build must not be marked as "failed" due to this
- [ ] Implement shard splitting/resharding when shards reach maxSize limits (Implement Re-Sharding as per the specification)
  - Increment shard number for overflow
  - Update shardTotal in index/template
  - Migrate entries to correct shards based on new distribution
- [ ] Use drift storage for locorda graph sync test

## Later
- [ ] Implement namespace in Resource Identity => maybe later
- [ ] Final check if the spec in ARCHITECTURE.md is fully implemented

## Future Feature Ideas

### Auto-Generated Worker Configuration
- [ ] Investigate automatic generation of worker.dart to eliminate parallel configuration
  - **Problem**: Currently storage and remotes must be configured separately on main and worker sides
  - **Idea**: Use code generation (similar to existing builder) to automatically generate worker.dart from main-side configuration
  - **Benefits**: 
    - DRY principle - single source of truth for backend configuration
    - Reduced error potential - no manual synchronization needed between main/worker
    - Better maintainability - changing backends only requires main-side update
  - **Challenges**:
    - Worker-specific configuration (e.g., WorkerContext dependencies)
    - Platform-specific options (web vs native)
    - Build-time vs runtime flexibility trade-offs
  - **Related**: We already have builder infrastructure (locorda_builder package)

## Done
- [x] Migrate to W3ID.org permanent IRIs
- [x] Clarify: can we include localhost into the client-config.json document to support local debugging? Or should we rather not do that since it would open up our app to attacks? => better not, plus: removed linux/windows support and adviced against those platforms
- [x] Refactor: Solid should only be one possible backend - rename from solid_crdt_sync to locorda and split the spec as well
- [x] Refactor: I am thinking about adding something like SyncEngine which would be similar to Locorda, but not based on dart objects + mapper, but on pure RdfGraph instances. The Idea is, that SyncEngine should be used by Locorda for the actual work, so that Locorda itself adds the dart object conversion on top of the more basic sync service. Clarify if I want to do it now or possibly later => done
- [x] Clarify: What is the most-user-friendly way to approach http? should we simply assume that we are provided with http client, or is it best practice for a library like ours to abstract this away? Remember: http would need to be integrated with solid DPoP, is this in our control, or should we offload it to the developer? => http.Client is an interface, let users optionally provide an instance - this is common practice and other networking implementations have adapters for this interface.
