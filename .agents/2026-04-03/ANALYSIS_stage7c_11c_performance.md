# Performance-Analyse: Stage 7c (CrdtMerge) und Stage 11c (ShardMerge)

## Szenario

Initial sync von ~15.000 lokalen Chat-Nachrichten zu einem leeren lokalen Directory.  
Es gibt **keine Remote-Daten** und **keine Konflikte** — beide Stages sollten im Wesentlichen No-Ops sein.

**Beobachtet:**
| Stage | Events | Total | Avg/Event |
|-------|--------|-------|-----------|
| S07c.CrdtMerge | 15.440 | 2,82s | 182µs |
| S11c.ShardMerge | 140 | 1,25s | 8,9ms |

> **Hinweis:** Alle Zeitschätzungen in diesem Dokument sind **unverifizierten Hochrechnungen**. Sub-Messungen wurden implementiert (siehe Abschnitt am Ende) und werden bei nächster Ausführung echte Zahlen liefern.

---

## Stage 7c: CrdtMerge — Detailanalyse

### Codepfad im Initial-Sync-Szenario

**SyncDirection**: `notInRemoteShard` — Ressource existiert lokal, ist aber nicht im Remote-Shard (weil Remote leer ist).

#### Schritt-für-Schritt Durchlauf von `_merge()` in [stage7c_crdt_merge.dart](../packages/locorda_core/lib/src/sync/pipeline/stages/stage7c_crdt_merge.dart):

```
1. switch (d.effectiveDirection)
   → case SyncDirection.notInRemoteShard:
     → mergedGraph = d.localGraph!            ✅ Sofort, kein Merge — gut
   
2. reconciler.reconcileSync(...)               ⚠️ Wird IMMER aufgerufen
   → shardDeterminer.determineShards(...)      → zu messen (S07c.reconcile.shards)
   → hlcService.getCurrentClock(...)           → zu messen (S07c.reconcile.clock)
     → _extractCrdtClock()                     Graph-Lookup
     → _hashClock()                            N-Quads + MD5
   → _shardsChanged(...)                       Set-Vergleich — günstig
   → replaceInDocument (nur bei Änderungen)    → zu messen (S07c.reconcile.replace)

3. buildActiveIndexEntries(...)                → zu messen (S07c.indexEntries)
4. collectTombstonedShards(...)                → zu messen (S07c.tombstones)
5. rdfCore.encodeBinary(reconciled.graph)      → zu messen (S07c.encode)
```

### CPU-Hotspots (15.440×)

#### 1. `_hashClock()` — N-Quads-Serialisierung + MD5

Quelle: [hlc_service.dart](../packages/locorda_core/lib/src/hlc_service.dart) L263-L280

```dart
String _hashClock(CrdtClock clock) {
  final triples = <Triple>[];
  for (final (_, graph) in clock) {
    triples.addAll(graph.findTriples(predicate: CrdtClockEntry.logicalTime));
  }
  final dataset = RdfDataset.fromDefaultGraph(RdfGraph.fromTriples(triples));
  final nquadsEncoder = NQuadsEncoder(options: const NQuadsEncoderOptions(canonical: true));
  final nquads = nquadsEncoder.encode(dataset, generateNewBlankNodeLabels: false);
  return md5.convert(utf8.encode(nquads)).toString();
}
```

**Problem:** Für jede der 15.440 Ressourcen wird:
1. Ein neuer `RdfGraph` aus den Clock-Triples erstellt
2. Ein `RdfDataset` gewrappt
3. Kanonische N-Quads serialisiert (String-Allokation!)
4. UTF8-encoded
5. MD5-gehashed

**Teilweise Redundanz:** Im `notInRemoteShard`-Pfad ändert sich der Graph nicht — `localClockHash` aus `SyncCandidate` könnte als `mergedClockHash` wiederverwendet werden. **Aber:** `getCurrentClock()` liefert auch `logicalTime`, `physicalTime`, `fullClock`, die downstream benötigt werden (Index-Entries, Metadata). Der Hash allein reicht nicht.

→ **Messung nötig** um den realen Impact per Sub-Stage `S07c.reconcile.clock` zu quantifizieren.

#### 2. `encodeBinary()` — Jelly-Encoding

