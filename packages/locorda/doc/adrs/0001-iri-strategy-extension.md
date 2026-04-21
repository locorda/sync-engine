# ADR-0001: IRI Strategy Annotation Design for Solid Pod Integration

## Status
PROPOSED

## Context
The current RDF mapping approach using `IriStrategy()` is quite flexible and supports runtime context through template variables and custom mappers, but still doesn't seem sufficient for the complex requirements of Solid Pod integration in a offline-first architecture.

**Current IriStrategy capabilities:**
```dart
// Template with runtime context:
@RdfGlobalResource(Schema.NoteDigitalDocument, 
  IriStrategy('{+baseUrl}/notes/{id}'))
class Note {
  @RdfIriPart()
  String id;
}

// Or custom mapper:
@RdfGlobalResource(Schema.NoteDigitalDocument, 
  IriStrategy.namedMapper('podIriMapper'))
class Note {
  @RdfIriPart()
  String id;
}
```

**Why existing capabilities are insufficient:**
Even with `baseUrlProvider` and custom mappers, the Solid Pod integration requirements create additional complexity:

**Core Design Challenge:**
While `IriStrategy` supports runtime context and custom mappers, Solid Pod integration requires **combining runtime context with computed path derivation** that the current system doesn't easily support:

- **Application-defined partitioning**: Path derivation from ID values (e.g., UUID → `a7/f2/a7f2-...`)
- **Dynamic pod URL resolution**: Pod URLs only known after authentication
- **Type-specific path resolution**: Note storage paths from Solid Type Index on pod
- **Offline-first**: Must work without any pod connection
- **Multi-layer context combination**: Need pod URL + type path + computed ID paths
- **Context-dependent IRI generation**: Different IRIs needed for offline vs online states

**Complex requirements example:**
```dart
// What we need to achieve:
Local ID: "a7f2c4e8-1234-5678-9abc-def012345678" (UUID)

// Context-dependent IRI generation:
→ Offline mode: urn:local:notes:a7/f2/a7f2c4e8-1234-5678-9abc-def012345678
→ Alice's Pod: https://alice.pod.com/notes/a7/f2/a7f2c4e8-1234-5678-9abc-def012345678  
→ Bob's Pod: https://bob.pod.com/personal/notes/a7/f2/a7f2c4e8-1234-5678-9abc-def012345678
→ During sync: Map offline IRIs to pod IRIs seamlessly

// Problem: Need context-aware IRI generation AND multi-layer path resolution
Offline template: 'urn:local:notes:{computedPath}/{id}'
Pod template: '{+podUrl}{+typeIndexPath}{computedPath}/{id}'
Where:
  podUrl = https://alice.pod.com (from authentication)
  typeIndexPath = /notes/ (from Solid Type Index lookup)
  computedPath = function(id) => id.substring(0,2) + '/' + id.substring(2,4)
```

**Technical Constraint:**
How to combine **runtime context variables** (pod URL from authentication) with **type-specific path resolution** (from Solid Type Index) AND **computed path derivation** (from UUID values) AND **context-dependent IRI generation** (offline vs online) in a single IRI strategy? 

Current `IriStrategy` can do either:
- Runtime context: `IriStrategy('{+podUrl}/notes/{id}')`  ✓
- Custom computation: `IriStrategy.namedMapper('customMapper')`  ✓
- **But not multi-layer resolution**: Pod URL + Type Index paths + computed paths + context-awareness ✗

**What we need:**
```dart
@RdfGlobalResource(Schema.NoteDigitalDocument, SolidPodIriStrategy())
class Note {
  @RdfIriPart()
  String id = "a7f2c4e8-1234-5678-9abc-def012345678";  // UUID
}

// Should automatically handle:
// - Context-aware IRI generation (offline URNs vs pod URLs)
// - Runtime pod URL resolution (from authentication)
// - Type-specific path resolution (from Solid Type Index)
// - Computed path derivation from UUID (a7/f2/...)
// - Seamless IRI mapping during offline-to-online sync
// - Application-defined partitioning strategy
```
Or maybe even
```
@PodResource(Schema.NoteDigitalDocument, /* somehow configure the path pattern */)
class Note {
  @RdfIriPart()
  String id = "a7f2c4e8-1234-5678-9abc-def012345678";  // UUID
}
```

and we also need to be able to reference such resources on the same pod, e.g. 
```
@PodResource(...)
class Document {
  // ...
  @RdfProperty(..., iri: PodResourceRef(Note))
  String noteRef;
}
```
**Key Requirements:**
1. **App-controlled IDs**: Developer controls identity/equality semantics
2. **Computed path derivation**: Support application-defined partitioning (UUID → path structure)
3. **Context-aware IRI generation**: Different IRI schemes for offline vs online states
4. **Multi-layer context resolution**: Pod URL (auth) + type paths (Type Index) + computed paths (ID)
5. **Offline compatibility**: Works without any pod connection using local URN scheme
6. **Seamless sync mapping**: Automatic offline→online IRI translation during synchronization
7. **Integration with existing IriStrategy**: Build on existing capabilities rather than replace them

**Technical Constraint:**
How to extend `IriStrategy` to support **multi-layer context resolution** (pod URL from auth + type paths from Type Index + computed ID paths), **context-aware IRI generation** (offline URNs vs pod URLs) in a single annotation while maintaining simplicity and offline-first requirements?

## Decision
[TBD - Research needed]

This is a fundamental annotation API design challenge that requires careful research and experimentation to solve properly.

## Consequences
[TBD]

## Implementation Notes
**Blocked by:** 
- Pod connection architecture design
- Understanding of RDF mapper extension points
- Runtime context injection mechanisms

**Research areas:**
- How to bridge compile-time annotations with runtime context
- Extension points in current RDF mapper architecture
- Pod configuration and type mapping strategies
- Offline fallback mechanisms

**Related files:**
- `/packages/locorda/example/personal_notes_app/lib/models/note.dart`
- RDF mapper annotation processing
- Future Pod connection architecture

## Related
- Will impact: All model classes, sync architecture, Pod integration
- Dependencies: RDF mapper extension capabilities, Pod connection design
