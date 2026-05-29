import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/mapping/framework_iri_generator.dart';
import 'package:locorda_core/src/mapping/identified_blank_node_builder.dart';
import 'package:locorda_core/src/mapping/resource_locator.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';

class MetadataGenerator {
  final FrameworkIriGenerator _frameworkIriGenerator;

  MetadataGenerator({required FrameworkIriGenerator frameworkIriGenerator})
      : _frameworkIriGenerator = frameworkIriGenerator;

  Iterable<Node> createPropertyValueMetadata(
          IriTerm documentIri,
          IdTerm<RdfSubject> subject,
          RdfPredicate predicate,
          IdTerm<RdfObject> value,
          Iterable<Triple> Function(RdfSubject) createMetadataTriples) =>
      _createPropertyValueMetadata(documentIri, subject, createMetadataTriples,
          predicate: predicate, value: value);

  Iterable<Node> createPropertyMetadata(
          IriTerm documentIri,
          IdTerm<RdfSubject> subject,
          RdfPredicate predicate,
          Iterable<Triple> Function(RdfSubject) createMetadataTriples) =>
      _createPropertyValueMetadata(
        documentIri,
        subject,
        createMetadataTriples,
        predicate: predicate,
      );

  Iterable<Node> createResourceMetadata(
          IriTerm documentIri,
          IdTerm<RdfSubject> subject,
          Iterable<Triple> Function(RdfSubject) createMetadataTriples) =>
      _createPropertyValueMetadata(documentIri, subject, createMetadataTriples);

  /// Creates one or more `sync:PropertyStatement` framework metadata nodes
  /// for the `(subject, predicate)` slot, identified by `sync:resource` +
  /// `sync:property` (and stable across saves: identical `(s, p)` ⇒
  /// identical IRI ⇒ automatic deduplication via `sync:hasStatement`'s
  /// OR-Set merge).
  ///
  /// One node is produced per concrete IRI in [subject.localSubjectIris]
  /// (identified blank nodes expand to multiple canonical IRIs).
  ///
  /// `createMetadataTriples` receives the freshly minted statement subject
  /// (typed as `RdfSubject` so it can also be used as triple subject) and
  /// returns the variable metadata for this slot — most callers will emit
  /// a single `(stmt, crdt:vclk, V)` triple.
  Iterable<Node> createPropertyStatement(
    IriTerm documentIri,
    IdTerm<RdfSubject> subject,
    RdfPredicate predicate,
    Iterable<Triple> Function(RdfSubject) createMetadataTriples,
  ) {
    final expandedSubject = subject.localSubjectIris;
    final predicateIri = switch (predicate) { final IriTerm iri => iri };

    return expandedSubject.map((subj) {
      final stmtIri =
          _createPropertyStatementIri(documentIri, subj, predicateIri);
      final identifyingTriples = <Triple>[
        Triple(stmtIri, Rdf.type, SyncPropertyStatement.classIri),
        Triple(stmtIri, SyncPropertyStatement.resource, subj),
        Triple(stmtIri, SyncPropertyStatement.property, predicateIri),
      ];
      final metadataTriples = createMetadataTriples(stmtIri).toList();
      // Note: unlike createStatement* paths, blank-node objects ARE allowed
      // here — callers attach the immutable VersionedClock node via
      // crdt:vclk and its per-entry blank nodes inline so they ride along
      // when the PropertyStatement is materialised into the document graph.
      final graph =
          RdfGraph.fromTriples([...identifyingTriples, ...metadataTriples]);
      return (stmtIri, graph);
    });
  }

  IriTerm _createPropertyStatementIri(
    IriTerm documentIri,
    IriTerm subject,
    IriTerm predicate,
  ) {
    final temporaryIdSubject = BlankNodeTerm();
    final idGraph = RdfGraph.fromTriples([
      Triple(temporaryIdSubject, SyncPropertyStatement.resource, subject),
      Triple(temporaryIdSubject, SyncPropertyStatement.property, predicate),
    ]);
    return _frameworkIriGenerator.generateSimpleCanonicalIri(
        documentIri, 'prop', idGraph.triples,
        labels: {temporaryIdSubject: 'prop0'});
  }

