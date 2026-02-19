/// Index entry for Note resources containing lightweight header properties.
///
/// Index entries are used for efficient querying and on-demand sync scenarios.
/// They contain selected properties from the full Note resource plus metadata
/// like Hybrid Logical Clock hashes for change detection.
library;

import 'package:locorda_annotations/locorda_annotations.dart';
import 'package:personal_notes_app/models/note.dart';
import 'package:personal_notes_app/models/note_group_key.dart';
import 'package:locorda_rdf_mapper_annotations/annotations.dart';
import 'package:locorda_rdf_terms_schema/schema.dart';

/// Lightweight index entry for Note resources.
///
/// Contains essential properties for browsing and filtering notes without
/// loading the full note content. Used in index update streams and
/// on-demand sync scenarios.
///
/// No CRDT annotations needed for index entries, would be ignored anyways.
@IndexItem.groupIndex(NoteGroupKey, IndexItemIriStrategy(Note))
class NoteIndexEntry {
  /// Unique identifier for the note
  @RdfIriPart()
  final String id;

  /// Note title for display in lists
  @RdfProperty(SchemaNoteDigitalDocument.name)
  final String name;

  /// Creation date for sorting and grouping
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated)
  final DateTime dateCreated;

  /// Last modification time
  @RdfProperty(SchemaNoteDigitalDocument.dateModified)
  final DateTime dateModified;

  /// Keywords/tags for filtering
  @RdfProperty(SchemaNoteDigitalDocument.keywords)
  final Set<String> keywords;

  /// Category ID for grouping
  @NoteCategoryProperty()
  final String? categoryId;

  const NoteIndexEntry({
    required this.id,
    required this.name,
    required this.dateCreated,
    required this.dateModified,
    this.keywords = const {},
    this.categoryId,
  });

  @override
  String toString() =>
      'NoteIndexEntry(id: $id, name: $name, keywords: $keywords)';
}
