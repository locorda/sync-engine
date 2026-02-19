// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: unused_import, depend_on_referenced_packages, unnecessary_import, implementation_imports

/// Generated LocordaConfig from annotations.
///
/// All crdtMapping IRIs are static, app-owned, absolute IRIs
/// fully determined at compile time from annotation values.
library;

import 'dart:core';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_objects/locorda_objects.dart';
import 'package:locorda_rdf_core/src/graph/rdf_term.dart' as rdf_term;
import 'package:personal_notes_app/models/category.dart' as category;
import 'package:personal_notes_app/models/note.dart' as note;
import 'package:personal_notes_app/models/note_group_key.dart' as ngk;
import 'package:personal_notes_app/models/note_index_entry.dart' as nie;

LocordaConfig generateLocordaConfig() => LocordaConfig(
  resources: [
    ResourceConfig(
      type: category.Category,
      crdtMapping: Uri.parse(
        'https://locorda.dev/example/personal_notes_app/mappings/category-v1#',
      ),
      indices: [FullIndexConfig()],
    ),
    ResourceConfig(
      type: note.Note,
      crdtMapping: Uri.parse(
        'https://locorda.dev/example/personal_notes_app/mappings/note-v1#',
      ),
      indices: [
        GroupIndexConfig(
          ngk.NoteGroupKey,
          groupingProperties: [
            GroupingPropertyData(
              const rdf_term.IriTerm('https://schema.org/dateCreated'),
              transforms: [
                RegexTransformData(
                  r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*',
                  r'${1}-${2}',
                ),
              ],
            ),
          ],
          item: IndexItemConfig(nie.NoteIndexEntry, {
            const rdf_term.IriTerm('https://schema.org/name'),
            const rdf_term.IriTerm('https://schema.org/dateCreated'),
            const rdf_term.IriTerm('https://schema.org/dateModified'),
            const rdf_term.IriTerm('https://schema.org/keywords'),
          }),
        ),
      ],
    ),
  ],
);
