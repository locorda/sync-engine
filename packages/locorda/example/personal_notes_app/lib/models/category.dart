/// Category model for organizing notes with CRDT annotations.
library;

import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_mapper_annotations/annotations.dart';
import 'package:locorda_rdf_terms_schema/schema.dart';
import 'package:locorda_annotations/locorda_annotations.dart';
import '../vocabulary/personal_notes_vocab.dart';
import '../consts.dart' show appBaseUrl;
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
@RootResource.externalVocab(
  PersonalNotesVocab.NotesCategory,
  appBaseUrl,
  mergeContractPath: '/contracts/category-v1',
  mergeContractLabel: 'Notes Category CRDT Document Mapping v1',
  mergeContractComment:
      'Defines how note categories should merge when conflicts occur during sync.',
  mergeContractImports: const [
    MergeContracts.coreV1,
  ],
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
  @RdfProperty(PersonalNotesVocab.displaySettings)
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
  @RdfProperty(PersonalNotesVocab.archived)
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
