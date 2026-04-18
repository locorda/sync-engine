import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/vocab/generated/rdf.dart';
import 'package:locorda_core/src/util/lru_cache.dart';
import 'package:locorda_core/src/util/structure_validation_logger.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_terms_core/xsd.dart';

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

  /// Returns the maximum datetime value from an OR_Set datetime property.
  ///
  /// Per spec (`core-v1.ttl`), lifecycle timestamps like `crdt:createdAt` and
  /// `crdt:deletedAt` use OR_Set semantics: after merging multiple peers,
  /// there can be multiple values. The correct effective value is the maximum:
  ///   document is deleted if max(deletedAt) > max(createdAt)
  ///
  /// Returns null if no values are present.
  LiteralTerm? findMaxDateTimeObject(
      RdfSubject subject, RdfPredicate predicate) {
    final triples = findTriples(subject: subject, predicate: predicate);
    LiteralTerm? maxValue;
    DateTime? maxDateTime;
    for (final triple in triples) {
      if (triple.object is! LiteralTerm) continue;
      final literal = triple.object as LiteralTerm;
      if (!literal.isDateTime) continue;
      final dt = literal.dateTimeValue;
      if (maxDateTime == null || dt.isAfter(maxDateTime)) {
        maxDateTime = dt;
        maxValue = literal;
      }
    }
    return maxValue;
  }

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
      final next = it.current;
      expectationFailed(
        "Multiple values for property that should have at most one. First value: ${first.object}, next value: ${next.object}",
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

  /**
   * Gets a list of RdfObjects from a rdf:List structure (e.g. rdf:first, rdf:rest, rdf:nil)
   */
  List<T> getListObjects<T extends RdfObject>(
      RdfSubject subject, RdfPredicate predicate) {
    final obj = findSingleObject(subject, predicate);
    if (!(obj is RdfSubject)) {
      return [];
    }
    return traverseListObjects<T>(obj);
  }

/*
* Gets a list of RdfObjects from a multi-valued property (i.e. multiple triples with the same predicate)
*/
  List<T> getMultiValueObjectList<T extends RdfObject>(
      RdfSubject subject, RdfPredicate predicate) {
    final obj = findTriples(subject: subject, predicate: predicate);
    if (obj.isEmpty) {
      return [];
    }
    return obj.map((t) => t.object).whereType<T>().toList();
  }

  Set<T> getMultiValueObjects<T extends RdfObject>(
      RdfSubject subject, RdfPredicate predicate) {
    final obj = findTriples(subject: subject, predicate: predicate);
    if (obj.isEmpty) {
      return {};
    }
    return obj.map((t) => t.object).whereType<T>().toSet();
  }

  List<T> traverseListObjects<T extends RdfObject>(RdfSubject listRoot) {
    if (listRoot == Rdf.nil) return [];
    return subgraph(listRoot, filter: (t, depth) {
      if (t.predicate == Rdf.rest) {
        if (t.object == Rdf.nil) {
          return TraversalDecision.skip;
        }
        return TraversalDecision.skipButDescend;
      }
      if (t.predicate == Rdf.first) {
        // the actual file
        return TraversalDecision.includeButDontDescend;
      }
      return TraversalDecision.skip;
    }).triples.map((t) => t.object).whereType<T>().toList();
  }

  RdfGraph withNodes(
      RdfSubject subject, RdfPredicate predicate, Iterable<Node> nodes) {
    final triples = List<Triple>.from(this.triples);
    for (final node in nodes) {
      {
        final (objectTerm, graph) = node;
        triples.add(Triple(
          subject,
          predicate,
          objectTerm,
        ));
        triples.addAll(graph.triples);
      }
    }
    return RdfGraph.fromTriples(triples);
  }
}

extension IriTermExtensions on IriTerm {
  static final LRUCache<IriTerm, String> _debugStringCache =
      LRUCache<IriTerm, String>(maxCacheSize: 100);

  // 'late final debug = _iriToDebugString(this);' would be much nicer,
  // but isn't supported yet in extension methods
  String get debug => _debugStringCache.putIfAbsent(this, _iriToDebugString);

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

extension RdfGraphIterableExtensions on Iterable<RdfGraph> {
  RdfGraph mergeGraphs() {
    return RdfGraph.fromTriples(expand((g) => g.triples));
  }
}

extension RdfNullableTermExtensions on RdfTerm? {
  String get debug {
    if (this == null) {
      return 'null';
    }
    return this!.debug;
  }
}

extension RdfTermExtensions on RdfTerm {
  String get debug {
    if (this is IriTerm) {
      return (this as IriTerm).debug;
    } else if (this is LiteralTerm) {
      final lit = this as LiteralTerm;
      return '"${lit.value}"^^<${lit.datatype.value}>';
    } else {
      return this.toString();
    }
  }

  bool get isLiteral {
    return this is LiteralTerm;
  }

  bool get isIri {
    return this is IriTerm;
  }

  bool get isBlankNode {
    return this is BlankNodeTerm;
  }

  bool get isNumeric {
    return this is LiteralTerm && (this as LiteralTerm).isNumeric;
  }

  num get numericValue {
    if (!isNumeric) {
      throw StateError('$this is not numeric');
    }
    return (this as LiteralTerm).numericValue;
  }

  bool get isDateTime {
    return this is LiteralTerm && (this as LiteralTerm).isDateTime;
  }

  DateTime get dateTimeValue {
    if (!isDateTime) {
      throw StateError('$this is not a dateTime');
    }
    return (this as LiteralTerm).dateTimeValue;
  }

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

extension LiteralTermExtensions on LiteralTerm {
  static LiteralTerm dateTime(DateTime dateTime) {
    return LiteralTerm(dateTime.toUtc().toIso8601String(),
        datatype: Xsd.dateTime);
  }

