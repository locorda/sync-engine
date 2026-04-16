/// Simple Note model with CRDT annotations for offline-first sync.
library;

import 'package:locorda/annotations.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_terms_common/dcterms.dart';
import 'package:locorda_rdf_terms_core/owl.dart';
import 'package:locorda_rdf_terms_core/rdf.dart' show Rdf;
import 'package:locorda_rdf_terms_core/rdfs.dart';
import 'package:locorda_rdf_terms_schema/schema.dart';

import '../consts.dart' show appVocab, vocabNs;
import '../utils/optional.dart';
import 'category.dart';
import 'comment.dart';
import 'weblink.dart';

const _belongsToCategoryFragment = 'belongsToCategory';
const _belongsToCategoryIri = IriTerm('$vocabNs$_belongsToCategoryFragment');

class NoteCategoryProperty extends RdfProperty {
  const NoteCategoryProperty.ref()
      : super(
          _belongsToCategoryIri,
          iri: const RootResourceRef(Category),
        );

  const NoteCategoryProperty()
      : super.define(
          iri: const RootResourceRef(Category),
          fragment: _belongsToCategoryFragment,
          label: 'belongs to category',
          comment:
              'Indicates that a note belongs to a specific notes category.',
          metadata: const [
            (Rdf.type, Owl.ObjectProperty),
            (Rdfs.subPropertyOf, Dcterms.subject),
            // TODO: this is a bit hacky, but
            // both our :Note and our :NoteIndexEntry types
            // are using this property - not sure what the correct
            // way to handle this is. Should the NoteIndexEntry
            // dart class rather use the rdf type of the Note class?
            // How do we express that with generated vocabulary?
            // For now we just put the property on the common super class...
            (Rdfs.domain, SchemaNoteDigitalDocument.classIri),
            (
              Rdfs.range,
              IriTerm(
                  'https://locorda.dev/example/personal_notes_app/vocabulary/personal-notes#Category')
            ),
          ],
        );
}

/// A personal note with title, content, and tags.
///
/// Uses our custom PersonalNote type that specializes schema:NoteDigitalDocument
/// for personal note-taking use cases, following ADR-0002 guidance.
///
/// Uses CRDT merge strategies:
/// - LWW-Register for title and content (last writer wins)
/// - OR-Set for tags (additions and removals merge)
///
@RootResource(
  appVocab,
  mergeContract: MergeContract(
    label: 'Personal Note CRDT Document Mapping v1',
    comment:
        'Defines how personal notes should merge when conflicts occur during sync.',
  ),
  comment:
      'A personal note or memo. Specializes schema:NoteDigitalDocument for personal note-taking use cases.',
  label: 'Personal Note',
  // we could also use the default iriStrategy, but we want to
  // use `note` instead of `it` for the fragment.
  iriStrategy: RootIriStrategy(RootIriConfig('note')),
  fullIndex: FullIndex.disabled(),
  subClassOf: SchemaNoteDigitalDocument.classIri,
)
class Note {
  /// Unique identifier for this note
  @RdfIriPart()
  final String id;

  /// Note title - last writer wins on conflicts
  @RdfProperty(SchemaNoteDigitalDocument.name)
  @CrdtLwwRegister()
  final String title;

  /// Note content - last writer wins on conflicts
  @RdfProperty(SchemaNoteDigitalDocument.text)
  @CrdtLwwRegister()
  final String content;

  /// Tags that can be added/removed independently
  @RdfProperty(SchemaNoteDigitalDocument.keywords)
  @CrdtOrSet()
  final Set<String> tags;

  /// Category this note belongs to - last writer wins on conflicts
  @NoteCategoryProperty()
  @CrdtLwwRegister()
  final String? categoryId;

  /// When this note was created
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated)
  @CrdtImmutable()
  final DateTime createdAt;

  /// When this note was last modified
  @RdfProperty(SchemaNoteDigitalDocument.dateModified)
  @CrdtLwwRegister()
  final DateTime modifiedAt;

  /// Weblinks referenced by this note (identified blank nodes)
  @RdfProperty(Schema.relatedLink)
  @CrdtOrSet()
  final Set<Weblink> weblinks;

  /// Comments on this note (IRI-identified sub-resources)
  @RdfProperty(SchemaNoteDigitalDocument.comment)
  @CrdtOrSet()
  final Set<Comment> comments;

  /// Catch-all for unmapped triples added by other apps/extensions/versions.
  /// Persisted as Turtle in the database for lossless RDF round-tripping.
  @RdfUnmappedTriples(globalUnmapped: true)
  final RdfGraph other;

  Note({
    required this.id,
    required this.title,
    required this.content,
    Set<String>? tags,
    this.categoryId,
    DateTime? createdAt,
    DateTime? modifiedAt,
    Set<Weblink>? weblinks,
    Set<Comment>? comments,
    RdfGraph? other,
  })  : tags = tags ?? <String>{},
        weblinks = weblinks ?? <Weblink>{},
        comments = comments ?? <Comment>{},
        createdAt = createdAt ?? DateTime.now(),
        modifiedAt = modifiedAt ?? DateTime.now(),
        other = other ?? RdfGraph();

  /// Create a copy of this note with updated fields
  Note copyWith({
    String? id,
    String? title,
    String? content,
    Set<String>? tags,
    Optional<String>? categoryId,
    DateTime? createdAt,
    DateTime? modifiedAt,
    Set<Weblink>? weblinks,
    Set<Comment>? comments,
  }) {
    return Note(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      tags: tags ?? Set.from(this.tags),
      categoryId: categoryId != null ? categoryId.value : this.categoryId,
      createdAt: createdAt ?? this.createdAt,
      modifiedAt: modifiedAt ?? DateTime.now(),
      weblinks: weblinks ?? Set.from(this.weblinks),
      comments: comments ?? Set.from(this.comments),
      other: other,
    );
  }

  @override
  String toString() {
    return 'Note(id: $id, title: $title, tags: ${tags.length})';
  }
}
