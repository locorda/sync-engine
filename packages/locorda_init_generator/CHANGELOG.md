## 0.5.1

 - **FIX**: do not use field that was deprecated in analyzer 10 and removed in analyzer 12. ([fab5758e](https://github.com/locorda/sync-engine/commit/fab5758ec2b1115b8b2875ed4aa0055e59667ba7))

## 0.5.0

- Initial public release
- `InitLocordaBuilder`: generates `lib/init_locorda.g.dart` — a `initLocorda()` convenience wrapper that calls `Locorda.create()` with auto-detected worker setup, mapper initialiser and config
- `ConfigBuilder`: generates `lib/locorda_config.g.dart` from `@RootResource` annotations
- `CrdtMappingBuilder`: generates CRDT mapping Turtle documents consumed by `locorda_mapping_bootstrap_generator`
- Together with `locorda_builder` and `locorda_dev`, eliminates all boilerplate for standard Locorda application setup
