## 0.5.2

 - **FIX**(dependencies): update analyzer version constraint to support Dart SDK range. ([f738f93b](https://github.com/locorda/sync-engine/commit/f738f93b94560dd96b94d86238ae2603f0437a41))
 - **DOCS**: reposition packages as BYOB offline-first sync. ([9a03fd0a](https://github.com/locorda/sync-engine/commit/9a03fd0a170ace56bc9a372aae2effea1949aa19))

## 0.5.1

## 0.5.0

- Initial public release
- Unified dev-dependency: add `locorda_dev` once to activate all Locorda build-time tooling
- Activates `locorda_builder:web_worker` — compiles `lib/worker.dart` and the generated `lib/worker_generated.g.dart` to JavaScript for web platform support
- Activates `locorda_mapping_bootstrap_generator:mapping_bootstrap` — embeds CRDT mapping documents as `const List<String>` for offline-first bootstrap loading
- Activates `locorda_init_generator` — generates `lib/init_locorda.g.dart`, `lib/worker_generated.g.dart`, `lib/locorda_config.g.dart` and related files
- Activates `locorda_rdf_mapper_generator` — generates RDF mapper cache, source and init files for Dart ↔ RDF serialisation
