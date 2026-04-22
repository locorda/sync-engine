## 0.5.1

## 0.5.0

- Initial public release
- `@RootResource` — marks a class as a Locorda-managed RDF resource and configures its storage layout and index strategy
- `@CrdtLwwRegister` — Last-Write-Wins register: the value with the highest Hybrid Logical Clock timestamp wins
- `@CrdtFwwRegister` — First-Write-Wins register: the first observed value is preserved
- `@CrdtOrSet` — Observed-Remove Set: supports concurrent add/remove with re-add semantics
- `@CrdtImmutable` — write-once property: set on creation, never overwritten by sync
- Integration with `rdf_mapper_annotations` for combined RDF mapping and CRDT code generation