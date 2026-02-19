/// Comment model representing a comment on a note.
library;

import 'package:locorda_rdf_mapper_annotations/annotations.dart';
import 'package:locorda_rdf_terms_schema/schema.dart';
import 'package:locorda_annotations/locorda_annotations.dart';

/// A comment attached to a note, demonstrating IRI-identified sub-content.
///
/// Comments are IRI-identified resources (not blank nodes) that can be
/// referenced independently and demonstrate sub-resource patterns.
///
/// Uses CRDT merge strategies:
/// - Immutable for createdAt (creation timestamp)
/// - LWW-Register for content (last writer wins)
///
@SubResource(Schema.Comment, SubIriStrategy("comment-{id}"))
class Comment {
  /// Unique identifier for this comment (IRI fragment)
  @RdfIriPart()
  final String id;

  /// Comment text content
  @RdfProperty(Schema.text)
  @CrdtLwwRegister()
  final String content;

  /// When this comment was created (immutable)
  @RdfProperty(Schema.dateCreated)
  @CrdtImmutable()
  final DateTime createdAt;

  Comment({required this.id, required this.content, DateTime? createdAt})
      : createdAt = createdAt ?? DateTime.now();

  Comment copyWith({String? id, String? content, DateTime? createdAt}) {
    return Comment(
      id: id ?? this.id,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  String toString() {
    return 'Comment(id: $id, content: ${content.substring(0, content.length > 20 ? 20 : content.length)}...)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Comment && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
