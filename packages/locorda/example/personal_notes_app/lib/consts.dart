import 'package:locorda/annotations.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_terms_common/dcterms.dart';
import 'package:locorda_rdf_terms_core/xsd.dart';
import 'package:locorda_rdf_terms_core/owl.dart';

const appVocab = AppVocab(
  appBaseUri: appBaseUri,
  vocabPath: vocabPath,
  label: 'Personal Notes App Vocabulary',
  comment:
      'A vocabulary for personal note-taking applications with categories and organization features.',
  metadata: [
    (Dcterms.created, LiteralTerm.withDatatype('2026-02-19', Xsd.date)),
    (Dcterms.creator, LiteralTerm('Locorda Example Team')),
    (Owl.versionInfo, LiteralTerm('1.0.0')),
  ],
);

const appBaseUri = 'https://locorda.dev/example/personal_notes_app';
const vocabPath = '/vocabulary/personal-notes';
const vocabNs = '$appBaseUri$vocabPath#';
