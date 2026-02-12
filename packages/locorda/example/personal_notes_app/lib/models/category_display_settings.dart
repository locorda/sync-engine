/// Category display settings for UI presentation preferences.
library;

import 'package:locorda_rdf_mapper_annotations/annotations.dart';
import 'package:locorda_annotations/locorda_annotations.dart';
import '../vocabulary/personal_notes_vocab.dart';

/// Display settings for a category, demonstrating single-path-identified blank nodes.
///
/// This is a blank node that can only be reached via a single path from its
/// parent Category resource (Category → displaySettings).
///
/// Uses CRDT merge strategies:
/// - LWW-Register for color and icon (last writer wins)
///
@RdfLocalResource()
class CategoryDisplaySettings {
  /// Color for UI display (hex code, CSS color name, etc.)
  @RdfProperty(PersonalNotesVocab.categoryColor)
  @CrdtLwwRegister()
  final String? color;

  /// Icon for UI display (emoji, icon name, etc.)
  @RdfProperty(PersonalNotesVocab.categoryIcon)
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
