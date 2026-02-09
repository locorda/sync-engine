# Personal Notes App - Web Assets

This directory contains assets intended for deployment to GitHub Pages at:
`https://locorda.dev/example/personal_notes_app/`

## Directory Structure

### `/vocabulary/`
Custom RDF vocabularies for the Personal Notes app:
- `personal-notes.ttl` - Custom vocabulary defining `NotesCategory` and `PersonalNote` types
  - Properly specializes `schema:CreativeWork` and `schema:NoteDigitalDocument`
  - Follows ADR-0002 guidance for unique RDF type IRIs per Dart type
  - Includes domain-specific properties like `categoryColor` and `categoryIcon`

### `/mappings/`
CRDT merge contract definitions:
- `note-v1.ttl` - CRDT merge strategies for personal notes
- `category-v1.ttl` - CRDT merge strategies for note categories
- Define how properties merge during sync conflicts (LWW, OR-Set, Immutable)
- eventually, those files should be generated from annotations

### `/auth/`
OIDC client configuration:
- `client-config.json` - OAuth/OIDC client metadata for Solid Pod authentication
- Pre-configured for GitHub Pages deployment URLs

## Deployment

These assets should be deployed to GitHub Pages to make them accessible at predictable URLs that the Flutter app can reference. The URLs are already configured in the Dart code:

```dart
const baseUrl = 'https://locorda.dev/example/personal_notes_app/mappings';
```

## Vocabulary Design

The custom `NotesCategory` vocabulary demonstrates best practices from ADR-0002:
- **Specific over generic**: Uses domain-specific type instead of generic `schema:CreativeWork`
- **Proper inheritance**: Subclasses standard Schema.org types for interoperability
- **Unique RDF IRIs**: Each Dart type maps to exactly one RDF type IRI
- **Semantic clarity**: Clear distinction between notes and their categories

This prevents the RDF type IRI collisions that could cause issues in:
- Solid type registry entries
- Index configurations 
- CRDT merge strategies