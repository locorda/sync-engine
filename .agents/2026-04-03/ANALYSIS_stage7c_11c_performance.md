# Performance-Analyse: Stage 7c (CrdtMerge) und Stage 11c (ShardMerge)

## Szenario

Initial sync von ~15.000 lokalen Chat-Nachrichten zu einem leeren lokalen Directory.  
Es gibt **keine Remote-Daten** und **keine Konflikte** — beide Stages sollten im Wesentlichen No-Ops sein.

**Beobachtet:**
| Stage | Events | Total | Avg/Event |
|-------|--------|-------|-----------|
| S07c.CrdtMerge | 15.440 | 2,82s | 182µs |
| S11c.ShardMerge | 140 | 1,25s | 8,9ms |

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
   → shardDeterminer.determineShards(...)      ~10-20µs — OK
   → hlcService.getCurrentClock(...)           ⛔ TEUER — siehe unten
     → _extractCrdtClock()                     ~5µs — Graph-Lookup
     → _hashClock()                            ⛔ 30-80µs — N-Quads + MD5
   → _shardsChanged(...)                       ~2µs — Set-Vergleich
   → replaceInDocument (nur bei Änderungen)    ~5-10µs bei Änderungen

3. buildActiveIndexEntries(...)                ~5µs — OK
4. collectTombstonedShards(...)                ~5-10µs — unnötig bei initial sync
5. rdfCore.encodeBinary(reconciled.graph)      ⛔ 60-100µs — Jelly-Encoding
```

### CPU-Hotspots (15.440×)

#### 1. `_hashClock()` — N-Quads-Serialisierung + MD5 (geschätzt 450–1.200ms gesamt)

Quelle: [hlc_service.dart](../packages/locorda_core/lib/src/hlc_service.dart) L263-L280

```dart
String _hashClock(CrdtClock clock) {
  final triples = <Triple>[];
  for (final (_, graph) in clock) {
    triples.addAll(graph.findTriples(predicate: CrdtClockEntry.logicalTime));
  }
  // Erzeugt RdfGraph → RdfDataset → NQuadsEncoder → UTF8 → MD5
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

**Redundanz:** Der `localClockHash` ist bereits als Feld im `SyncCandidate` verfügbar (kommt aus Stage 4 / der DB). Er wird in `reconcileSync` aber **nicht genutzt** — stattdessen wird er komplett neu berechnet.

#### 2. `encodeBinary()` — Jelly-Encoding (geschätzt 900–1.500ms gesamt)

Quelle: `rdfCore.encodeBinary()` → `JellyGraphEncoder.convert()`

```dart
Uint8List convert(RdfGraph graph) {
  final state = JellyEncoderState(...);
  final writer = JellyRawFrameWriter(_options.maxRowsPerFrame);
  for (final triple in graph.triples) {    // ← Iteration über ALLE Triples
    state.emitTriple(triple, writer);       // ← Name/Prefix/Datatype Lookups
  }
  return writer.finish();                   // ← Protobuf-Serialisierung
}
```

**Problem:** Jelly-Encoding iteriert über alle Triples des Graphen, baut Lookup-Tables, serialisiert zu Protobuf. Bei ~15.440 Graphen mit je ~20-50 Triples ist das die dominante CPU-Last.

**Teilredundanz:** Im `notInRemoteShard`-Pfad ist `mergedGraph = d.localGraph` — der Graph wurde nicht verändert. Wenn die ursprünglichen Jelly-Bytes aus Stage 5 (LocalLoad) noch verfügbar wären, könnte die Neukodierung entfallen. Allerdings verändert `reconcileSync` den Graphen durch Shard-Zuweisung (bei initial sync wird `idx:belongsToIndexShard` initial gesetzt → `hasChanges == true`).

#### 3. `collectTombstonedShards()` — unnötig bei initial sync (~75–150ms gesamt)

Quelle: [index_entry_builder.dart](../packages/locorda_core/lib/src/index/index_entry_builder.dart)

Bei initial sync gibt es keine Tombstones. Die Funktion traversiert trotzdem den Graphen und sucht nach `rdf:subject` / `crdt:deletedAt` Triples.

### Zusammenfassung Stage 7c: Zeitaufteilung (geschätzt)

| Operation | Geschätzt | % von 2,82s |
|-----------|-----------|-------------|
| `encodeBinary` (Jelly) | ~900-1.500ms | 32-53% |
| `_hashClock` (N-Quads+MD5) | ~450-1.200ms | 16-43% |
| `reconcileSync` (ohne Hash) | ~200-350ms | 7-12% |
| `buildActiveIndexEntries` | ~75ms | 3% |
| `collectTombstonedShards` | ~100ms | 4% |
| Rest (dispatch, alloc) | ~100-300ms | - |

---

## Stage 11c: ShardMerge — Detailanalyse

### Codepfad im Initial-Sync-Szenario

140 Shard-Events, davon laut Log ~50 mit "No property changes detected".

#### Schritt-für-Schritt Durchlauf von `_merge()` in [stage11c_shard_merge.dart](../packages/locorda_core/lib/src/sync/pipeline/stages/stage11c_shard_merge.dart):

```
1. Prüfe p.remoteShardGraph
   → Bei initial sync zu leerem Dir: remoteShardGraph == null (404/410)
   → effectiveDoc = p.localDoc                    ✅ Kein Remote-Merge — gut

2. documentManager.prepareModifyWithContract(...)  ⛔ TEUER — immer aufgerufen
   Innerhalb:
   a) computeIsGovernedBy()                        ~1µs — OK
   b) splitDocument(effectiveDoc, ...)             ⛔ O(n) BFS + Set-Diff
   c) buildShardAppData(oldAppData, ...)           ⛔ Subgraph + neuer Graph
   d) _computeSaveCore(...)                        ⛔ TEUER — siehe unten
      → createOrIncrementClock()                   ⛔ _hashClock()
      → generateMetadata(appData, oldAppData, ...) ⛔ DOMINANT
        → computeCanonicalBlankNodes(appData)      ⛔ TEUER bei vielen Entries
        → computeCanonicalBlankNodes(oldAppData)   ⛔ DUPLIKAT!
        → _generateCrdtMetadataForChanges(...)     ⛔ Voller Subjekt/Prädikat-Diff

3. WENN prepared == null (keine Änderungen, ~50 Shards):
   → rdfCore.encodeBinary(baseGraph)              ⛔ JELLY-ENCODING TROTZDEM!
   
4. WENN prepared != null (mit Änderungen, ~90 Shards):
   → rdfCore.encodeBinary(mergedGraph)             ⚠️ Nötig, aber teuer
```

### CPU-Hotspots (140×)

#### 1. `computeCanonicalBlankNodes` — 2× pro Shard (geschätzt 200–500ms gesamt)

Quelle: [identified_blank_node_builder.dart](../packages/locorda_core/lib/src/mapping/identified_blank_node_builder.dart) L206+

Wird **zweimal** aufgerufen in `generateMetadata()`:
1. Für `appData` (neue App-Daten nach `buildShardAppData`)
2. Für `oldAppData` (bisherige App-Daten)

Pro Aufruf:
- Alle BlankNode-Subjekte sammeln (`blankNodeSubjects`)
- Identifying Predicates pro BlankNode aus MergeContract laden
- Parent-Triples aufbauen (kompletter Triple-Scan!)
- Dependency-Sortierung (`_sortByDependencies`)
- Pro BlankNode: `_addIdentifiedBlankNodes` mit Pfad-Berechnung
- Duplikat- und Zirkularreferenz-Erkennung

Bei einem Shard mit z.B. 100 Entries (je als BlankNode) und je 3-5 Triples → 300-500 Triples, davon ~100 BlankNode-Subjekte. **Zweimal**.

#### 2. `_generateCrdtMetadataForChanges` — Voller Diff (geschätzt 150–350ms gesamt)

Quelle: [local_document_merger.dart](../packages/locorda_core/lib/src/local_document_merger.dart) L189+

- Partitioniert alle Subjekte in `added`, `deleted`, `common`
- Für **jeden** `common` Subjekt: iteriert über **alle** Prädikate beider Graphen
- Pro Prädikat: `_valuesEqual()` mit Deep-Equality inkl. Blank-Node-Vergleich
- Pro Änderung: `crdtType.localValueChange()` mit vollständiger Metadaten-Generierung

Wenn die Shards unverändert sind, werden ~100 Subjekte × ~4 Prädikate verglichen, nur um festzustellen: alles gleich → `propertyChanges.isEmpty` → return null.

#### 3. `splitDocument` — BFS + Set-Differenz (geschätzt 70–200ms gesamt)

Quelle: [split_document.dart](../packages/locorda_core/lib/src/split_document.dart) L9-L30

```dart
final frameworkGraph = document.subgraph(documentIri, filter: (triple, depth) {
  // BFS-Traversal des gesamten Dokuments
  final type = types.putIfAbsent(triple.subject, () => ...findSingleObject...);
  final isStopTraversal = mergeContract.isStopTraversalPredicate(type, triple.predicate);
  return isStopTraversal ? TraversalDecision.includeButDontDescend : TraversalDecision.include;
});
return (appGraph: document.without(frameworkGraph), frameworkGraph: frameworkGraph);
```

- `subgraph()`: BFS/DFS-Traversal mit Filter-Callback + Type-Lookup pro Triple
- `without()`: Set-Differenz über alle Triples des Dokuments
- Bei Shard-Dokumenten mit 300-500+ Triples: O(n) mit konstantem Overhead pro Triple

#### 4. `buildShardAppData` — Erneuter Subgraph + Graph-Erzeugung (geschätzt 70–140ms gesamt)

Quelle: [shard_document_generator.dart](../packages/locorda_core/lib/src/sync/shard_document_generator.dart) L345-L363

```dart
RdfGraph.fromTriples([
  ...oldAppData.subgraph(shardIri, filter: ...).triples,  // ← Erneuter Traversal
  if (!hasType) Triple(...),
  if (!hasIsShardOf) Triple(...),
  ...newTriples                                            // ← Alle Entry-Triples
]);
```

- **Erneuter** `subgraph()`-Traversal (nach dem in `splitDocument`)
- Neuen `RdfGraph.fromTriples` aus ~200-500 Triples erstellen
- Im No-Change-Fall: identisch mit `oldAppData` (der Subgraph minus `containsEntry` + erneute `containsEntry` = dasselbe)

#### 5. Jelly-Encoding bei `prepared == null` — pure Verschwendung (geschätzt 50–200ms gesamt)

In [stage11c_shard_merge.dart](../packages/locorda_core/lib/src/sync/pipeline/stages/stage11c_shard_merge.dart) L92-L94:

```dart
if (prepared == null) {
    // ...
    final encodedBytes = rdfCore.encodeBinary(baseGraph, contentType: jelly.primaryMimeType);
    // ↑ JELLY-ENCODING OBWOHL NICHTS GEÄNDERT!
```

~50 Shards durchlaufen die volle CRDT-Analyse nur um festzustellen "keine Änderungen", und werden danach trotzdem Jelly-encoded.

#### 6. `createOrIncrementClock` mit `_hashClock` (geschätzt 40–100ms gesamt)

In `_computeSaveCore()` ([crdt_document_manager.dart](../packages/locorda_core/lib/src/crdt_document_manager.dart) L620):

```dart
final clock = _hlcService.createOrIncrementClock(oldFrameworkGraph, documentIri, ...);
```

→ `_incrementClock()` → `_hashClock()` → N-Quads + MD5. 140× für Shards.

### Zusammenfassung Stage 11c: Zeitaufteilung (geschätzt)

| Operation | Geschätzt | % von 1,25s |
|-----------|-----------|-------------|
| `computeCanonicalBlankNodes` (2×140) | ~200-500ms | 16-40% |
| `_generateCrdtMetadataForChanges` | ~150-350ms | 12-28% |
| `encodeBinary` (Jelly, 140×) | ~140-420ms | 11-34% |
| `splitDocument` | ~70-200ms | 6-16% |
| `buildShardAppData` | ~70-140ms | 6-11% |
| `_hashClock` | ~40-100ms | 3-8% |
| Rest | ~50-100ms | - |

---

## Übergreifende Erkenntnisse

### 1. Clock-Hash wird redundant neu berechnet (betrifft 7c)

In `reconcileSync` (via `getCurrentClock`) wird der Clock-Hash neu berechnet, obwohl er in `SyncCandidate.localClockHash` aus Stage 4 bereits vorhanden ist. Im `notInRemoteShard`-Pfad ändert sich der Graph nicht → Hash bleibt identisch.

**Impact**: ~450-1.200ms in 7c vermeidbar.

### 2. Voller CRDT-Diff für "keine Änderungen" (betrifft 11c)

`prepareModifyWithContract` führt den **kompletten** Algorithmus durch:
1. `splitDocument` (BFS + Set-Diff)
2. `buildShardAppData` (Subgraph + Graph-Konstruktion)
3. `createOrIncrementClock` (Extract + Hash)
4. `computeCanonicalBlankNodes` × 2 (Dependency-Sort, Pfad-Berechnung)
5. `_generateCrdtMetadataForChanges` (Voller Subjekt/Prädikat-Diff)

...nur um in ~50 Fällen `return null` zu liefern.

**Kein Early-Exit**: Es gibt keine günstige Vorstufen-Prüfung ("Hat sich überhaupt etwas geändert?").

### 3. Jelly-Encoding bei unveränderten Shards (betrifft 11c)

Wenn `prepared == null`, wird der unveränderte Graph trotzdem neu Jelly-encoded. Die bestehenden Bytes aus der DB stehen nicht zur Verfügung.

### 4. Doppelte `computeCanonicalBlankNodes` (betrifft 11c)

Für Shard-Dokumente mit vielen Entry-BlankNodes ist die Identifizierung besonders teuer. Sie wird für `appData` UND `oldAppData` separat durchgeführt — jedes Mal mit vollständigem Triple-Scan, Dependency-Sortierung, und Pfad-Berechnung.

### 5. Redundante Graph-Traversals (betrifft 11c)

`splitDocument` macht einen Subgraph-Traversal, dann macht `buildShardAppData` einen **weiteren** Subgraph-Traversal auf dem Ergebnis. Bei großen Shard-Dokumenten verdoppelt sich der Traversal-Aufwand.

---

## Optimierungsmöglichkeiten

### Quick Wins (Hoch Impact, Wenig Aufwand)

| # | Maßnahme | Betroffene Stage | Geschätzte Einsparung |
|---|----------|-------------------|----------------------|
| **A** | Clock-Hash aus `SyncCandidate.localClockHash` durchreichen statt neu berechnen | 7c | 450-1.200ms |
| **B** | Jelly-Encoding überspringen bei `prepared == null` — bestehende Bytes aus DB/preload durchreichen | 11c | 50-200ms |
| **C** | Early-Exit in 11c **vor** `prepareModifyWithContract`: Wenn `entryTriples` identisch mit bestehenden Entries → skip | 11c | 200-500ms (für ~50 Shards) |

### Mittlerer Aufwand

| # | Maßnahme | Betroffene Stage | Geschätzte Einsparung |
|---|----------|-------------------|----------------------|
| **D** | `reconcileSync` bei `notInRemoteShard` vereinfachen: Shard-Zuweisungen und Clock aus dem lokalen Dokument extrahieren, ohne vollen `determineShards` + `getCurrentClock` | 7c | 200-400ms |
| **E** | Raw Jelly-Bytes aus Stage 5 (LocalLoad) als `BinaryGraphSource` mitführen, um Neukodierung in 7c zu vermeiden wenn Graph unverändert bleibt (nach Shard-Reconciliation) | 7c | 0-500ms (nur wenn `hasChanges == false`) |
| **F** | `computeCanonicalBlankNodes`: Ergebnis cachen zwischen `appData` und `oldAppData` wenn der Subgraph sich nicht geändert hat, oder für Shard-Entries einen simplifizierten Pfad verwenden | 11c | 100-250ms |

### Architektur-Level

| # | Maßnahme | Betroffene Stage | Geschätzte Einsparung |
|---|----------|-------------------|----------------------|
| **G** | Für Initial-Sync: `notInRemoteShard`-Pfad in 7c komplett spezialisieren — kein `reconcileSync`, kein `encodeBinary` wenn Bytes vorhanden, Clock direkt aus Candidate | 7c | bis 1.500ms |
| **H** | Für Initial-Sync: Shards mit identischen Entry-Triples in 11c komplett skippen — Shard-Dokument unverändert in DB belassen, nur `needsUpload` prüfen | 11c | bis 800ms (für ~50 Shards) |
| **I** | `_hashClock` Algorithmus optimieren: Statt N-Quads-Serialisierung einen direkten Hash über die sortierten `(installationIri, logicalTime)`-Paare berechnen | 7c, 11c | 30-50% der Hash-Kosten |

---

## Priorisierte Empfehlung

**Maximaler Impact mit minimalem Risiko:**

1. **A — Clock-Hash durchreichen** (7c): Einfachster Fix. `localClockHash` aus dem Input-Candidate als `mergedClockHash` verwenden wenn `mergedGraph == d.localGraph` (alle non-merge Pfade).

2. **C — Early-Exit für unveränderte Shards** (11c): Vor dem teuren `prepareModifyWithContract` prüfen ob die neuen Entry-Triples identisch mit den bestehenden sind. Das spart den gesamten `splitDocument` → `computeCanonicalBlankNodes` × 2 → `_generateCrdtMetadataForChanges` Durchlauf.

3. **B — Raw Bytes durchreichen bei no-change** (11c): Wenn `prepared == null`, die bestehenden Jelly-Bytes aus `p.localDoc` verwenden statt neu zu encodieren.

4. **I — `_hashClock` vereinfachen** (übergreifend): Den N-Quads-Umweg eliminieren und direkt über sortierte `(installationIri, logicalTime)`-Tupel hashen.

**Konservative Gesamtschätzung: 1,5–3s Einsparung (13–25% der Gesamtlaufzeit von 12s)**
