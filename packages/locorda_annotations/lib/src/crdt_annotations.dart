/// CRDT merge strategy annotations for RDF properties.
library;

/// Annotation for Last-Writer-Wins Register merge strategy.
///
/// Used for single-value properties where conflicts are resolved by
/// keeping the value with the most recent timestamp.
class CrdtLwwRegister {
  const CrdtLwwRegister();
}

/// Annotation for Observed-Remove Set merge strategy.
///
/// Used for multi-value properties where additions and removals
/// can happen independently and merge together.
class CrdtOrSet {
  const CrdtOrSet();
}

/// Annotation for immutable properties that never change.
///
/// Used for properties like creation timestamps that should
/// remain constant once set.
class CrdtImmutable {
  const CrdtImmutable();
}

/// Annotation to mark a property as identifying for a local resource (blank node).
///
/// Used to indicate that a property uniquely identifies a local resource,
/// allowing the CRDT system to recognize when two blank nodes represent
/// the same logical entity. This maps to `mc:isIdentifying` in the merge contract.
///
/// Example:
/// ```dart
/// @LocalResource()
/// class Weblink {
///   @RdfProperty(Schema.url)
///   @MergeIdentifying()
///   @CrdtImmutable()
///   final String url;
///   // ...
/// }
/// ```
class MergeIdentifying {
  const MergeIdentifying();
}
