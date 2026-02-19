/// Category model for organizing notes with CRDT annotations.
library;

import 'package:locorda/annotations.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_terms_core/owl.dart';
import 'package:locorda_rdf_terms_core/rdf.dart' show Rdf;
import 'package:locorda_rdf_terms_core/rdfs.dart';
import 'package:locorda_rdf_terms_core/xsd.dart';
import 'package:locorda_rdf_terms_schema/schema.dart';

import '../consts.dart' show appVocab;
import 'category_display_settings.dart';

/// A category for organizing personal notes.
///
/// Uses our custom vocabulary that properly specializes schema:CreativeWork
/// for note categorization, following ADR-0002 guidance for specific types.
///
/// Uses CRDT merge strategies:
/// - LWW-Register for name and description (last writer wins)
/// - Immutable for creation date
///
@RootResource(
  appVocab,
  mergeContract: MergeContract(
    label: 'Notes Category CRDT Document Mapping v1',
    comment:
        'Defines how note categories should merge when conflicts occur during sync.',
  ),
  label: 'Notes Category',
  comment:
      'A category for organizing personal notes. Provides a more specific classification than schema:CreativeWork for note organization purposes.',
  subClassOf: SchemaCreativeWork.classIri,
)
class Category {
  /// Unique identifier for this category
  @RdfIriPart()
  final String id;

  /// Category name - last writer wins on conflicts
  @RdfProperty(SchemaCreativeWork.name)
  @CrdtLwwRegister()
  final String name;

  /// Optional description - last writer wins on conflicts
  @RdfProperty(SchemaCreativeWork.description)
  @CrdtLwwRegister()
  final String? description;

  /// Display settings for UI presentation (single-path-identified blank node)
  @RdfProperty.define(
    fragment: 'displaySettings',
    metadata: [
      (Rdf.type, Owl.ObjectProperty),
    ],
  )
  @CrdtLwwRegister()
  final CategoryDisplaySettings? settings;

  /// When this category was created
  @RdfProperty(SchemaCreativeWork.dateCreated)
  @CrdtImmutable()
  final DateTime createdAt;

  /// When this category was last modified
  @RdfProperty(SchemaCreativeWork.dateModified)
  @CrdtLwwRegister()
  final DateTime modifiedAt;

  /// Whether this category is archived (soft deleted)
  @RdfProperty.define(
    fragment: 'archived',
    label: 'archived',
    comment:
        'Indicates that a category is archived (soft deleted) but remains referenceable.',
    metadata: [
      (Rdfs.range, Xsd.boolean),
      (Rdf.type, Owl.DatatypeProperty),
    ],
  )
  @CrdtLwwRegister()
  final bool archived;

  @RdfUnmappedTriples(globalUnmapped: true)
  final RdfGraph other;

  Category({
    required this.id,
    required this.name,
    this.description,
    this.settings,
    DateTime? createdAt,
    DateTime? modifiedAt,
    this.archived = false,
    RdfGraph? other,
  })  : createdAt = createdAt ?? DateTime.now(),
        modifiedAt = modifiedAt ?? DateTime.now(),
        other = other ?? RdfGraph();

  /// Create a copy of this category with updated fields
  Category copyWith({
    String? id,
    String? name,
    String? description,
    CategoryDisplaySettings? settings,
    DateTime? createdAt,
    DateTime? modifiedAt,
    bool? archived,
  }) {
    return Category(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      settings: settings ?? this.settings,
      createdAt: createdAt ?? this.createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      archived: archived ?? this.archived,
      other: other,
    );
  }

  @override
  String toString() {
    return 'Category(id: $id, name: $name)';
  }
}
