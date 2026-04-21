# ADR-0004: Project Assessment and Future Direction

## Status
PROPOSED → Decision pending final reflection

## Context

After approximately 6 months of intensive development work on Locorda (May-November 2025), attempting to build production-ready offline-first sync for Solid Pods, fundamental questions have emerged about the viability of the current approach.

**Original Hypothesis**: Solid apps are slow because they query the pod every time. Solution: offline-first architecture with local storage, CRDTs, smart indexing/sharding, and selective sync.

**Discovery**: The fundamental performance problems **cannot be solved through client-side optimization**. The issues are inherent to the Solid Protocol design.

**For complete analysis**, see [STATUS.md](../../../../STATUS.md) which documents the detailed assessment, technical discoveries, and personal reflections.

## Decision Drivers

* **Performance bottleneck**: Single entity sync takes ~1 second (GET+PUT+HEAD @ ~300ms each) - unsolvable by client optimization
* **Protocol limitations**: No batching, SPARQL endpoints removed from spec, inherently chatty design (see STATUS.md "Solid Protocol Limitations")
* **Ecosystem immaturity**: All providers "early adopters only", poor UI/UX, manual ACL editing required
* **Alternative uncertainty**: Google Drive pivot requires significant rework with uncertain performance outcome

## Options Considered

### Option 1: Continue with Solid Backend
**Not viable** - Cannot solve fundamental protocol-level performance problems. Even optimal client implementation hits 1-second-per-entity bottleneck.

### Option 2: Pivot to Google Drive Backend  
**Uncertain viability** - Batch API available but requires major rework. Performance outcome unclear. Would essentially be a new project.

### Option 3: Archive Project with Documentation
**Currently preferred** - Honest assessment prevents further investment in problematic approach. Preserves learnings and CRDT work for community.

See [STATUS.md § Alternative Paths Forward](../../../../STATUS.md#alternative-paths-forward) for detailed analysis of each option.

## Decision

**ARCHIVE PROJECT** (Proposed - pending final reflection)

**Rationale**: After 6 months of work, Solid Protocol's fundamental performance limitations (no batching, SPARQL removed, ~1 second per entity sync) cannot be overcome by client-side optimization. Ecosystem remains immature with unclear timeline to production readiness.

**What will be preserved**: 
- Complete specification and working implementation
- CRDT algorithms and RDF vocabularies
- **Valuable RDF libraries developed**: `rdf_core`, `rdf_xml`, `rdf_vocabulary_to_dart`, `rdf_vocabularies`, `rdf_canonicalization`, `rdf_mapper`, `rdf_mapper_annotations`, `rdf_mapper_generator`
- Comprehensive documentation of what doesn't work and why

See [STATUS.md](../../../../STATUS.md) for complete analysis.

## Consequences

**Key outcome**: While Locorda itself isn't viable, the project produced valuable RDF tooling for the Dart ecosystem and comprehensive documentation of Solid Protocol limitations.

**Trade-off**: 6 months of work doesn't yield the intended offline-first sync library, but provides reusable RDF packages and honest assessment for the community.

See [STATUS.md § Consequences](../../../../STATUS.md#consequences) for detailed positive/negative/neutral outcomes.

## Related

* **Primary Assessment**: [STATUS.md](../../../../STATUS.md) - Complete analysis with technical details and reflections
* **Original Specification**: [spec/docs/ARCHITECTURE.md](../../../../spec/docs/ARCHITECTURE.md)
* **Previous ADRs**: [0000](0000-use-architecture-decision-records.md), [0001](0001-iri-strategy-extension.md), [0002](0002-dart-type-vs-rdf-type-mapping.md), [0003](0003-sync-as-addon-architecture.md)

---

**Note to Solid community**: This represents one developer's honest experience in November 2025. I admire the vision and would be delighted to be proven wrong on these concerns.