Quelle: `rdfCore.encodeBinary()` → `JellyGraphEncoder.convert()`

**Problem:** Jelly-Encoding iteriert über alle Triples des Graphen, baut Lookup-Tables, serialisiert zu Protobuf. Bei ~15.440 Graphen mit je ~20-50 Triples ist das wahrscheinlich die dominante CPU-Last.

**Initial sync:** `reconcileSync` setzt `idx:belongsToIndexShard` initial → `hasChanges == true` → der Graph wird modifiziert → Neukodierung ist **nötig** (Raw-Bytes aus Stage 5 passen nicht mehr).

→ **Messung nötig** um den realen Impact per Sub-Stage `S07c.encode` zu quantifizieren.

#### 3. `collectTombstonedShards()` — Graph-Traversal

Quelle: [index_entry_builder.dart](../packages/locorda_core/lib/src/index/index_entry_builder.dart)

Traversiert den Graphen und sucht nach `rdf:subject` / `crdt:deletedAt` Triples. In diesem Szenario sehr wahrscheinlich keine Tombstones vorhanden — allerdings ist "initial sync" nicht immer gleichbedeutend mit "keine Tombstones" (Nutzer können die App offline monatelang nutzen, über andere Remotes synchen, etc.).

→ **Messung nötig** per `S07c.tombstones`.

### Zusammenfassung Stage 7c: Identifizierte Hotspots

| Sub-Stage | Mess-Label | Hypothese |
|-----------|------------|-----------|
| CRDT-Merge (switch) | `S07c.merge` | Trivial bei `notInRemoteShard` |
| Shard-Bestimmung | `S07c.reconcile.shards` | Wahrscheinlich günstig |
| Clock (Extract+Hash) | `S07c.reconcile.clock` | `_hashClock()` potenziell dominant |
| Shard-Replace | `S07c.reconcile.replace` | Nur bei Änderungen |
| Reconcile gesamt | `S07c.reconcile` | Summe der obigen |
| Index-Entries | `S07c.indexEntries` | Wahrscheinlich günstig |
| Tombstones | `S07c.tombstones` | Wahrscheinlich günstig, Graph-Traversal |
| Jelly-Encoding | `S07c.encode` | Wahrscheinlich dominant |

---

## Stage 11c: ShardMerge — Detailanalyse

### Codepfad im Initial-Sync-Szenario

140 Shard-Events, davon laut Log ~50 mit "No property changes detected".

#### Schritt-für-Schritt Durchlauf von `_merge()` in [stage11c_shard_merge.dart](../packages/locorda_core/lib/src/sync/pipeline/stages/stage11c_shard_merge.dart):

```
1. Prüfe p.remoteShardGraph
   → Bei initial sync zu leerem Dir: remoteShardGraph == null (404/410)
   → effectiveDoc = p.localDoc                    ✅ Kein Remote-Merge — gut

2. documentManager.prepareModifyWithContract(...)  ⚠️ IMMER aufgerufen
   Innerhalb:
   a) computeIsGovernedBy()                        ~günstig
   b) splitDocument(effectiveDoc, ...)             O(n) BFS + Set-Diff
   c) buildShardAppData(oldAppData, ...)           Subgraph + neuer Graph
   d) _computeSaveCore(...)                        → Sub-Messungen implementiert
      → createOrIncrementClock()                   → _computeSave.clock
      → generateMetadata(appData)                  → _computeSave.appMeta
        → computeCanonicalBlankNodes(appData)      Für neue BlankNode-Identität
        → computeCanonicalBlankNodes(oldAppData)   Für alte BlankNode-Identität
        → _generateCrdtMetadataForChanges(...)     Voller Subjekt/Prädikat-Diff
      → _constructCrdtDocument + fwk metadata      → _computeSave.construct

3. WENN prepared == null (~50 Shards):
   → rdfCore.encodeBinary(baseGraph)              → S11c.encode (benötigt für DB)
   
4. WENN prepared != null (~90 Shards):
   → rdfCore.encodeBinary(mergedGraph)             → S11c.encode
```

### CPU-Hotspots (140×)

#### 1. `computeCanonicalBlankNodes` — 2× pro Shard (NICHT redundant!)

Quelle: [identified_blank_node_builder.dart](../packages/locorda_core/lib/src/mapping/identified_blank_node_builder.dart) L206+

