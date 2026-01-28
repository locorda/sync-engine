# locorda

**Bring your own persistence layer and make it syncable to a Solid Pod.**

Offline-first CRDT synchronization with Solid Pods. Build Flutter apps that work offline and sync seamlessly with Solid Pods using conflict-free replicated data types (CRDTs).

## Quick Start

Add to your `pubspec.yaml`:

```yaml
dependencies:
  locorda: ^0.1.0
  locorda_drift: ^0.1.0  # SQLite storage backend
```

Create a model with CRDT annotations:

```dart
import 'package:locorda/locorda.dart';
import 'package:locorda_rdf_mapper_annotations/annotations.dart';

@RdfGlobalResource(IriTerm('https://example.org/Note'))
class Note {
  @RdfProperty(Schema.identifier)
  @RdfIriPart()
  String id;

  @RdfProperty(Schema.name)
  @CrdtLwwRegister()  // Last writer wins for title
  String title;

  @RdfProperty(Schema.text)
  @CrdtLwwRegister()  // Last writer wins for content
  String content;

  @RdfProperty(Schema.keywords)
  @CrdtOrSet()  // Tags can be added/removed independently
  Set<String> tags;

  Note({required this.id, required this.title, required this.content, Set<String>? tags})
      : tags = tags ?? {};
}
```

Set up the sync system:

```dart
import 'package:locorda/locorda.dart';
import 'package:locorda_drift/locorda_drift.dart';

void main() async {
  // Create storage backend
  final storage = DriftStorage(path: 'notes.db');
  
  // Set up sync system
  final sync = await Locorda.setup(storage: storage);
  
  // Create and save a note (works offline!)
  final note = Note(
    id: 'note-1',
    title: 'My First Note',
    content: 'This works offline and syncs to Solid Pods!',
    tags: {'offline-first', 'crdt'},
  );
  
  await sync.save(note);
  
  // Retrieve notes
  final allNotes = await sync.getAll<Note>();
  print('Notes: ${allNotes.length}');
  
  // Optional: Connect to Solid Pod for sync
  final auth = SolidAuthProvider(/* your config */);
  await sync.connectToSolid(auth);
  await sync.sync();  // Sync with pod
}
```

## Features

- **Offline-First**: Your app works completely offline
- **CRDT Merge Strategies**: Conflict-free synchronization
  - `@CrdtLwwRegister()` - Last writer wins (good for titles, content)
  - `@CrdtOrSet()` - Observed-remove sets (good for tags, lists)
  - `@CrdtImmutable()` - Never changes after creation
- **Solid Pod Integration**: Optional sync with Solid Pods
- **Flutter Ready**: UI components for auth and sync status
- **RDF-Based**: Clean, semantic data that's interoperable

## Architecture

This package provides a convenient entry point to the locorda ecosystem:

- `locorda_core` - Platform-agnostic sync engine
- `locorda_annotations` - CRDT merge strategy annotations  
- `locorda_drift` - SQLite/Drift storage implementation
- `locorda_solid_auth` - Solid authentication integration

## Examples

See the `example/` directory for a complete personal notes app demonstrating:
- Offline-first note creation and editing
- CRDT merge strategies in action
- Optional Solid Pod authentication
- Conflict resolution when syncing

## Learn More

- [Architecture Documentation](https://github.com/your-org/locorda/blob/main/spec/docs/ARCHITECTURE.md)
- [CRDT Specification](https://github.com/your-org/locorda/blob/main/spec/CRDT_SPECIFICATION.md)
- [Security Considerations](https://github.com/your-org/locorda/blob/main/spec/docs/SECURITY.md) - Critical OAuth/OIDC redirect URI security
- [Solid Integration Guide](https://github.com/your-org/locorda/blob/main/docs/SOLID_INTEGRATION.md)