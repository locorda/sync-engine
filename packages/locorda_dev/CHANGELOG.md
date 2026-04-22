## 0.5.1

## 0.5.0

- Initial public release
- Unified dev-dependency: add `locorda_dev` once to activate all Locorda build-time tooling
- Activates `locorda_builder:web_worker` — compiles `lib/worker.dart` and the generated `lib/worker_generated.g.dart` to JavaScript for web platform support
- Activates `locorda_mapping_bootstrap_generator:mapping_bootstrap` — embeds CRDT mapping documents as `const List<String>` for offline-first bootstrap loading
- Activates `locorda_init_generator` — generates `lib/init_locorda.g.dart`, `lib/worker_generated.g.dart`, `lib/locorda_config.g.dart` and related files
- Activates `locorda_rdf_mapper_generator` — generates RDF mapper cache, source and init files for Dart ↔ RDF serialisation
