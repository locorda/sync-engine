/// Personal Notes vocabulary constants for RDF type and property IRIs.
///
/// This demonstrates a simple approach for managing custom vocabulary IRIs
/// in example applications. For production applications, consider using
/// locorda_rdf_terms_generator to generate these constants from your .ttl files.
library;

import 'package:locorda_rdf_core/core.dart';
import '../consts.dart' show appBaseUrl;

/// Constants for the Personal Notes vocabulary.
///
/// This vocabulary is deployed at GitHub Pages and defines specialized
/// types for note organization that properly subclass Schema.org types.
class PersonalNotesVocab {
  /// Base IRI for the Personal Notes vocabulary
  static const baseIri = '$appBaseUrl/vocabulary/personal-notes#';

  // Classes

  /// A category for organizing personal notes.
  /// Subclass of schema:CreativeWork.
  // ignore: constant_identifier_names
  static const NotesCategory = IriTerm('${baseIri}NotesCategory');

  /// A personal note or memo.
  /// Subclass of schema:NoteDigitalDocument.
  // ignore: constant_identifier_names
  static const PersonalNote = IriTerm('${baseIri}PersonalNote');

  // ignore: constant_identifier_names
  static const Weblink = IriTerm('${baseIri}Weblink');

  // Properties

  /// Indicates that a note belongs to a specific notes category.
  /// Domain: PersonalNote, Range: NotesCategory
  static const belongsToCategory = IriTerm('${baseIri}belongsToCategory');

  /// A color code (hex, name, etc.) associated with a category for UI display.
  /// Domain: NotesCategory, Range: xsd:string
  static const categoryColor = IriTerm('${baseIri}categoryColor');

  /// An icon identifier or emoji associated with a category for UI display.
  /// Domain: NotesCategory, Range: xsd:string
  static const categoryIcon = IriTerm('${baseIri}categoryIcon');

  /// Indicates that a category is archived (soft deleted).
  /// Domain: NotesCategory, Range: xsd:boolean
  static const archived = IriTerm('${baseIri}archived');

  /// Display settings for a category (single-path-identified blank node).
  /// Domain: NotesCategory, Range: CategoryDisplaySettings (blank node)
  static const displaySettings = IriTerm('${baseIri}displaySettings');
}
