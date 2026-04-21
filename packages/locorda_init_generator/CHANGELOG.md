## 0.5.0

- Initial public release
- `InitLocordaBuilder`: generates `lib/init_locorda.g.dart` — a `initLocorda()` convenience wrapper that calls `Locorda.create()` with auto-detected worker setup, mapper initialiser and config
- `ConfigBuilder`: generates `lib/locorda_config.g.dart` from `@RootResource` annotations
- `CrdtMappingBuilder`: generates CRDT mapping Turtle documents consumed by `locorda_mapping_bootstrap_generator`
- Together with `locorda_builder` and `locorda_dev`, eliminates all boilerplate for standard Locorda application setup
