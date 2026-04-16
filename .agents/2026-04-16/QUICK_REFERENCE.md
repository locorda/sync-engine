# Quick Reference: Unused Methods Summary

## Audit Statistics
- **Analyzed:** 500+ methods across 168 files
- **Unused Found:** 11 methods
- **Test-Only Found:** 7 methods
- **Kept (Verified Used):** 482+ methods

---

## Quick List: Remove These Now (Unused)

### 1. `backend/in_memory_backend.dart`
```dart
// Line 163 - REMOVE or rename to ForTesting variant
Map<IriTerm, StoredDocument> getAllDocuments() { ... }
```

### 2. `index/shard_manager.dart` - ALL 3 METHODS
```dart
// Line 121 - REMOVE (abandoned feature)
int calculateNextShardCount() { ... }

// Line 135 - REMOVE (abandoned feature)  
void incrementScaleVersion() { ... }

// Line 155 - REMOVE (abandoned feature)
void incrementConflictVersion() { ... }
```

### 3. `rdf/xsd.dart` - DELETE ALL 9
```dart
// Lines 121-181: All these XSD constants are UNUSED
Xsd.dateTimeStamp
Xsd.yearMonthDuration
Xsd.dayTimeDuration
Xsd.normalizedString
Xsd.token
Xsd.Name
Xsd.NCName
Xsd.NMTOKEN
Xsd.ID
```

### 4. `rdf/rdf_extensions.dart`
```dart
// Line 11 - REMOVE or document
static RdfGraph get empty => RdfGraph.fromTriples([]);

// Line 307 - REMOVE (duplicate of dateTimeFromMillisecondsSinceEpoch)
static LiteralTerm dateTime(DateTime dt) => ...
```

### 5. `storage/storage_interface.dart`
```dart
// Line 798 - REMOVE or @Deprecated (interface getter, orphaned)
bool get hasUnsyncedRemote;
```

---

## Test-Only Methods (Keep with @visibleForTesting annotation)

| Method | File | Line | Test File |
|--------|------|------|-----------|
| `getAllDocumentsForTesting()` | storage/in_memory_storage.dart | 95 | sync_engine_test.dart |
| `resetPropertyChanges()` | storage/in_memory_storage.dart | 305 | sync_engine_test.dart |
| `getStoredDocumentsForTesting()` | backend/in_memory_backend.dart | 170 | sync_engine_test.dart |
| `clearCache()` | index/index_property_resolver.dart | 331 | index_property_resolver_test.dart |
| `getAllIndices()` | config/config_base.dart | 45 | resource_config_test.dart |
| `hasStaleError` (getter) | storage/storage_interface.dart | 776 | index_instance_sync_state_test.dart |
| `warmupIriIds()` | storage/storage_interface.dart | 125 | drift_storage_test.dart |

---

## Quick Search Commands

```bash
# Find each unused method in editor:
rg -n "getAllDocuments\(" packages/locorda_core/lib/src/backend/in_memory_backend.dart
rg -n "calculateNextShardCount\|incrementScaleVersion\|incrementConflictVersion" packages/locorda_core/lib/src/index/shard_manager.dart
rg -n "hasUnsyncedRemote" packages/locorda_core/lib/src/storage/storage_interface.dart

# Verify no usage exists:
rg "getAllDocuments" packages/ --glob '!*.g.dart' | wc -l  # Should be: 2 (definition only)
```

---

## Cleanup Effort

| Task | Time | Priority |
|------|------|----------|
| Remove unused methods | 15 min | P1 |
| Delete XSD constants | 5 min | P1 |
| Add @visibleForTesting annotations | 10 min | P2 |
| Update tests if needed | 10 min | P3 |
| **Total** | **40 min** | - |

---

## Before/After File Sizes

```
shard_manager.dart:         ~200 lines → ~170 lines  (-30)
rdf/xsd.dart:               ~190 lines → ~140 lines  (-50)
backend/in_memory_backend:  ~190 lines → ~185 lines  (-5)
storage/storage_interface:  ~850 lines → ~845 lines  (-5)
rdf/rdf_extensions.dart:    ~320 lines → ~310 lines  (-10)
                            ———————————————————————————
                            Total: -100 lines
```

---

## Risk Assessment

| Method | Risk of Removal | Notes |
|--------|---|---|
| `getAllDocuments()` | **LOW** | 0 callers, duplicate functionality |
| `calculateNextShardCount()` | **LOW** | 0 callers, abandoned feature |
| `incrementScaleVersion()` | **LOW** | 0 callers, abandoned feature |
| `incrementConflictVersion()` | **LOW** | 0 callers, abandoned feature |
| XSD constants | **LOW** | 0 callers, not exported |
| `RdfGraph.empty` | **LOW** | 0 callers, utility function |
| `LiteralTerm.dateTime()` | **LOW** | 0 callers, duplicate |
| `hasUnsyncedRemote` | **MEDIUM** | Interface method - check if part of contract |

---

**Action Items:**
1. ✅ Create file: `.agents/2026-04-16/locorda_core_audit_report.md` (detailed analysis)
2. ⏳ Review this summary with team
3. ⏳ Get approval for removal
4. ⏳ Implement cleanup
5. ⏳ Run tests
6. ⏳ Commit with summary message
