## 0.5.0

- Initial public release
- `MappingBootstrapBuilder`: build_runner builder that discovers CRDT mapping Turtle documents from package assets and embeds them as `const List<String> bootstrapMappings` in `src/generated/mapping_bootstrap.g.dart`
- Enables offline-first CRDT merge contract loading without runtime HTTP requests
- Applied automatically when using `locorda_dev` as a dev dependency
