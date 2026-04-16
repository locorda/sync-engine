# locorda_core Internal Public Methods Audit Report

**Date:** 2026-04-16  
**Scope:** locorda_core package - internal public methods (no underscore, NOT exported)  
**Analysis:** Comprehensive search across packages/locorda_core/lib/src/ and cross-repo validation  

---

## Executive Summary

| Category | Count |
|----------|-------|
| **Total unused methods** | 11 |
| **Total test-only methods** | 7 |
| **Methods analyzed** | 500+ |
| **Files reviewed** | 168 |

---

## UNUSED Methods (Zero Production Callers)

### Group 1: Test Helper Methods with Wrong Names

#### backend/in_memory_backend.dart

**`getAllDocuments()`** [line 163]
```dart
Map<IriTerm, StoredDocument> getAllDocuments() {
  return _documents.map(
    (key, value) => MapEntry(IriTerm(key), value),
  );
}
```
- **Status:** UNUSED (never called anywhere)
- **Docstring:** "Returns a snapshot of all documents for testing purposes"
- **Issue:** Lacks `ForTesting` suffix; conflicts with `getStoredDocumentsForTesting()` which IS used
- **Recommendation:** Either remove or consolidate with the ForTesting variant

---

### Group 2: Unimplemented/Abandoned ShardManager Methods

#### index/shard_manager.dart

**`calculateNextShardCount()`** [line 121]
```dart
int calculateNextShardCount() { ... }
```
- **Status:** UNUSED (0 callers)
- **Type:** Public method on non-exported class

**`incrementScaleVersion()`** [line 135]
```dart
void incrementScaleVersion() { ... }
```
- **Status:** UNUSED (0 callers)
- **Type:** Public method on non-exported class

**`incrementConflictVersion()`** [line 155]
```dart
void incrementConflictVersion() { ... }
```
- **Status:** UNUSED (0 callers)  
- **Type:** Public method on non-exported class

**Issue:** These methods suggest a versioning/scaling feature that was either abandoned or never completed. No production code references any of them.

**Recommendation:** Remove if feature is not planned; if planned, mark with `@Deprecated` and document the feature status.

---

### Group 3: Unused Storage Interface Getters

#### storage/storage_interface.dart

**`hasUnsyncedRemote`** [line 798]
```dart
bool get hasUnsyncedRemote;
```
- **Status:** UNUSED (0 callers anywhere)
- **Type:** Interface getter on exported class Storage
- **Context:** Other similar getters ARE used:
  - `hasInitialSyncError` → used in standard_sync_engine.dart:443,446
  - `hasError` → used in example app
  - `hasStaleError` → used in tests only
- **Recommendation:** Remove if not part of active feature; may be dead code from earlier design

---

### Group 4: Unused RDF Utility Extensions

#### rdf/rdf_extensions.dart

**`RdfGraph.empty`** [line 11]
```dart
static RdfGraph get empty => RdfGraph.fromTriples([]);
```
- **Status:** UNUSED (0 callers)
- **Type:** Static getter extension
- **Context:** No code uses empty graphs; could be a convenience that's not needed
- **Recommendation:** Remove if not used in examples or documentation

**`LiteralTerm.dateTime()`** [line 307]
```dart
static LiteralTerm dateTime(DateTime dt) => ...
```
- **Status:** UNUSED (0 callers)
- **Type:** Extension factory method
- **Note:** `dateTimeFromMillisecondsSinceEpoch()` IS used (in crdt_types.dart, local_document_merger.dart)
- **Issue:** Duplicate or alternative factory that's never called
- **Recommendation:** Remove unless documenting a preferred pattern

---

### Group 5: Unused XSD Vocabulary Constants (9 items)

#### rdf/xsd.dart

All of these are **completely UNUSED** across all packages:

| Constant | Line | Status |
|----------|------|--------|
| `Xsd.dateTimeStamp` | 121 | UNUSED |
| `Xsd.yearMonthDuration` | 129 | UNUSED |
| `Xsd.dayTimeDuration` | 137 | UNUSED |
| `Xsd.normalizedString` | 145 | UNUSED |
| `Xsd.token` | 153 | UNUSED |
| `Xsd.Name` | 159 | UNUSED |
| `Xsd.NCName` | 165 | UNUSED |
| `Xsd.NMTOKEN` | 173 | UNUSED |
| `Xsd.ID` | 181 | UNUSED |