  /// Public, deterministic IRI lookup for a `sync:PropertyStatement`,
  /// content-addressed over `(subject, predicate)`. Used by causality-tracking
  /// CRDT types to locate and garbage-collect stale framework metadata they
  /// previously emitted for the same `(s, p)` slot.
  IriTerm propertyStatementIriFor(
    IriTerm documentIri,
    IriTerm subject,
    RdfPredicate predicate,
  ) =>
      _createPropertyStatementIri(
        documentIri,
        subject,
        switch (predicate) { final IriTerm iri => iri },
      );

  /// Creates an immutable, content-addressed `crdt:VersionedClock` snapshot
  /// from the document's current HLC [entries].
  ///
  /// Identity hash: canonical N-Quads over the `(forClockEntry, logicalTime)`
  /// pairs sorted by `forClockEntry`. `physicalTime` is preserved as an
  /// annotation on each emitted entry (needed for concurrent tie-break) but
  /// is excluded from the hash — consistent with `crdt:clockHash` and
  /// necessary for cross-installation deduplication of identical logical
  /// vectors.
  ///
  /// Returns the vclk IRI and the full triples to attach to the document.
  /// Identical [entries] produce identical IRIs across calls, so emitting
  /// the same vclk multiple times in one save (or across saves) is safe
  /// under the OR-Set semantics of `sync:hasStatement`.
  ({IriTerm vclkIri, List<Triple> triples}) createVersionedClock(
    IriTerm documentIri,
    Iterable<({IriTerm forClockEntry, int logicalTime, int physicalTime})>
        entries,
  ) {
    if (entries.isEmpty) {
      throw ArgumentError('VersionedClock requires at least one entry');
    }
    // Stable order by forClockEntry IRI for both hash and emitted layout.
    final sorted = entries.toList()
      ..sort((a, b) => a.forClockEntry.value.compareTo(b.forClockEntry.value));

    // Build identification graph: deterministic blank-node labels per index,
    // only (forClockEntry, logicalTime) per entry — physicalTime is excluded.
    final idLabels = <BlankNodeTerm, String>{};
    final idTriples = <Triple>[];
    final tmpVclk = BlankNodeTerm();
    idLabels[tmpVclk] = 'vclk0';
    for (var i = 0; i < sorted.length; i++) {
      final entry = sorted[i];
      final entryBn = BlankNodeTerm();
      idLabels[entryBn] = 'vce$i';
      idTriples
        ..add(Triple(tmpVclk, CrdtVersionedClock.hasClockEntry, entryBn))
        ..add(Triple(entryBn, Crdt.forClockEntry, entry.forClockEntry))
        ..add(Triple(entryBn, CrdtClockEntry.logicalTime,
            LiteralTerm.integer(entry.logicalTime)));
    }
    final vclkIri = _frameworkIriGenerator.generateCanonicalIriFromGraph(
        documentIri, 'vclk', RdfGraph.fromTriples(idTriples),
        labels: idLabels);

    // Emit full triples (including physicalTime) with fresh blank nodes per
    // entry. Note: the vclk subject is the content-addressed IRI; only the
    // entry-level nodes remain anonymous (see <#versioned-clock> mapping:
    // disableBlankNodePathIdentification = true).
    final triples = <Triple>[
      Triple(vclkIri, Rdf.type, CrdtVersionedClock.classIri),
    ];
    for (final entry in sorted) {
      final entryBn = BlankNodeTerm();
      triples
        ..add(Triple(vclkIri, CrdtVersionedClock.hasClockEntry, entryBn))
        ..add(Triple(entryBn, Crdt.forClockEntry, entry.forClockEntry))
        ..add(Triple(entryBn, CrdtClockEntry.logicalTime,
            LiteralTerm.integer(entry.logicalTime)))
        ..add(Triple(entryBn, CrdtClockEntry.physicalTime,
            LiteralTerm.integer(entry.physicalTime)));
    }
    return (vclkIri: vclkIri, triples: triples);
  }

