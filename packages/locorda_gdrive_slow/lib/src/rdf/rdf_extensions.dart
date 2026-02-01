import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/vocab/generated/rdf.dart';
import 'package:locorda_core/src/util/structure_validation_logger.dart';
import 'package:locorda_rdf_core/core.dart';

typedef Node = (RdfSubject node, RdfGraph triples);

extension RdfGraphExtensions on RdfGraph {
  static final empty = RdfGraph.fromTriples(const []);

  IriTerm getIdentifier(IriTerm type) {
    final localIdTriple = findTriples(predicate: Rdf.type, object: type).single;
    return localIdTriple.subject as IriTerm;
  }

  /// Returns single value if present, null if absent. No structural expectation.
  /// Use when the property is genuinely optional in the data model.
  T? findSingleObject<T extends RdfObject>(
          RdfSubject subject, RdfPredicate predicate) =>
      _findSingleObject(subject, predicate, expectSingle: false);

  /// Expects exactly one value, but returns null if absent/invalid.
  /// Use when the property SHOULD be present according to spec/schema,
  /// but you want to handle its absence gracefully.
  T? expectSingleObject<T extends RdfObject>(
          RdfSubject subject, RdfPredicate predicate,
          {ExpectationSeverity severity = ExpectationSeverity.major}) =>
      _findSingleObject(subject, predicate,
          expectSingle: true, severity: severity);

  T? _findSingleObject<T extends RdfObject>(
      RdfSubject subject, RdfPredicate predicate,
      {required bool expectSingle,
      ExpectationSeverity severity = ExpectationSeverity.major}) {
    final triples = findTriples(subject: subject, predicate: predicate);
    final it = triples.iterator;

    if (!it.moveNext()) {
      if (expectSingle) {
        expectationFailed(
          "Missing required single-valued property",
          subject: subject,
          predicate: predicate,
          graph: this,
          severity: severity,
        );
      }
      return null;
    }
    final first = it.current;

    if (it.moveNext()) {
      expectationFailed(
        "Multiple values for property that should have at most one",
        subject: subject,
        predicate: predicate,
        graph: this,
        severity: severity,
      );
      // In lenient mode: take first value
    }

    if (first.object is! T) {
      expectationFailed(
        "Unexpected object type ${first.object.runtimeType}, expected $T",
        subject: subject,
        predicate: predicate,
        graph: this,
        severity: severity,
      );
      return null;
    }
    return first.object as T;
  }

  Set<T> getMultiValueObjects<T extends RdfObject>(
      RdfSubject subject, RdfPredicate predicate) {
    final obj = findTriples(subject: subject, predicate: predicate);
    if (obj.isEmpty) {
      return {};
    }
    return obj.map((t) => t.object).whereType<T>().toSet();
  }
}

extension RdfTermExtensions on RdfTerm {
  bool get hasStringValue => switch (this) {
        LiteralTerm _ => true,
        IriTerm _ => true,
        BlankNodeTerm _ => false,
      };

  String get stringValue => switch (this) {
        LiteralTerm lt => lt.stringValue,
        IriTerm it => it.value,
        BlankNodeTerm _ => throw StateError('Blank nodes have no string value'),
      };
}

extension IriTermExtensions on IriTerm {
  // 'late final debug = _iriToDebugString(this);' would be much nicer,
  // but isn't supported yet in extension methods
  String get debug => _iriToDebugString(this);

  static String _iriToDebugString(IriTerm iri) {
    try {
      final rl = LocalResourceLocator(iriTermFactory: IriTerm.new);
      final r = rl.fromIriNoType(iri);
      final type =
          r.typeIri.value.startsWith('https://w3id.org/solid-crdt-sync/vocab/')
              ? r.typeIri.value
                  .substring('https://w3id.org/solid-crdt-sync/vocab/'.length)
                  .replaceAll('#', ':')
              : r.typeIri.value;
      return '<${type} | ${r.id}${r.fragment != null ? ' # ${r.fragment!}' : ''}>';
    } catch (_) {
      return iri.value;
    }
  }

  String get localName {
    final hashIndex = value.lastIndexOf('#');
    if (hashIndex != -1 && hashIndex <= value.length - 1) {
      return value.substring(hashIndex + 1);
    }
    final slashIndex = value.lastIndexOf('/');
    if (slashIndex != -1 && slashIndex <= value.length - 1) {
      return value.substring(slashIndex + 1);
    }
    return value; // Fallback to full IRI if no separator found
  }

  String get fragment {
    final hashIndex = value.lastIndexOf('#');
    if (hashIndex != -1 && hashIndex <= value.length - 1) {
      return value.substring(hashIndex + 1);
    }
    return ''; // Fallback to empty if no fragment found
  }

  IriTerm getDocumentIri([IriTermFactory iriFactory = IriTerm.validated]) {
    final hashIndex = value.lastIndexOf('#');
    if (hashIndex != -1) {
      return iriFactory(value.substring(0, hashIndex));
    }
    return this; // Fallback to self if no separator found
  }

  IriTerm withFragment(String fragment,
      {IriTermFactory iriTermFactory = IriTerm.validated}) {
    final hashIndex = value.lastIndexOf('#');
    if (hashIndex != -1) {
      return iriTermFactory(value.substring(0, hashIndex) + '#' + fragment);
    }
    return iriTermFactory(
        value + '#' + fragment); // Fallback to self if no separator found
  }
}
