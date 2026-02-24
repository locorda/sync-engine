# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Quick Reference

**Architecture**: 4-layer (Data Resource → Merge Contract → Indexing → Sync Strategy)
**CRDT Types**: LWW-Register, FWW-Register, OR-Set, 2P-Set, Immutable
**Index Types**: FullIndex (monolithic) vs GroupIndex (partitioned), with RootResourceFetchPolicy (onRequest/prefetch)
**Scale**: 2-100 installations (optimal: 2-20)
**Key Commands**: `melos bootstrap`, `melos test`, `melos format`, `dart tool/run_tests.dart`
**Critical Rule**: Ask before ANY code edit (bug fixes, features, refactoring)

## Project Overview

**Locorda: Sync offline-first apps using your user's remote storage**

**Locorda** — the rope that connects and weaves local data together.

This is a multipackage Dart library (`locorda`) that enables synchronization of RDF data to Solid Pods using CRDT (Conflict-free Replicated Data Types) for offline-first, interoperable applications. The library follows a state-based CRDT approach with passive storage backends.

The project is organized as a monorepo with the following packages:
- `locorda` - Main entry point package with documentation and examples
- `locorda_core` - Platform-agnostic sync logic and runtime engine
- `locorda_annotations` - CRDT merge strategy annotations for code generation
- `locorda_generator` - Build runner integration for RDF + CRDT code generation
- `locorda_solid_auth` - Solid authentication integration using solid-auth library
- `locorda_solid_ui` - Flutter UI components including login forms and sync status widgets
- `locorda_drift` - Drift (SQLite) storage backend implementation

## 🛑 MANDATORY: Ask Before Code Edits (With Exceptions)

**CRITICAL WORKFLOW RULE**

Before editing any file in the repository:

1. ✅ Identify the issue and solution
2. ✅ Explain what needs changing (code example optional)
3. ⚠️ **ASK: "Shall I implement this?"**
4. ⏸️ **WAIT for: "yes"/"approve"/"do it"**
5. ✅ Then (and only then) use edit tools

**Exception**: When the user gives a **direct, specific instruction** for exactly what to do:
- ✅ "Translate this document to English" → Just do it
- ✅ "Fix the typo in line 42" → Just do it
- ✅ "Add logging here" (with specific location) → Just do it
- ❌ "The code has a bug" → Ask first (solution unclear)
- ❌ "Improve performance" → Ask first (approach unclear)

**Applies to everything else:**
- Bug fixes where solution is not explicitly specified
- Refactoring, optimizations, features
- ANY file modification where approach is not crystal clear

**Enforcement checklist:**
```
□ Is this a direct instruction with clear action?
  → YES: Proceed
  → NO: Ask first
□ Did I ask explicitly when unsure?
□ Did user approve explicitly?
□ If NO to either → STOP, ask first
```

## Key Architecture Concepts

The project is built around a **4-layer architecture** that enables offline-first, collaborative, and truly interoperable applications using passive storage backends (with Solid Pods as the primary focus):

### 4-Layer Architecture

