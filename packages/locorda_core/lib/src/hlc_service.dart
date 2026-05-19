/// Main facade for the CRDT sync system.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';

/// Factory function for generating physical timestamps (wall-clock time)
typedef PhysicalTimestampFactory = DateTime Function();

// Default factory functions for time and clock generation
DateTime defaultPhysicalTimestampFactory() => DateTime.now();

typedef CrdtClock = List<Node>;
typedef CurrentCrdtClock = ({
  /// Will be 0 if no existing clock entry for us
  int logicalTime,

  /// Will be 0 if no existing clock entry for us
  int physicalTime,
  CrdtClock fullClock,
  String hash
});

class HlcService {
  final String _installationLocalId;
  final PhysicalTimestampFactory _physicalTimestampFactory;

  HlcService({
    required String installationLocalId,
    required PhysicalTimestampFactory physicalTimestampFactory,
  })  : _installationLocalId = installationLocalId,
        _physicalTimestampFactory = physicalTimestampFactory;

  /// Generates a stable clock entry IRI based on installation localId
  /// Fragment format: #lcrd-clk-md5-{hash-of-installation-localId}
  IriTerm _generateClockEntryIri(IriTerm documentIri) {
    final hash = md5.convert(utf8.encode(_installationLocalId)).toString();
    return documentIri.withFragment('lcrd-clk-md5-$hash');
  }

  /// Builds a clock entry node as an IRI resource (not blank node)
  /// Note: installationIri property is NOT added here - it's added during sync
  Node _buildClockEntryNode(
      IriTerm documentIri, int physicalTime, int logicalTime,
      {List<Triple> extra = const []}) {
    final clockEntryIri = _generateClockEntryIri(documentIri);
    final triples = <Triple>[
      Triple(
        clockEntryIri,
        CrdtClockEntry.logicalTime,
        LiteralTerm.integer(logicalTime),
      ),
      Triple(
        clockEntryIri,
        CrdtClockEntry.physicalTime,
        LiteralTerm.integer(physicalTime),
      ),
      ...extra,
    ];
    return (clockEntryIri, RdfGraph.fromTriples(triples));
  }

  CrdtClock _extractCrdtClock(RdfGraph oldGraph, IriTerm documentIri) {
    final clockEntries = oldGraph
        .findTriples(
            subject: documentIri,
            predicate: SyncManagedDocument.crdtHasClockEntry)
        .map((t) => t.object as RdfSubject);
    return clockEntries.map((clockEntrySubject) {
      final graph = oldGraph.matching(subject: clockEntrySubject);
      return (clockEntrySubject, graph);
    }).toList();
  }

  CurrentCrdtClock createOrIncrementClock(
    RdfGraph? document,
    IriTerm documentIri, {
    int? physicalTime,
    int? logicalTime,
  }) {
    final existingClock =
        document == null ? null : _extractCrdtClock(document, documentIri);
    if (existingClock == null || existingClock.isEmpty) {
      return _newClock(documentIri,
          physicalTime: physicalTime, logicalTime: logicalTime);
    }
    return _incrementClock(documentIri, existingClock,
        physicalTime: physicalTime);
  }

/*
// Important: this throws away additional triples from clock entries - this probably
// needs to be handled outside of this function
  CurrentCrdtClock mergeRawClock(
      IriTerm documentIri, CurrentCrdtClock clock1, CurrentCrdtClock clock2) {
    final mergedEntries = <Node>{};
    // Merge entries by taking max logical and physical times
    final entryMap = <IriTerm, ({int logicalTime, int physicalTime})>{};

    for (final (node, graph) in [...clock1.fullClock, ...clock2.fullClock]) {
      final logicalTime = graph
          .findSingleObject<LiteralTerm>(node, CrdtClockEntry.logicalTime)
          ?.integerValue;
      final physicalTime = graph
          .findSingleObject<LiteralTerm>(node, CrdtClockEntry.physicalTime)
          ?.integerValue;

      if (logicalTime != null && physicalTime != null) {
        final existing = entryMap[node as IriTerm];
        if (existing == null) {
          entryMap[node] =
              (logicalTime: logicalTime, physicalTime: physicalTime);
        } else {
          entryMap[node] = (
            logicalTime: logicalTime > existing.logicalTime
                ? logicalTime
                : existing.logicalTime,
            physicalTime: physicalTime > existing.physicalTime
                ? physicalTime
                : existing.physicalTime,
          );
        }
      }
    }

    // Build merged clock entries
    for (final entry in entryMap.entries) {
      final (logicalTime: logicalTime, physicalTime: physicalTime) =
          entry.value;
      mergedEntries
          .add(_buildClockEntryNode(entry.key, physicalTime, logicalTime));
    }

    // Compute new hash
    final mergedClock = mergedEntries.toList();
    final newHash = _hashClock(mergedClock);

    final (logicalTime: logicalTime, physicalTime: physicalTime) =
        _getOurTime(documentIri, mergedClock);

    return (
      logicalTime: logicalTime,
      physicalTime: physicalTime,
      fullClock: mergedClock,
      hash: newHash
    );
  }
*/
  CurrentCrdtClock getCurrentClock(RdfGraph document, IriTerm documentIri) {
    final existingClock = _extractCrdtClock(document, documentIri);
    if (existingClock.isEmpty) {
      throw StateError(
          'No existing CRDT clock found in document ${documentIri.debug}');
    }

    final (logicalTime: logicalTime, physicalTime: physicalTime) =
        _getOurTime(documentIri, existingClock);

    return (
      logicalTime: logicalTime,
      physicalTime: physicalTime,
      fullClock: existingClock,
      hash: _hashClock(existingClock)
    );
  }

