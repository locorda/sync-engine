# ADR-003: Sync as Add-on Architecture

**Philosophy:** Bring your own persistence layer and make it syncable to a Solid Pod.

## Status
ACCEPTED

## Context

The `locorda` library needed to define its fundamental relationship with application storage systems. Two primary architectural patterns were considered:

1. **"Sync as Storage"**: The sync system acts as the primary database, with apps querying directly against RDF/CRDT data structures
2. **"Sync as Add-on"**: Apps maintain their own storage layer, with the sync system providing synchronization capabilities as an overlay service

This decision impacts developer experience, query capabilities, data consistency guarantees, and the overall positioning of the library in the Flutter/Dart ecosystem.

## Decision

We have chosen **"Sync as Add-on"** architecture with atomic consistency guarantees.

The sync system provides synchronization capabilities as an overlay service while applications retain full control over their local storage layer. This is implemented through a callback-based API that ensures atomic consistency between app storage and sync metadata.

### API Design

```dart
class Locorda {
  // Robust save method with callback for atomic consistency
  Future<void> saveWithCallback<T>(T object, {
    required void Function(T processedObject) onLocalUpdate,
  });
  
  // Stream of remote updates for existing data
  Stream<T> remoteUpdates<T>();
}
```

### Service Pattern

```dart
class ExampleService {
  final AppStorage _appStorage;      // App queries here
  final Locorda _syncSystem;   // CRDT + Pod sync here
  
  // Saves: Through sync system with callback
  Future<void> save(Object obj) async {
    await _syncSystem.saveWithCallback(obj, onLocalUpdate: (processed) {
      _appStorage.save(processed);  // App gets CRDT-merged version
    });
  }
  
  // Queries: Purely from app storage
  Future<List<Object>> getAll() => _appStorage.getAll();
}
```

## Consequences

### Positive
- **Developer Experience**: Familiar storage patterns and query capabilities
- **Robustness**: Atomic consistency prevents sync/app storage divergence  
- **Flexibility**: Apps can optimize storage for their specific use cases
- **Performance**: Apps can use storage optimized for their query patterns
- **Ecosystem Fit**: Aligns with Flutter/Dart development practices
- **Migration Friendly**: Existing applications can add sync without changing their storage architecture

### Negative
- **Complexity**: Two storage layers to coordinate (app + sync metadata)
- **Memory Overhead**: Some data exists in both storage layers
- **Integration Work**: Services must coordinate between both storage systems

## Implementation Notes

### Storage Layers
1. **App Storage**: Developer-chosen technology for application data and queries
2. **Sync Metadata Storage** (`SolidCrdtDatabase`): CRDT-specific tables for sync coordination
3. **Service Layer**: Coordinates between both storage systems

### Atomic Consistency Strategy
The callback pattern prevents race conditions by ensuring app storage is updated immediately after CRDT processing:

```dart
// ROBUST (chosen):
await _syncSystem.saveWithCallback(obj, onLocalUpdate: (processed) {
  _appStorage.save(processed);  // Immediate update with CRDT-processed version
});

// PROBLEMATIC (rejected):
await _appStorage.save(obj);     // App has version A
await _syncSystem.save(obj);     // Sync processes A, but remote update B arrives
// → App and sync become inconsistent
```

### Remote Updates
Services listen to `remoteUpdates<T>()` stream to automatically merge remote changes into app storage, ensuring app storage stays synchronized with CRDT state without manual polling.

## Related
- Future ADR needed for storage backend abstraction strategy
- Future ADR needed for CRDT merge strategy configuration
- `spec/docs/ARCHITECTURE.md` - 4-layer architecture documentation

**Note**: This foundational architecture will be extended with additional patterns and abstractions as the library matures, but the core "sync as add-on" principle remains fixed.