1. **Data Resource Layer**: Individual RDF resources with clean, standard vocabularies
   - Clean RDF using standard vocabularies (schema.org, custom vocabularies)
   - Fragment identifiers (#it) to distinguish "things" from documents
   - Self-contained resources with semantic IRIs

2. **Merge Contract Layer**: Public CRDT rules for conflict resolution
   - Declarative property-to-CRDT mappings via `sync:` and `crdt:` vocabularies
   - Public, discoverable merge contracts for cross-application interoperability
   - Property-level merge strategies (LWW-Register, OR-Set, Immutable, etc.)

3. **Indexing Layer**: Performance optimization through sharded indices
   - Sharded indices with `idx:` vocabulary for scalable data organization
   - Supports both monolithic (`idx:RootIndex`) and partitioned (`idx:PartitionedIndex`) indices
   - Group-based organization using regex transformations for hierarchical structures

4. **Sync Strategy Layer**: Application-controlled synchronization patterns
   - **Index Types**: FullIndex (single index for all items) vs GroupIndex (partitioned by groups)
   - **RootResourceFetchPolicy**: onRequest (on-demand) vs prefetch (eager loading)
   - **Sharding**: Indices split into multiple shards for performance

### Core Design Principles

- **Offline-First**: Fully functional offline with cached data, optional partial sync for large datasets
- **State-Based CRDTs**: Synchronizes complete resource states (not operations) using property-specific algorithms
- **Hybrid Logical Clocks**: Combines logical causality tracking with physical timestamps for tamper-resistant ordering
- **Passive Storage Integration**: Works with Solid Pods as simple storage buckets, all logic client-side
- **Semantic Preservation**: RDF semantics maintained throughout synchronization process
- **Managed Resource Discoverability**: Self-describing system via `sync:ManagedDocument` Type Index registrations

### Key Constraints

**Scale**: Designed for 2-100 installations (optimal: 2-20) - personal to small team collaboration
**Single-User Storage Focus**: CRDT synchronization within one user's storage backend (multi-user backend integration planned for v2/v3)

The core philosophy is that this service acts as an "add-on" for synchronization, not a database replacement. Developers retain full control over local storage and querying.

## Development Commands

### Melos Workspace Management
- `dart pub run melos bootstrap` - Bootstrap all packages (run after cloning)
- `dart pub run melos list` - List all packages in workspace
- `dart pub run melos clean` - Clean and get dependencies for all packages

### Testing
- `dart pub run melos test` - Run tests for all packages
- `dart tool/run_tests.dart` - Run tests with coverage (generates coverage/lcov.info and HTML report)
- Individual package testing: `cd packages/PACKAGE_NAME && dart test --coverage=coverage`

#### Test Record Mode
Some tests support **record mode** for creating/updating expected test results:
- `RECORD_MODE=true dart test` - Run tests in record mode (overwrites expected files)
- Use this to regenerate expected RDF graphs after intentional changes to test logic or CRDT behavior
- Always review changes via `git diff` before committing - record mode overwrites files!
- Currently supported: `sync_engine_test.dart` (graph sync expectations)

**Workflow**: Make code changes → run with `RECORD_MODE=true dart test` → review git diff → commit if correct

### Code Quality  
- `dart pub run melos analyze` - Run static analysis for all packages
- `dart pub run melos format` - Format code for all packages (follow this before commits)
- `dart pub run melos lint` - Combined analyze + format check for all packages

### Version Management & Publishing
- `dart pub run melos version` - Update versions across all packages with changelog generation
- `dart pub run melos publish` - Publish all packages to pub.dev
- `dart pub run melos release` - Preview version + publish process
- See `tool/version_and_release.md` for detailed workflow

### Database Management (macOS)
- Clean Drift databases: `rm -f ~/Library/Containers/dev.locorda.example.personalNotesApp/Data/Documents/*.sqlite*`
  - Removes both `locorda_sync.sqlite` and `personal_notes_app.sqlite` databases
  - Use when app fails to start due to corrupted or incompatible database schema
  - App will recreate fresh databases on next launch

## Key Files and Structure

### Core Documentation
- `spec/docs/ARCHITECTURE.md` - Complete architectural specification with 4-layer model, CRDT algorithms, and implementation guidance
- `spec/docs/CRDT-SPECIFICATION.md` - Detailed CRDT algorithms, Hybrid Logical Clock mechanics, and merge procedures
- `spec/docs/GROUP-INDEXING.md` - Group indexing system with regex transformations and hierarchical organization
- `spec/docs/PERFORMANCE.md` - Performance analysis, benchmarks, and optimization guidance
- `spec/docs/ERROR-HANDLING.md` - Comprehensive error handling and graceful degradation patterns
- `spec/docs/SHARDING.md` - Index sharding strategies and filesystem mapping
- `spec/docs/FUTURE-TOPICS.md` - Roadmap for multi-Pod integration and advanced features

### RDF Vocabularies and Specifications

**Core Vocabularies:**
- `vocabularies/` - Custom RDF vocabularies:
  - `crdt-algorithms.ttl` - CRDT merge algorithms (`algo:` namespace: LWW-Register, OR-Set, FWW-Register, Immutable, 2P-Set)
  - `crdt-mechanics.ttl` - Framework infrastructure (`crdt:` namespace: clocks, installations, deletion, tombstones)
  - `idx.ttl` - Indexing vocabulary (sharding, group keys, index types)
  - `sync.ttl` - Synchronization vocabulary (managed documents, strategies, contracts)

**Merge Contract Mappings:**
- `mappings/` - Semantic mapping files for CRDT merge contracts:
  - `core-v1.ttl` - Essential CRDT mappings imported by all other mapping files
  - Application-specific mapping files (client-installation-v1.ttl, recipe-v1.ttl, etc.)
  - Public, discoverable contracts enabling cross-application interoperability

**RDF Integration Patterns:**
- Fragment identifiers (#it) for clean thing/document separation
- RDF reification for semantically correct deletion tombstones
- Blank node context identification for stable CRDT object identity
- Standard vocabulary usage (schema.org) with CRDT extensions

### Tools
- `tool/` - Dart utilities for testing, versioning, and releases

## Package Architecture Guidelines

### Multipackage Structure Requirements
The project follows these architectural principles established during development:

- **Separate packages with clear dependency chains** - No circular dependencies between packages
- **No re-exports between packages** - Each package exports only its own functionality  
- **Clean separation of concerns** - CRDT annotations separate from core runtime logic
- **Single entry point package** - `locorda` provides documentation and convenient access
- **RDF mapper ecosystem integration** - CRDT annotations depend on `rdf_mapper_annotations`
- **Good documentation** - Follow comprehensive documentation standards (see Documentation Guidelines below)

### Dependency Architecture
```
locorda (main entry point)
├── locorda_core (runtime engine)
├── locorda_annotations (code gen annotations)
├── locorda_solid_auth (authentication)
├── locorda_solid_ui (Flutter widgets)  
└── locorda_drift (storage backend)

locorda_annotations
└── rdf_mapper_annotations (external dependency)
```

## Documentation Guidelines

### What "Good Documentation" Means

**Content-wise:**
1. **Single narrative** - Treats RDF + CRDT as one coherent story, not separate technologies
2. **Progressive disclosure** - Simple example → full features → advanced concepts  
3. **Working examples** - Personal notes app as the "hello world" demonstration
4. **Clear mental models** - "This is distributed data modeling, not just sync"
5. **Troubleshooting guide** - Common annotation mistakes, build issues, sync conflicts

**Technically:**
1. **DartDoc + more** - DartDoc for API reference, but need guides/tutorials beyond generated docs
2. **README hierarchy** - Main package has complete story, sub-packages reference back to main narrative
3. **Inline examples** - Every annotation shows usage in context with real code
4. **Generated examples** - Show what the code generator produces, not just input

### Documentation Structure
- Main `locorda` package README provides the complete story and mental model
- Individual package READMEs focus on their specific role within the larger narrative
- Examples demonstrate real-world usage patterns, not toy scenarios
- API documentation includes both what and why for each component

### Architecture Decision Records (ADRs)

**Location**: `packages/locorda/docs/adrs/` - See README.md and template.md in that directory for process and format.

## Development Guidelines


### Collaborative Development Approach

**CRITICAL: Always ask before ANY code edit**

When working on this codebase:

1. **Ask-first approach**: Before ANY file edit, explicitly ask "Shall I implement this?"
2. **Wait for approval**: User must say "yes"/"approve"/"do it" before you edit
3. **Applies to everything**: Bug fixes, features, refactoring, tests, documentation
4. **Start minimal**: When approved, start with smallest possible change
5. **Focus on actual usage**: Design based on real example app needs
6. **Avoid over-engineering**: No complex systems without explicit approval
7. **Iterative refinement**: Basic working solution first, then add complexity if needed

**Example of correct workflow**:
- You: "I found bug X. Fix would be Y. Shall I implement this?"
- User: "yes"
- You: [Implement the fix]

**Example of WRONG workflow**:
- You: "I found bug X. [Implements fix immediately]" ← NO!
- You: "Here's the solution [code block]. [Edits file]" ← NO!
- You: "This is obviously needed [edits file]" ← NO!

### RDF and Semantic Web Focus
- All data stored as clean, standard RDF that's human-readable
- Use fragment identifiers (#it) to distinguish "things" from documents  
- Maintain interoperability through public merge contracts
- Follow semantic web best practices with proper vocabulary usage

### CRDT Implementation

**Core Algorithms**: State-based CRDTs with Hybrid Logical Clocks for causality + physical timestamp tie-breaking
**Deletion**: RDF reification tombstones (property-level), `crdt:deletedAt` triples (document-level)
**Performance**: O(1) change detection via clock hash comparison, efficient bandwidth usage
**Details**: See `spec/docs/CRDT-SPECIFICATION.md` for complete algorithm specifications

### Indexing Strategy

**Types**: FullIndex (monolithic) vs GroupedIndex (partitioned with regex transformations)
**Sharding**: 1-16 shards with lightweight headers, O(1) change detection per shard
**Organization**: Hierarchical group keys for date/category-based organization
**Details**: See `spec/docs/GROUP-INDEXING.md` and `spec/docs/SHARDING.md`

### API Design Patterns

**Repository-Based Hydration**: Main pattern using `hydrateStreaming<T>()` with callbacks:
- `getCurrentCursor()`: Repository provides current sync position
- `onUpdate(item)`: Handle new/updated items from sync
- `onDelete(item)`: Handle deleted items from sync
- `onCursorUpdate(cursor)`: Persist new sync position

**Developer Control**: App controls local storage/querying via repositories, library handles CRDT merging
**Sync Operations**: `syncSystem.save<T>(object)` and `syncSystem.deleteDocument<T>(object)` for changes
**Index Configuration**: Configure per-resource via FullIndexConfig or GroupIndexConfig with RootResourceFetchPolicy

### Deletion Handling
- Framework deletion is for system-level cleanup (storage optimization, retention policies)
- Applications typically implement domain-specific soft deletion (`archived: true`, `hidden: true`)
- Document-level deletion: `deleteDocument()` performs complete CRDT deletion processing
- Layered approach: applications can use both soft deletion (user-facing) and framework deletion (backend cleanup)

## Testing Approach

Uses Dart's built-in `test` package with comprehensive coverage across all architectural layers.
**Key Areas**: CRDT algorithms, HLC mechanics, indexing/sharding, merge contracts, sync strategies, error handling
**Run Tests**: `dart tool/run_tests.dart` (with coverage) or `melos test` (all packages)

## Code Style

- Follow standard Dart formatting (`dart format`)
- Use clear, semantic naming that reflects RDF/Solid concepts
- Document public APIs with usage examples
- Maintain separation between sync logic and local storage concerns
- We are in the initial development phase and must not burden our code with "legacy" or "backwards compatibility" code - just get rid of code that is not right (any more)
- Align with W3C CRDT for RDF Community Group standardization efforts
- Follow semantic web best practices with proper vocabulary usage
- Maintain interoperability through public merge contracts and standard RDF

### Code Quality
  - Clean and minimal, please
  - Write idiomatic Dart following language conventions and best practices
  - Use Dart's type system effectively - catch specific exceptions, handle nulls explicitly
