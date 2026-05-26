// Copyright (c) 2025, Klas Kalaß <habbatical@gmail.com>
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

/// Per-property change clock metadata used to scope LWW concurrent merges.
library;

/// When a LWW property is modified locally, the merger records a
/// `sync:PropertyClock` framework node into the managed document. Each
/// node captures the Hybrid Logical Clock (HLC) of the modifying
/// installation at the time of the change, together with the set of
/// (resource, property) pairs the installation modified in that save.
///
/// During remote merge, when document-level clocks are concurrent, these
/// records allow the merger to resolve **each LWW property independently**
/// instead of falling back to a single document-level physical-time tie
/// break, which would otherwise revert uncontested properties to their
/// pre-divergence values.
///
/// One record is emitted per (resource, installation, logicalTime). The
/// `changedProperty` list groups all properties touched in the same save
/// so the HLC snapshot is only stored once.
///
/// RDF shape:
/// ```turtle
/// <doc> sync:hasPropertyClock <pc-iri> .
/// <pc-iri> a sync:PropertyClock ;
///     sync:resource <S> ;
///     crdt:hasClockEntry <ce-iri> ;       # references a clock entry IRI inside this doc
///     crdt:logicalTime 4 ;                # snapshot of the entry's HLC at change time
///     crdt:physicalTime 1704074400000 ;
///     sync:changedProperty schema:name, schema:description .
/// ```
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_rdf_core/core.dart';

/// New vocabulary terms for per-property change tracking. These are part
/// of the sync vocabulary (see `spec/vocabularies/sync.ttl`).
class SyncPropertyClock {
  SyncPropertyClock._();

  /// Class IRI for `sync:PropertyClock`.
  static const classIri = IriTerm(
    'https://w3id.org/solid-crdt-sync/vocab/sync#PropertyClock',
  );

  /// Predicate linking a managed document to its property clock records.
  static const hasPropertyClock = IriTerm(
    'https://w3id.org/solid-crdt-sync/vocab/sync#hasPropertyClock',
  );

  /// Predicate identifying the RDF resource the recorded changes apply to.
  static const resource = IriTerm(
    'https://w3id.org/solid-crdt-sync/vocab/sync#resource',
  );

  /// Predicate listing the (LWW) property IRIs modified in this save.
  /// Multi-valued — multiple properties changed together share one record.
  static const changedProperty = IriTerm(
    'https://w3id.org/solid-crdt-sync/vocab/sync#changedProperty',
  );
}

/// In-memory representation of a `sync:PropertyClock` record.
class PropertyClock {
  /// IRI of the PropertyClock metadata node itself (`#lcrd-pc-md5-...`).
  final IriTerm clockIri;

  /// Resource the changes apply to.
  final IriTerm resource;

  /// Clock entry IRI of the modifying installation within this document
  /// (same IRI used by `crdt:hasClockEntry` in the document clock).
  final IriTerm clockEntryIri;

  /// HLC logical time snapshot at the moment of the recorded change.
  final int logicalTime;

  /// HLC physical time snapshot at the moment of the recorded change.
  final int physicalTime;

  /// Set of properties modified by this installation in this save.
  final Set<IriTerm> changedProperties;

  const PropertyClock({
    required this.clockIri,
    required this.resource,
    required this.clockEntryIri,
    required this.logicalTime,
    required this.physicalTime,
    required this.changedProperties,
  });

  /// Serializes this PropertyClock as RDF triples (including the document
  /// link `<doc> sync:hasPropertyClock <pc-iri>`).
  Iterable<Triple> toTriples(IriTerm documentIri) sync* {
    yield Triple(
        documentIri, SyncPropertyClock.hasPropertyClock, clockIri);
    yield Triple(clockIri, Rdf.type, SyncPropertyClock.classIri);
    yield Triple(clockIri, SyncPropertyClock.resource, resource);
    yield Triple(clockIri, CrdtClockEntry.hasClockEntry, clockEntryIri);
    yield Triple(clockIri, CrdtClockEntry.logicalTime,
        LiteralTerm.integer(logicalTime));
    yield Triple(clockIri, CrdtClockEntry.physicalTime,
        LiteralTerm.integer(physicalTime));
    for (final prop in changedProperties) {
      yield Triple(clockIri, SyncPropertyClock.changedProperty, prop);
    }
  }

  /// Compares HLC snapshots, returning `> 0` if this is newer than [other],
  /// `< 0` if older, `0` if equal. Logical time dominates, physical time
  /// is the tie-breaker.
  int compareHlc(PropertyClock other) {
    if (logicalTime != other.logicalTime) {
      return logicalTime.compareTo(other.logicalTime);
    }
    return physicalTime.compareTo(other.physicalTime);
  }
}

