/// Locorda Dev - unified build-time tools for Locorda applications.
///
/// Add this package as a single `dev_dependency` to activate all Locorda
/// builders via `applies_builders`:
///
/// ```yaml
/// dev_dependencies:
///   build_runner: ^2.4.0
///   locorda_dev: any
/// ```
///
/// ## Included builders
///
/// - **locorda_builder:web_worker**: Compiles `lib/worker.dart` to
///   `web/worker.dart.js` for web platform support.
/// - **locorda_mapping_bootstrap_generator:mapping_bootstrap**: Embeds TTL
///   mapping files as `const List<String>` for offline-first bootstrap loading.
/// - **locorda_rdf_mapper_generator**: Runs the RDF mapper generators
///   (cache, source, and init file builders).
///
/// Run `dart run build_runner build` or use watch mode:
/// `dart run build_runner watch`
library;
