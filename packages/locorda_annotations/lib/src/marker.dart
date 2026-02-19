/// Marker interface for top-level Locorda annotations.
library;

/// Marker interface for class-level Locorda annotations.
///
/// Classes implementing this interface are designed to be used as
/// **class-level annotations** (e.g., `@RootResource`, `@GroupKey`).
///
/// This distinguishes them from:
/// - **Parameter classes** like [FullIndex] or [MergeContract] (passed as constructor arguments)
/// - **Property-level annotations** like `@CrdtLwwRegister` or `@RdfProperty` (applied to fields)
///
/// ## Usage
///
/// **✅ Class-level annotations** (implement this interface):
/// ```dart
/// @RootResource(...)  // ← Annotation (implements LocordaAnnotation)
/// class Note { }
///
/// @GroupKey(...)      // ← Annotation (implements LocordaAnnotation)
/// class NoteGroupKey { }
/// ```
///
/// **❌ Parameter classes** (do NOT implement this interface):
/// ```dart
/// @RootResource(
///   classIri,
///   MergeContract(...),  // ← Parameter class
///   fullIndex: FullIndex(...),  // ← Parameter class
/// )
/// class Note { }
/// ```
///
/// **❌ Property-level annotations** (do NOT implement this interface):
/// ```dart
/// @RootResource(...)
/// class Note {
///   @CrdtLwwRegister()  // ← Property annotation (different scope)
///   String? title;
/// }
/// ```
///
/// This design makes the API boundaries explicit and enables tooling
/// to programmatically distinguish between annotation types.
abstract interface class LocordaAnnotation {
  const LocordaAnnotation();
}