  ({int logicalTime, int physicalTime}) _getOurTime(
      IriTerm documentIri, CrdtClock clock) {
    final ourClockEntryIri = _generateClockEntryIri(documentIri);
    final ourEntry = clock
        .where((entry) {
          final (node, _) = entry;
          return node == ourClockEntryIri;
        })
        .map<RdfGraph>((e) => e.$2)
        .singleOrNull;
    final logicalTime = ourEntry
        ?.findSingleObject<LiteralTerm>(
            ourClockEntryIri, CrdtClockEntry.logicalTime)
        ?.integerValue;
    final physicalTime = ourEntry
        ?.findSingleObject<LiteralTerm>(
            ourClockEntryIri, CrdtClockEntry.physicalTime)
        ?.integerValue;

    return (
      logicalTime: logicalTime ?? 0,
      physicalTime: physicalTime ?? 0,
    );
  }

  CurrentCrdtClock _newClock(IriTerm documentIri,
      {int? physicalTime, int? logicalTime}) {
    physicalTime ??= _physicalTimestampFactory().millisecondsSinceEpoch;
    logicalTime ??= 1;

    final fullClock = [
      _buildClockEntryNode(documentIri, physicalTime, logicalTime)
    ];
    return (
      logicalTime: logicalTime,
      physicalTime: physicalTime,
      fullClock: fullClock,
      hash: _hashClock(fullClock)
    );
  }

  CurrentCrdtClock _incrementClock(IriTerm documentIri, CrdtClock clock,
      {int? physicalTime}) {
    physicalTime ??= _physicalTimestampFactory().millisecondsSinceEpoch;
    final ourClockEntryIri = _generateClockEntryIri(documentIri);

    final (ours: ours, theirs: theirs) =
        clock.fold((ours: <Node>[], theirs: <Node>[]), (acc, entry) {
      final (node, triples) = entry;
      if (node == ourClockEntryIri) {
        acc.ours.add(entry);
      } else {
        acc.theirs.add(entry);
      }
      return acc;
    });
    final Node entry;
    final int logicalTime;
    if (ours.isNotEmpty) {
      final ourClockEntry = ours.single;
      final oldLogicalTime = ourClockEntry.$2.findSingleObject<LiteralTerm>(
          ourClockEntry.$1, CrdtClockEntry.logicalTime)!;
      final extraTriples = ourClockEntry.$2.triples.where((triple) {
        return triple.predicate != CrdtClockEntry.logicalTime &&
            triple.predicate != CrdtClockEntry.physicalTime;
      }).toList();
      logicalTime = oldLogicalTime.integerValue + 1;
      entry = _buildClockEntryNode(documentIri, physicalTime, logicalTime,
          extra: extraTriples);
    } else {
      logicalTime = 1;
      entry = _buildClockEntryNode(documentIri, physicalTime, logicalTime);
    }

    final fullClock = [entry, ...theirs];

    return (
      logicalTime: logicalTime,
      physicalTime: physicalTime,
      fullClock: fullClock,
      hash: _hashClock(fullClock)
    );
  }

  /// Computes clock hash from logical time only.
  ///
  /// Physical time is excluded as it's merely an annotation for tie-breaking
  /// when logical times are concurrent. The logical time alone defines the
  /// causal state of the document - two documents with identical logical clocks
  /// are causally identical regardless of their physical timestamps.
  ///
  /// Per spec: includes only logicalTime triples, excludes physicalTime and installationIri.
  String _hashClock(CrdtClock clock) {
    final triples = <Triple>[];

    // Extract ONLY logicalTime triples from all clock entries
    for (final (_, graph) in clock) {
      triples.addAll(graph.findTriples(predicate: CrdtClockEntry.logicalTime));
    }

    // Serialize to canonical N-Quads
    final dataset = RdfDataset.fromDefaultGraph(RdfGraph.fromTriples(triples));
    final nquadsEncoder = NQuadsEncoder(
      options: const NQuadsEncoderOptions(canonical: true),
    );
    final nquads =
        nquadsEncoder.encode(dataset, generateNewBlankNodeLabels: false);

    // Compute MD5 hash
    return md5.convert(utf8.encode(nquads)).toString();
  }
}