  Iterable<Node> _createPropertyValueMetadata(
    IriTerm documentIri,
    IdTerm<RdfSubject> subject,
    Iterable<Triple> Function(RdfSubject) createMetadataTriples, {
    RdfPredicate? predicate,
    IdTerm<RdfObject>? value,
  }) {
    final expandedSubject = subject.localSubjectIris;
    final List<RdfObject>? expandedObject = switch (value?.value) {
      final LiteralTerm lt => [lt],
      final IriTerm iri => [iri],
      final BlankNodeTerm ibn =>
        value!.identifiers ?? (throw UnidentifiedBlankNodeException(ibn)),
      null => null
    };

    /*
    Blank nodes can be represented by multiple IRIs, so we need to create
    all combinations of subject IRIs and object IRIs (if applicable), this
    will cause us to create multiple metadata graphs.
    */
    final graphs = expandedSubject.expand((subj) {
      return (expandedObject?.cast<RdfObject?>() ?? [null]).map((obj) {
        final stmtIri = createStatementIri(documentIri, subj,
            predicate: predicate, value: obj);
        final metadataTriples = createMetadataTriples(stmtIri);
        if (metadataTriples.any((m) => m.object is BlankNodeTerm)) {
          throw ArgumentError(
              'Metadata triples must not contain blank node objects: $metadataTriples');
        }
        final graph = RdfGraph.fromTriples([
          ..._createIdentifyingTriples(stmtIri, subj, predicate, obj),
          ...metadataTriples,
        ]);
        return (stmtIri, graph);
      });
    });

    return graphs;
  }

  IriTerm createStatementIri(
    IriTerm documentIri,
    IriTerm subject, {
    RdfPredicate? predicate,
    RdfObject? value,
  }) {
    final temporaryIdSubject = BlankNodeTerm();
    final idGraph = RdfGraph.fromTriples(_createIdentifyingTriples(
        temporaryIdSubject, subject, predicate, value));
    return _frameworkIriGenerator.generateSimpleCanonicalIri(
        documentIri, 'stmt', idGraph.triples,
        labels: {temporaryIdSubject: 'stmt0'});
  }

  List<Triple> _createIdentifyingTriples(RdfSubject idSubject, IriTerm subj,
      RdfPredicate? predicate, RdfObject? obj) {
    return [
      Triple(idSubject, RdfStatement.subject, subj),
      if (predicate != null)
        Triple(idSubject, RdfStatement.predicate,
            switch (predicate) { final IriTerm iri => iri }),
      if (obj != null) Triple(idSubject, RdfStatement.object, obj),
    ];
  }
}

extension IdTermSubjectExtension on IdTerm<RdfSubject> {
  List<IriTerm> get subjectIris {
    return switch (value) {
      final IriTerm iri => [iri],
      final BlankNodeTerm bn =>
        identifiers ?? (throw UnidentifiedBlankNodeException(bn)),
    };
  }

  List<IriTerm> get localSubjectIris {
    final result = subjectIris;
    if (!result.every(LocalResourceLocator.isLocalIri)) {
      throw ArgumentError(
          'Resource metadata cannot be created for local IRIs: $result');
    }
    return result;
  }
}

class IdTerm<T extends RdfTerm> {
  final T value;
  final List<IriTerm>? identifiers;

  IdTerm._(this.value, this.identifiers);

  factory IdTerm.create(
      T value, IdentifiedBlankNodes<IriTerm> identifiedBlankNodes) {
    return switch (value) {
      final BlankNodeTerm ibn => identifiedBlankNodes.hasIdentifiedNodes(ibn)
          ? IdTerm._(ibn as T, identifiedBlankNodes.getIdentifiedNodes(ibn))
          : IdTerm._(value, null),
      _ => IdTerm._(value, null)
    };
  }
  @override
  String toString() => 'IdentifiedOrTerm($value, $identifiers)';
}