  static LiteralTerm dateTimeFromMillisecondsSinceEpoch(
      int millisecondsSinceEpoch) {
    return LiteralTerm(
        DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch)
            .toUtc()
            .toIso8601String(),
        datatype: Xsd.dateTime);
  }

  bool get isBoolean {
    return datatype == Xsd.boolean;
  }

  bool get booleanValue {
    if (!isBoolean) {
      throw StateError('Literal of type $datatype is not a boolean');
    }
    return value == 'true' || value == '1';
  }

  bool get isInteger {
    return datatype == Xsd.integer ||
        datatype == Xsd.int ||
        datatype == Xsd.long ||
        datatype == Xsd.short ||
        datatype == Xsd.byte ||
        datatype == Xsd.negativeInteger ||
        datatype == Xsd.nonNegativeInteger ||
        datatype == Xsd.nonPositiveInteger ||
        datatype == Xsd.positiveInteger ||
        datatype == Xsd.unsignedLong ||
        datatype == Xsd.unsignedInt ||
        datatype == Xsd.unsignedShort ||
        datatype == Xsd.unsignedByte;
  }

  int get integerValue {
    if (!isInteger) {
      throw StateError('Literal of type $datatype is not an integer');
    }
    return int.parse(value);
  }

  int? get tryIntegerValue {
    return int.tryParse(value);
  }

  bool get isString {
    return datatype == Xsd.string || datatype == Rdf.langString;
  }

  String get stringValue {
    if (!isString) {
      throw StateError('Literal of type $datatype is not a string');
    }
    return value;
  }

  double get doubleValue {
    if (!isDouble) {
      throw StateError('Literal of type $datatype is not a double or float');
    }
    return double.parse(value);
  }

  bool get isDouble {
    return datatype == Xsd.double ||
        datatype == Xsd.float ||
        datatype == Xsd.decimal;
  }

  bool get isNumeric {
    return isInteger || isDouble;
  }

  num get numericValue {
    if (isInteger) {
      return integerValue;
    } else if (isDouble) {
      return doubleValue;
    } else {
      throw StateError('Literal of type $datatype is not numeric');
    }
  }

  bool get isDateTime {
    return datatype == Xsd.dateTime;
  }

  DateTime get dateTimeValue {
    if (!isDateTime) {
      throw StateError('Literal of type $datatype is not a dateTime');
    }
    return DateTime.parse(value);
  }

  bool get isDate {
    return datatype == Xsd.date;
  }

  DateTime get dateValue {
    if (!isDate) {
      throw StateError('Literal of type $datatype is not a date');
    }
    return DateTime.parse(value);
  }
}

extension TripleListExtensions on List<Triple> {
  void addMultiple(
      RdfSubject subject, RdfPredicate predicate, Iterable<RdfObject> objects) {
    for (final object in objects) {
      add(Triple(subject, predicate, object));
    }
  }

  void addRdfList(
      RdfSubject subject, RdfPredicate predicate, List<RdfObject> items) {
    if (items.isEmpty) {
      add(Triple(subject, predicate, Rdf.nil));
      return;
    }

    // Create blank nodes for each list item
    final blankNodes = List.generate(items.length, (index) => BlankNodeTerm());

    for (var i = 0; i < items.length; i++) {
      final currentNode = blankNodes[i];
      final nextNode = (i < items.length - 1) ? blankNodes[i + 1] : Rdf.nil;

      // Add rdf:first triple
      add(Triple(currentNode, Rdf.first, items[i]));

      // Add rdf:rest triple
      add(Triple(currentNode, Rdf.rest, nextNode));
    }

    // Link the head of the list to the subject via the predicate
    add(Triple(subject, predicate, blankNodes.first));
  }

  void addNodes(
      RdfSubject subject, RdfPredicate predicate, Iterable<Node> nodes) {
    for (final node in nodes) {
      {
        final (objectTerm, graph) = node;
        add(Triple(
          subject,
          predicate,
          objectTerm,
        ));
        addAll(graph.triples);
      }
    }
  }

  RdfGraph toRdfGraph() {
    return RdfGraph.fromTriples(this);
  }
}

extension TripleSetExtensions on Set<Triple> {
  void addMultiple(
      RdfSubject subject, RdfPredicate predicate, Iterable<RdfObject> objects) {
    for (final object in objects) {
      add(Triple(subject, predicate, object));
    }
  }

  void addRdfList(
      RdfSubject subject, RdfPredicate predicate, List<RdfObject> items) {
    if (items.isEmpty) {
      add(Triple(subject, predicate, Rdf.nil));
      return;
    }

    // Create blank nodes for each list item
    final blankNodes = List.generate(items.length, (index) => BlankNodeTerm());

    for (var i = 0; i < items.length; i++) {
      final currentNode = blankNodes[i];
      final nextNode = (i < items.length - 1) ? blankNodes[i + 1] : Rdf.nil;

      // Add rdf:first triple
      add(Triple(currentNode, Rdf.first, items[i]));

      // Add rdf:rest triple
      add(Triple(currentNode, Rdf.rest, nextNode));
    }

    // Link the head of the list to the subject via the predicate
    add(Triple(subject, predicate, blankNodes.first));
  }

  void addNodes(
      RdfSubject subject, RdfPredicate predicate, Iterable<Node> nodes) {
    for (final node in nodes) {
      {
        final (objectTerm, graph) = node;
        add(Triple(
          subject,
          predicate,
          objectTerm,
        ));
        addAll(graph.triples);
      }
    }
  }

  RdfGraph toRdfGraph() {
    return RdfGraph.fromTriples(this);
  }
}
