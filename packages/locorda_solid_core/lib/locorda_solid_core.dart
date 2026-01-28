/// Solid Pod backend implementation for locorda CRDT synchronization.
///
/// This library provides the Solid Pod backend implementation for syncing
/// RDF data using CRDT (Conflict-free Replicated Data Types).
///
/// Usage:
/// ```dart
/// final backend = SolidBackend(authProvider: myAuthProvider);
/// ```
library locorda_solid;

export 'src/solid_backend.dart';
export 'src/auth/solid_auth_provider.dart';
