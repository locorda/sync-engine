/// Locorda annotations for model classes.
///
/// Import this in your model classes to use sync annotations:
///
/// ```dart
/// import 'package:locorda/annotations.dart';
///
/// @RootResource(AppVocab(appBaseUri: 'https://example.com/app'))
/// class MyModel {
///   @RdfIriPart()
///   final String id;
///   final String name;
/// }
/// ```
library locorda.annotations;

// Locorda-specific annotations
export 'package:locorda_annotations/locorda_annotations.dart';

// RDF mapper annotations (re-exported for convenience)
export 'package:locorda_rdf_mapper_annotations/annotations.dart';