Wird **zweimal** aufgerufen in `generateMetadata()`:
1. Für `appData` (neue App-Daten nach `buildShardAppData`)
2. Für `oldAppData` (bisherige App-Daten)

**⚠️ Dies ist KEIN Duplikat.** Beide Aufrufe sind semantisch notwendig:
- `computeCanonicalBlankNodes` erzeugt `IdentifiedBlankNodeSubject`-Objekte, die die kanonische IRI-Identität eines BlankNodes innerhalb eines bestimmten Graphen festlegen.
- `IdentifiedBlankNodeSubject.operator==` verwendet `any(contains)` auf den `identifiers`-Listen beider Graphen, um BlankNodes **graphübergreifend** zu matchen.
- `hashCode` ist konstant `0` um dies zu ermöglichen — das Matching ist bewusst asymmetrisch.
- Ohne den Aufruf für `oldAppData` wären gelöschte oder geänderte BlankNode-Subjects nicht korrekt identifizierbar.

Pro Aufruf:
- Alle BlankNode-Subjekte sammeln
- Identifying Predicates pro BlankNode aus MergeContract laden
- Parent-Triples aufbauen (Triple-Scan)
- Dependency-Sortierung (`_sortByDependencies`)
- Pro BlankNode: `_addIdentifiedBlankNodes` mit Pfad-Berechnung

Bei einem Shard mit z.B. 100 Entries (als BlankNodes) → zweimal ~100 BlankNode-Subjekte verarbeiten.

→ **Messung nötig** via `_computeSave.appMeta` (enthält beide Aufrufe).

#### 2. `_generateCrdtMetadataForChanges` — Voller Diff

Quelle: [local_document_merger.dart](../packages/locorda_core/lib/src/local_document_merger.dart) L189+

- Partitioniert alle Subjekte in `added`, `deleted`, `common`
- Für **jeden** `common` Subjekt: iteriert über **alle** Prädikate beider Graphen
- Pro Prädikat: `_valuesEqual()` mit Deep-Equality inkl. Blank-Node-Vergleich
- Pro Änderung: `crdtType.localValueChange()` mit Metadaten-Generierung

Wenn die Shards unverändert sind, werden ~100 Subjekte × ~4 Prädikate verglichen, nur um festzustellen: alles gleich → `propertyChanges.isEmpty` → return null.

→ In `_computeSave.appMeta` enthalten.

#### 3. `splitDocument` — BFS + Set-Differenz

Quelle: [split_document.dart](../packages/locorda_core/lib/src/split_document.dart) L9-L30

- `subgraph()`: BFS/DFS-Traversal mit Filter-Callback + Type-Lookup pro Triple
- `without()`: Set-Differenz über alle Triples des Dokuments
- Bei Shard-Dokumenten mit 300-500+ Triples: O(n) mit konstantem Overhead pro Triple

→ In `S11c.prepareModify` enthalten (vor `_computeSaveCore`).

#### 4. `buildShardAppData` — Erneuter Subgraph + Graph-Erzeugung

Quelle: [shard_document_generator.dart](../packages/locorda_core/lib/src/sync/shard_document_generator.dart) L345-L363

```dart
RdfGraph.fromTriples([
  ...oldAppData.subgraph(shardIri, filter: ...).triples,
  if (!hasType) Triple(...),
  if (!hasIsShardOf) Triple(...),
  ...newTriples
]);
```

- **Erneuter** `subgraph()`-Traversal (nach dem in `splitDocument`)
- Neuen `RdfGraph.fromTriples` aus ~200-500 Triples erstellen

→ In `S11c.prepareModify` enthalten (vor `_computeSaveCore`).

#### 5. Jelly-Encoding — benötigt für DB-Commit

In [stage11c_shard_merge.dart](../packages/locorda_core/lib/src/sync/pipeline/stages/stage11c_shard_merge.dart):

```dart
if (prepared == null) {
    final encodedBytes = rdfCore.encodeBinary(baseGraph, ...);
```

**⚠️ Korrektur:** Dies ist **keine reine Verschwendung**. Stage 13 (`shardDbCommit`) schreibt **jeden** `MergedShard` in die DB und benötigt `encodedForDb.bytes`. Die Frage ist eher, ob der DB-Schreibvorgang selbst vermeidbar wäre — z.B. ob bei `prepared == null` UND `existsOnRemote` der Shard-Commit komplett übersprungen werden kann.