/// Parses all `sync:PropertyClock` records from a managed document graph.
List<PropertyClock> parsePropertyClocks(
    IriTerm documentIri, RdfGraph document) {
  final result = <PropertyClock>[];
  for (final t in document.findTriples(
      subject: documentIri, predicate: SyncPropertyClock.hasPropertyClock)) {
    final clockIri = t.object;
    if (clockIri is! IriTerm) continue;
    final resource = document
        .findTriples(subject: clockIri, predicate: SyncPropertyClock.resource)
        .map((t) => t.object)
        .whereType<IriTerm>()
        .firstOrNull;
    final clockEntry = document
        .findTriples(
            subject: clockIri, predicate: CrdtClockEntry.hasClockEntry)
        .map((t) => t.object)
        .whereType<IriTerm>()
        .firstOrNull;
    if (resource == null || clockEntry == null) continue;
    final logical = document
        .findTriples(
            subject: clockIri, predicate: CrdtClockEntry.logicalTime)
        .map((t) => t.object)
        .whereType<LiteralTerm>()
        .firstOrNull;
    final physical = document
        .findTriples(
            subject: clockIri, predicate: CrdtClockEntry.physicalTime)
        .map((t) => t.object)
        .whereType<LiteralTerm>()
        .firstOrNull;
    if (logical == null || physical == null) continue;
    final props = document
        .findTriples(
            subject: clockIri,
            predicate: SyncPropertyClock.changedProperty)
        .map((t) => t.object)
        .whereType<IriTerm>()
        .toSet();
    result.add(PropertyClock(
      clockIri: clockIri,
      resource: resource,
      clockEntryIri: clockEntry,
      logicalTime: int.parse(logical.value),
      physicalTime: int.parse(physical.value),
      changedProperties: props,
    ));
  }
  return result;
}

/// Returns the IRIs of all property-clock metadata nodes (and the document
/// link predicate-object IRIs) that are part of the framework "PC" surface,
/// to allow exclusion from the normal merge-subject iteration.
Set<IriTerm> collectPropertyClockSubjectIris(
    IriTerm documentIri, RdfGraph document) {
  return document
      .findTriples(
          subject: documentIri,
          predicate: SyncPropertyClock.hasPropertyClock)
      .map((t) => t.object)
      .whereType<IriTerm>()
      .toSet();
}

/// Merges two sets of property clocks into a deduplicated list.
///
/// Same `clockIri` on both sides → keep the one with the larger HLC
/// (logical, then physical); ties keep [local]'s. Unique IRIs are kept
/// as-is. The resulting list preserves clock identity so it can be
/// re-emitted into the merged document.
List<PropertyClock> mergePropertyClocks(
    List<PropertyClock> local, List<PropertyClock> remote) {
  final byIri = <IriTerm, PropertyClock>{};
  for (final pc in local) {
    byIri[pc.clockIri] = pc;
  }
  for (final pc in remote) {
    final existing = byIri[pc.clockIri];
    if (existing == null) {
      byIri[pc.clockIri] = pc;
    } else if (pc.compareHlc(existing) > 0) {
      byIri[pc.clockIri] = pc;
    }
  }
  return byIri.values.toList();
}

/// Looks up the most recent (subject, property) change among a set of
/// property clocks. Returns `null` when no record matches.
///
/// "Most recent" uses **physical time** as the primary key — same as the
/// document-level tie-break for `ClockComparison.concurrent`. This is
/// correct because logical-time comparisons between different
/// installations are not meaningful in the concurrent case. Per
/// `_emitPropertyClocks`, the set of records for a given (resource,
/// property, installation) collapses to at most one entry, so this is
/// always a well-defined "latest change by anyone" lookup.
PropertyClock? latestClockFor(
    Iterable<PropertyClock> clocks, IriTerm subject, IriTerm property) {
  PropertyClock? best;
  for (final pc in clocks) {
    if (pc.resource != subject) continue;
    if (!pc.changedProperties.contains(property)) continue;
    if (best == null) {
      best = pc;
      continue;
    }
    if (pc.physicalTime > best.physicalTime) {
      best = pc;
    } else if (pc.physicalTime == best.physicalTime &&
        pc.clockEntryIri.value.compareTo(best.clockEntryIri.value) > 0) {
      // Deterministic tie-break across installations with identical
      // physical timestamps: lexicographic clock-entry IRI order.
      best = pc;
    }
  }
  return best;
}