**Analysis:**
- Only these XSD constants are actually used in production:
  - `Xsd.string`
  - `Xsd.integer`
  - `Xsd.double`
  - `Xsd.boolean`
  - `Xsd.langString`

- All unused constants suggest:
  - Planned features/vocabularies never materialized
  - Copy-pasted from XSD spec without usage need
  - Placeholders for future enhancement

**Recommendation:** 
- Move to separate `xsd_unused.dart` file or remove entirely
- If planned, add `@Deprecated('Not yet used')` with tracking issue reference
- Clean up before v1.0 release

---

## TEST-ONLY Methods (Production: 0 callers; Test-only: 1+ callers)

These are intentional inspection/helper APIs for testing. Generally acceptable to keep, but should be documented clearly.

### Storage Test Helpers

#### storage/in_memory_storage.dart

**`getAllDocumentsForTesting()`** [line 95]
```dart
Map<IriTerm, StoredDocument> getAllDocumentsForTesting() {
  return Map<IriTerm, StoredDocument>.unmodifiable(_documents);
}
```
- **Callers:** `packages/locorda_core/test/sync/sync_engine_test.dart`
- **Status:** TEST-ONLY (used by 1 test)
- **Type:** Test inspection API

**`resetPropertyChanges()`** [line 305]
```dart
void resetPropertyChanges() {
  _propertyChanges.clear();
}
```
- **Callers:** `packages/locorda_core/test/sync/sync_engine_test.dart`
- **Status:** TEST-ONLY (used by 1 test)
- **Type:** Test setup helper

#### backend/in_memory_backend.dart

**`getStoredDocumentsForTesting()`** [line 170]
```dart
List<RemoteStoredDocument> getStoredDocumentsForTesting() {
  return _documents.entries
      .map((entry) => RemoteStoredDocument(...))
      .toList();
}
```
- **Callers:** `packages/locorda_core/test/sync/sync_engine_test.dart`
- **Status:** TEST-ONLY (used by 1 test)
- **Type:** Test inspection API

---

### Index Test Helper

#### index/index_property_resolver.dart

**`clearCache()`** [line 331]
```dart
void clearCache() {
  _cache.clear();
}
```
- **Callers:** `packages/locorda_core/test/index/index_property_resolver_test.dart`
- **Status:** TEST-ONLY (used by 1 test)
- **Type:** Test setup helper
- **Comment in code:** "Clears the cache. Useful for testing or when indices are rebuilt."

---

### Config Test Helper

#### config/config_base.dart

**`getAllIndices()`** [line 45]
```dart
Iterable<CrdtIndexConfigBase> getAllIndices() { ... }
```
- **Callers:** `packages/locorda/test/config/resource_config_test.dart` (and `packages/locorda_objects/test/...`)
- **Status:** TEST-ONLY (used in tests only)
- **Type:** Test inspection getter

---

### Serialization Test Helper

#### sync/pipeline/backend/remote_sync_storages.dart

**`RemoteStorageLayout.fromJson()`** [line 58]
```dart
factory RemoteStorageLayout.fromJson(Map<String, dynamic> json) { ... }
```
- **Callers:** `packages/locorda_core/test/sync/sync_engine_test.dart:169`
- **Status:** TEST-ONLY (JSON deserialization in test setup)
- **Type:** Test mock deserializer

---

### Storage Interface Test Getters

#### storage/storage_interface.dart

**`hasStaleError`** [line 776]
```dart
bool get hasStaleError;
```
- **Callers:** `packages/locorda_objects/test/index/index_instance_sync_state_test.dart` (7 test references)
- **Status:** TEST-ONLY (test assertions only)
- **Type:** Test assertion getter on interface

**`warmupIriIds()`** [line 125]
```dart
Future<void> warmupIriIds(Iterable<IriTerm> iris);
```
- **Implementations:** 
  - `in_memory_storage.dart:107`
  - `drift_storage.dart:521`