Zusätzlich: `StoredDocument` in `PreparedShard.localDoc` enthält **keine** rohen Bytes (nur den decoded `RdfGraph`). `RawStoredDocument` mit `rawContent`-Feld existiert als Typ, wird aber in diesem Pfad nicht verwendet.

→ **Messung nötig** per `S11c.encode`.

#### 6. `createOrIncrementClock` mit `_hashClock`

In `_computeSaveCore()` ([crdt_document_manager.dart](../packages/locorda_core/lib/src/crdt_document_manager.dart)):

```dart
final clock = _hlcService.createOrIncrementClock(oldFrameworkGraph, documentIri, ...);
```

→ `_incrementClock()` → `_hashClock()` → N-Quads + MD5. 140× für Shards.

→ **Messung nötig** per `_computeSave.clock`.

### Zusammenfassung Stage 11c: Identifizierte Hotspots

| Sub-Stage | Mess-Label | Hypothese |
|-----------|------------|-----------|
| Remote-Merge (switch) | `S11c.remoteMerge` | Trivial ohne Remote-Daten |
| prepareModify gesamt | `S11c.prepareModify` | Dominant — enthält splitDoc, buildAppData |
| ↳ Clock (Create+Hash) | `_computeSave.clock` | `_hashClock()` 140× |
| ↳ App-Metadata (Blank-Nodes + Diff) | `_computeSave.appMeta` | Potenziell dominant — 2× canonicalBlankNodes + Diff |
| ↳ Construct (Framework-Meta + Assembly) | `_computeSave.construct` | Framework generateMetadata + Graph-Assembly |
| Jelly-Encoding | `S11c.encode` | 140× Graphen kodieren |

---

## Übergreifende Erkenntnisse

### 1. Clock-Hash: Teilweise Redundanz (betrifft 7c)

In `reconcileSync` (via `getCurrentClock`) wird der Clock-Hash neu berechnet, obwohl `SyncCandidate.localClockHash` aus Stage 4 bereits vorhanden ist. Im `notInRemoteShard`-Pfad ändert sich der Graph nicht → Hash bleibt identisch.

**Aber:** `getCurrentClock()` liefert nicht nur `hash`, sondern auch `logicalTime`, `physicalTime`, `fullClock` — diese werden downstream für Index-Entries und Metadata benötigt. Eine Optimierung müsste den Hash separat behandeln und die anderen Clock-Felder weiterhin berechnen.

### 2. Voller CRDT-Diff für "keine Änderungen" (betrifft 11c)

`prepareModifyWithContract` führt den **kompletten** Algorithmus durch:
1. `splitDocument` (BFS + Set-Diff)
2. `buildShardAppData` (Subgraph + Graph-Konstruktion)
3. `createOrIncrementClock` (Extract + Hash)
4. `computeCanonicalBlankNodes` × 2 (beide semantisch notwendig!)
5. `_generateCrdtMetadataForChanges` (Voller Subjekt/Prädikat-Diff)

...nur um in ~50 Fällen `return null` zu liefern.

**Kein Early-Exit**: Es gibt keine günstige Vorstufen-Prüfung ("Hat sich überhaupt etwas geändert?").

### 3. DB-Commit für unveränderte Shards (betrifft 11c)

Wenn `prepared == null` und der Shard bereits in der DB existiert, könnte der gesamte DB-Commit (Stage 13) einschließlich der Jelly-Neukodierung übersprungen werden. `StoredDocument` enthält keine Raw-Bytes — eine Durchreichung der Raw-Bytes aus der DB (via `RawStoredDocument`) könnte die Neukodierung eliminieren.

### 4. Redundante Graph-Traversals (betrifft 11c)

`splitDocument` macht einen Subgraph-Traversal, dann macht `buildShardAppData` einen **weiteren** Subgraph-Traversal auf dem Ergebnis. Bei großen Shard-Dokumenten verdoppelt sich der Traversal-Aufwand.

---

## Optimierungsmöglichkeiten

### Quick Wins

