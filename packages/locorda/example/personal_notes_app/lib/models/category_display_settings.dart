/// Category display settings for UI presentation preferences.
library;

import 'package:locorda/annotations.dart';
import 'package:personal_notes_app/consts.dart';
import 'package:locorda_rdf_terms_core/xsd.dart';
import 'package:locorda_rdf_terms_core/rdfs.dart';
import 'package:locorda_rdf_terms_core/rdf.dart' show Rdf;
import 'package:locorda_rdf_terms_core/owl.dart';

/// Display settings for a category, demonstrating single-path-identified blank nodes.
///
/// This is a blank node that can only be reached via a single path from its
/// parent Category resource (Category → displaySettings).
///
/// Uses CRDT merge strategies:
/// - LWW-Register for color and icon (last writer wins)
///
@LocalResource(appVocab)
class CategoryDisplaySettings {
  /// Color for UI display (hex code, CSS color name, etc.)
  @RdfProperty.define(
    fragment: 'categoryColor',
    label: 'category color',
    comment:
        'A color code (hex, name, etc.) associated with a category for UI display purposes.',
    metadata: [
      (Rdfs.range, Xsd.string),
      (Rdf.type, Owl.DatatypeProperty),
    ],
  )
  @CrdtLwwRegister()
  final String? color;

  /// Icon for UI display (emoji, icon name, etc.)
  @RdfProperty.define(
    fragment: 'categoryIcon',
    label: 'category icon',
    comment:
        'An icon identifier or emoji associated with a category for UI display purposes.',
    metadata: [
      (Rdfs.range, Xsd.string),
      (Rdf.type, Owl.DatatypeProperty),
    ],
  )
  @CrdtLwwRegister()
  final String? icon;

  CategoryDisplaySettings({this.color, this.icon});

  CategoryDisplaySettings copyWith({String? color, String? icon}) {
    return CategoryDisplaySettings(
      color: color ?? this.color,
      icon: icon ?? this.icon,
    );
  }

  @override
  String toString() {
    return 'CategoryDisplaySettings(color: $color, icon: $icon)';
  }
}