- **Callers:** `packages/locorda_drift/test/drift_storage_test.dart:538`
- **Status:** TEST-ONLY (test setup only)
- **Type:** Test preparation helper

---

## Verified as USED (Kept for Reference)

These methods were audited and confirmed to have production callers:

### Internal Classes with Full Usage
- `ContentIndexResolver.computeMetaIndexIris()` → used in pipeline orchestrator
- `ContentIndexResolver.resolveContentIndices()` → used in stage14 feedback
- `RemoteDocumentMerger.merge()` → used in CRDT merge stages
- `RootResourceFetchPolicy.fromMap()` → used in drift_storage configuration
- `PipelineRemoteSyncStorage.createIriTranslated()` → used in in_memory_backend
- All `data_types.dart` classes (OrganizedGraph, MergeObject, MergeSubject, etc.) → used in CRDT merge chain
- All utility extensions (RdfGraphExtensions, LiteralTermExtensions, etc.) → used throughout sync pipeline

---

## Recommendations by Priority

### Priority 1: REMOVE (Dead Code)
1. **`getAllDocuments()`** - Duplicate of ForTesting variant; confusing naming
2. **`ShardManager.calculateNextShardCount/incrementScaleVersion/incrementConflictVersion()`** - Abandoned feature
3. **All XSD vocabulary constants** - Move to separate file or @Deprecated if planned

**Action:** Remove or deprecate within one version cycle

### Priority 2: CLARIFY (Unclear Intent)
1. **`hasUnsyncedRemote`** - Orphaned interface getter; document if planned or remove
2. **`RdfGraph.empty` and `LiteralTerm.dateTime()`** - Verify if truly unused or needed for completeness

**Action:** Check project backlog/roadmap; deprecate or use

### Priority 3: ACCEPT (Test Helpers)
1. All `ForTesting()` methods - intentional inspection APIs
2. `resetPropertyChanges()`, `clearCache()`, `warmupIriIds()` - valid test setup helpers

**Action:** Add `@visibleForTesting` annotation for clarity

### Priority 4: VERIFY (Interface Contracts)
1. `hasStaleError`, `warmupIriIds()` - appear to be part of Storage interface contract
2. Consider documenting these as optional/testing-only contract methods

**Action:** Add documentation or `@Deprecated` if truly test-only

---

## Implementation Path

```
Phase 1 (Immediate): Remove dead code
├─ Delete getAllDocuments() 
├─ Delete ShardManager methods (3)
└─ Delete XSD constants (9)
  
Phase 2 (This version): Deprecate/Clarify
├─ Mark hasUnsyncedRemote as @Deprecated
├─ Mark RdfGraph.empty as @Deprecated  
└─ Mark LiteralTerm.dateTime() as @Deprecated

Phase 3 (Next version): Remove deprecated

Phase 4 (Next version): Clean up test helpers
└─ Ensure all @visibleForTesting annotations are present
```

---

## Files Affected (Removal Impact)

| File | Method | Impact | Effort |
|------|--------|--------|--------|
| backend/in_memory_backend.dart | `getAllDocuments()` | Low - no callers | 1 min |
| index/shard_manager.dart | 3 methods | Medium - incomplete feature | 10 min |
| rdf/xsd.dart | 9 constants | High - large deletion | 5 min |
| storage/storage_interface.dart | `hasUnsyncedRemote` | Medium - interface contract | 15 min |
| rdf/rdf_extensions.dart | 2 methods | Low - utility functions | 5 min |

**Total Effort:** ~40 minutes for complete cleanup

---

## Notes on Audit Methodology

1. **Export list extraction:** Parsed `lib/locorda_core.dart` to identify exported public API
2. **Source code analysis:** Reviewed all 168 files in `lib/src/` for public methods
3. **Cross-repo validation:** Searched all packages in workspace (locorda_core, locorda_drift, locorda_objects, locorda, locorda_solid)  
4. **Test file analysis:** Distinguished production vs. test-only callers
5. **False positive check:** Verified each candidate multiple times with ripgrep

---

**Audit Completed:** 2026-04-16  
**Next Review:** After implementing recommendations  
**Archive Path:** `.agents/2026-04-16/archive/` (when superseded)