| # | Maßnahme | Stage | Kommentar |
|---|----------|-------|-----------|
| **A** | Clock-Hash aus `SyncCandidate.localClockHash` für `needsUpload`/`needsDbWrite` verwenden, statt in `getCurrentClock` neu zu berechnen | 7c | Spart `_hashClock` für non-merge Pfade; Clock-Felder müssen separat extrahiert werden |
| **B** | Early-Exit in 11c **vor** `prepareModifyWithContract`: Schneller Triple-Vergleich der Entry-Triples → skip wenn identisch | 11c | Spart den gesamten CRDT-Diff für ~50 unveränderte Shards |
| **C** | DB-Commit in Stage 13 überspringen wenn `prepared == null` UND Shard already exists | 11c | Spart Jelly-Encoding + DB-Write für unveränderte Shards |

### Mittlerer Aufwand

| # | Maßnahme | Stage | Kommentar |
|---|----------|-------|-----------|
| **D** | Raw Jelly-Bytes aus DB durchreichen wenn Graph unverändert | 7c, 11c | `RawStoredDocument` existiert, wird aber nicht genutzt |
| **E** | `_hashClock` Algorithmus: Direkter Hash über sortierte `(installationIri, logicalTime)` statt N-Quads-Umweg | Übergreifend | Eliminiert RdfGraph/RdfDataset/NQuads/UTF8 Allokationen |

### Architektur-Level

| # | Maßnahme | Stage | Kommentar |
|---|----------|-------|-----------|
| **F** | Für `notInRemoteShard`: Spezialisierten Pfad in 7c der `reconcileSync` minimal hält | 7c | Muss zuerst per Messung validiert werden |
| **G** | `splitDocument` + `buildShardAppData` Graph-Traversals fusionieren | 11c | Muss zuerst per Messung validiert werden |

---

## Implementierte Sub-Messungen

Folgende Instrumentierung wurde hinzugefügt und wird beim nächsten Sync-Lauf echte Zahlen liefern:

### Stage 7c (`stage7c_crdt_merge.dart`)

| Label | Was wird gemessen |
|-------|-------------------|
| `S07c.merge` | CRDT-Merge (SyncDirection switch) |
| `S07c.reconcile` | `reconcileSync()` gesamt |
| `S07c.reconcile.shards` | `determineShards()` innerhalb reconcile |
| `S07c.reconcile.clock` | `getCurrentClock()` innerhalb reconcile (inkl. `_hashClock`) |
| `S07c.reconcile.replace` | `replaceInDocument()` innerhalb reconcile (nur bei Änderungen) |
| `S07c.indexEntries` | `buildActiveIndexEntries()` |
| `S07c.tombstones` | `collectTombstonedShards()` |
| `S07c.encode` | `encodeBinary()` (Jelly) |

### Stage 11c (`stage11c_shard_merge.dart`)

| Label | Was wird gemessen |
|-------|-------------------|
| `S11c.remoteMerge` | Remote-CRDT-Merge (wenn `remoteShardGraph != null`) |
| `S11c.prepareModify` | `prepareModifyWithContract()` gesamt |
| `S11c.encode` | `encodeBinary()` (Jelly) |

### `_computeSaveCore` (`crdt_document_manager.dart`)

| Label | Was wird gemessen |
|-------|-------------------|
| `_computeSave.clock` | `createOrIncrementClock()` (inkl. `_hashClock`) |
| `_computeSave.appMeta` | `generateMetadata()` für App-Daten (inkl. 2× `computeCanonicalBlankNodes` + Diff) |
| `_computeSave.construct` | `_constructCrdtDocument()` + Framework-`generateMetadata()` + Graph-Assembly |

### `reconcileSync` (`document_shard_reconciler.dart`)

| Label | Was wird gemessen |
|-------|-------------------|
| `S07c.reconcile.shards` | `determineShards()` |
| `S07c.reconcile.clock` | `getCurrentClock()` (inkl. `_hashClock`) |
| `S07c.reconcile.replace` | `_shardsChanged()` + `replaceInDocument()` |

---

## Nächste Schritte

1. **Sync mit Messungen laufen lassen** → echte Zahlen für alle Sub-Stages sammeln
2. **Report mit echten Zahlen aktualisieren** → Hypothesen validieren oder widerlegen
3. **Optimierungen priorisieren** basierend auf gemessenen Hotspots
