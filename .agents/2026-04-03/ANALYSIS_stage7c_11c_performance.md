# Performance-Analyse: Stage 7c (CrdtMerge) und Stage 11c (ShardMerge)

## Szenario

Initial sync von ~15.000 lokalen Chat-Nachrichten zu einem leeren lokalen Directory.  
Es gibt **keine Remote-Daten** und **keine Konflikte** — beide Stages sollten im Wesentlichen No-Ops sein.

**Pipeline-Gesamtlauf:** 17,74s total, 155.473 Events.

**Beobachtet (mit Sub-Messungen):**
| Stage | Events | Total | Avg/Event |
|-------|--------|-------|-----------|
| S07c.CrdtMerge | 15.300 | 3,18s | 208µs |
| S11c.ShardMerge | 134 | 1,31s | 9,8ms |

> **Stand:** Echte Sub-Messungen vom 03.04.2026. Hypothesen aus der ersten Analyse sind nun validiert/widerlegt.

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

### Gemessene CPU-Verteilung (15.300×)

| Sub-Stage | Label | Total | Avg | Anteil |
|-----------|-------|-------|-----|--------|
| Jelly-Encoding | `S07c.encode` | **1,60s** | 104µs | **50%** |
| Shard-Bestimmung | `S07c.reconcile.shards` | **909ms** | 59µs | **29%** |
| Clock (Extract+Hash) | `S07c.reconcile.clock` | **464ms** | 30µs | **15%** |
| Shard-Replace | `S07c.reconcile.replace` | 65ms | 4µs | 2% |
| Tombstones | `S07c.tombstones` | 40ms | 2µs | 1% |
| Index-Entries | `S07c.indexEntries` | 18ms | 1µs | <1% |
| CRDT-Merge (switch) | `S07c.merge` | 344µs | ~0µs | ~0% |

**Summe Sub-Messungen:** ~3,10s von 3,18s — 97% der Stage-Zeit erklärt.

### Analyse der Top-3 Hotspots

#### 1. `encodeBinary()` — Jelly-Encoding (1,60s / 50%)

Quelle: `rdfCore.encodeBinary()` → `JellyGraphEncoder.convert()`

**Bestätigt als dominanter Hotspot.** Jelly-Encoding iteriert über alle Triples des Graphen, baut Lookup-Tables, serialisiert zu Protobuf. Bei ~15.300 Graphen mit je ~20-50 Triples die größte CPU-Last.

**Initial sync:** `reconcileSync` setzt `idx:belongsToIndexShard` initial → `hasChanges == true` → der Graph wird modifiziert → Neukodierung ist **nötig** (Raw-Bytes aus Stage 5 passen nicht mehr).

**Optimierungspotential:** Begrenzt bei Initial-Sync (Encoding unvermeidbar wegen Shard-Assignment). Bei Re-Sync mit unveränderten Graphen könnten Raw-Bytes aus DB durchgereicht werden.

#### 2. `determineShards()` — Shard-Bestimmung (909ms / 29%)

**Überraschung!** War als "wahrscheinlich günstig" eingeschätzt, ist aber der zweitgrößte Hotspot. 59µs pro Aufruf × 15.300 = 909ms.

Quellen der Kosten: `ShardDeterminer.determineShards()` muss pro Ressource die zugehörigen Shards berechnen — wahrscheinlich via Regex-Matching oder Gruppenzuordnung. **Hier lohnt sich eine tiefere Untersuchung.**

#### 3. `getCurrentClock()` — Clock Extract + Hash (464ms / 15%)

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

**Gemessen:** 464ms = 15% der Stage-Zeit. Optimierung via direktem Hash (statt N-Quads-Umweg) könnte ~300ms einsparen.

### Hypothesen-Validierung Stage 7c

| Hypothese | Ergebnis |
|-----------|----------|
| "CRDT-Merge trivial bei `notInRemoteShard`" | ✅ **Bestätigt** — 344µs total, vernachlässigbar |
| "Shard-Bestimmung wahrscheinlich günstig" | ❌ **Widerlegt** — 909ms, zweitgrößter Hotspot! |
| "`_hashClock()` potenziell dominant" | ⚠️ **Teilweise** — 464ms, Rang 3 (nicht dominant) |
| "Jelly-Encoding wahrscheinlich dominant" | ✅ **Bestätigt** — 1,60s = 50% |
| "Tombstones/IndexEntries günstig" | ✅ **Bestätigt** — zusammen 58ms, vernachlässigbar |

---

## Stage 11c: ShardMerge — Detailanalyse

### Codepfad im Initial-Sync-Szenario

134 Shard-Events. **100% der Shards** hatten `propertyChanges.isEmpty` — `_computeSave.construct` erscheint **nicht** im Output (wird nie erreicht).

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
   d) _computeSaveCore(...)
      → createOrIncrementClock()                   48ms total
      → generateMetadata(appData)                  851ms total ← DOMINANT
        → computeCanonicalBlankNodes(appData)
        → computeCanonicalBlankNodes(oldAppData)
        → _generateCrdtMetadataForChanges(...)     → findet KEINE Änderungen
      → _constructCrdtDocument                     → wird NIE erreicht (100% return null)

3. prepared == null (100% der Shards!):
   → rdfCore.encodeBinary(baseGraph)              226ms total
```

### Gemessene CPU-Verteilung (134×)

| Sub-Stage | Label | Total | Avg | Anteil |
|-----------|-------|-------|-----|--------|
| prepareModify gesamt | `S11c.prepareModify` | **1,08s** | 8,1ms | **82%** |
| ↳ App-Metadata (BlankNodes + Diff) | `_computeSave.appMeta` | **851ms** | 6,3ms | **65%** |
| ↳ Clock (Create+Hash) | `_computeSave.clock` | 48ms | 356µs | 4% |
| ↳ Construct | `_computeSave.construct` | **0ms** | — | **nie erreicht!** |
| Jelly-Encoding | `S11c.encode` | 226ms | 1,7ms | 17% |
| Remote-Merge | `S11c.remoteMerge` | 38µs | ~0µs | ~0% |

**Summe Sub-Messungen:** ~1,31s — 100% der Stage-Zeit erklärt.

**Kritische Erkenntnis:** `_computeSave.construct` erscheint **nicht im Output** — `propertyChanges.isEmpty` ist bei **100% der 134 Shards** `true`. Der gesamte CRDT-Diff-Aufwand (851ms `_computeSave.appMeta` + splitDoc/buildShardAppData in den 181ms `prepareModify`-Overhead) dient nur dazu, festzustellen, dass sich **nichts geändert hat**, und `return null` zu liefern.

### Analyse der Hotspots

#### 1. `_computeSave.appMeta` — 851ms (65%) — **GRÖSSTER HOTSPOT**

Enthält `computeCanonicalBlankNodes` (2×) + `_generateCrdtMetadataForChanges` (voller Diff).

**computeCanonicalBlankNodes** wird **zweimal** aufgerufen in `generateMetadata()` — für `appData` und `oldAppData`. Beide Aufrufe sind semantisch notwendig (siehe Analyse oben).

**_generateCrdtMetadataForChanges** ([local_document_merger.dart](../packages/locorda_core/lib/src/local_document_merger.dart) L189+) partitioniert alle Subjekte, iteriert über alle Prädikate, vergleicht Werte — nur um bei **100% der Shards** festzustellen: `propertyChanges.isEmpty` → `return null`.

**851ms für ein Ergebnis, das immer "keine Änderungen" lautet.**

#### 2. `splitDocument` + `buildShardAppData` — ~181ms (in `prepareModify`-Overhead)

`S11c.prepareModify` (1.08s) minus `_computeSave.*` (899ms) = ~181ms Overhead für:
- `splitDocument`: BFS + Set-Differenz
- `buildShardAppData`: Erneuter Subgraph + Graph-Erzeugung

Beide nur nötig als Input für den CRDT-Diff, der 100% null liefert.

#### 3. Jelly-Encoding — 226ms (17%)

In [stage11c_shard_merge.dart](../packages/locorda_core/lib/src/sync/pipeline/stages/stage11c_shard_merge.dart):

```dart
if (prepared == null) {
    final encodedBytes = rdfCore.encodeBinary(baseGraph, ...);
```

Stage 13 schreibt **jeden** `MergedShard` in die DB und benötigt `encodedForDb.bytes`. Frage: Ist der DB-Write selbst bei `prepared == null` vermeidbar?

**Zusätzlich:** Shards werden in S12 (ShardUpload) **nochmals** Jelly-encoded → S12.ShardUpload.encode = 1,02s. Zusammen: **1,25s doppeltes Jelly-Encoding für dieselben Shards.**

#### 4. `createOrIncrementClock` — 48ms (4%)

134× `_hashClock()` → N-Quads + MD5. Relativ günstig bei nur 134 Events. Optimierungspotential gering.

### Hypothesen-Validierung Stage 11c

| Hypothese | Ergebnis |
|-----------|----------|
| "Remote-Merge trivial ohne Remote-Daten" | ✅ **Bestätigt** — 38µs total |
| "`_computeSave.appMeta` potenziell dominant" | ✅ **Bestätigt** — 851ms = 65% der Stage |
| "`_computeSave.construct` relevant" | ❌ **Widerlegt** — wird **nie erreicht** (100% return null) |
| "Jelly-Encoding 140× kodieren" | ⚠️ **Teilweise** — 226ms, aber zusätzlich 1,02s in S12 (doppelt!) |
| "~50 Shards mit 'No property changes'" | ❌ **Widerlegt** — **100% der 134 Shards** hatten keine Änderungen |

---

## Übergreifende Erkenntnisse

### 1. Clock-Hash: Teilweise Redundanz (betrifft 7c)

In `reconcileSync` (via `getCurrentClock`) wird der Clock-Hash neu berechnet, obwohl `SyncCandidate.localClockHash` aus Stage 4 bereits vorhanden ist. Im `notInRemoteShard`-Pfad ändert sich der Graph nicht → Hash bleibt identisch.

**Aber:** `getCurrentClock()` liefert nicht nur `hash`, sondern auch `logicalTime`, `physicalTime`, `fullClock` — diese werden downstream für Index-Entries und Metadata benötigt. Eine Optimierung müsste den Hash separat behandeln und die anderen Clock-Felder weiterhin berechnen.

**Gemessen:** 464ms in 7c, 48ms in 11c. Optimierung via direktem Hash-Algorithmus könnte ~300ms sparen.

### 2. 100% verschwendeter CRDT-Diff in 11c — **GRÖSSTER FUND**

`prepareModifyWithContract` führt den **kompletten** Algorithmus durch:
1. `splitDocument` (BFS + Set-Diff)
2. `buildShardAppData` (Subgraph + Graph-Konstruktion)
3. `createOrIncrementClock` (Extract + Hash)
4. `computeCanonicalBlankNodes` × 2 (beide semantisch notwendig!)
5. `_generateCrdtMetadataForChanges` (Voller Subjekt/Prädikat-Diff)

...nur um bei **100% der 134 Shards** `return null` zu liefern.

**Gemessen:** 1,08s (82% der Stage) für ein garantiertes `null`-Ergebnis.  
**Kein Early-Exit**: Es gibt keine günstige Vorstufen-Prüfung ("Hat sich überhaupt etwas geändert?").

### 3. Doppeltes Jelly-Encoding zwischen S11c und S12

Shards werden in S11c encoded (226ms) und in S12.ShardUpload **nochmals** encoded (1,02s).
**Gemessen:** 1,25s gesamt für denselben Inhalt zweimal serialisieren.

### 4. `determineShards()` überraschend teuer in 7c

**909ms (29%)** — ursprünglich als "wahrscheinlich günstig" eingeschätzt. Braucht tiefere Analyse: Was genau macht `determineShards()` pro Ressource, und warum kostet es 59µs?

---

## Optimierungsplan (priorisiert nach gemessenem ROI)

### Priorität 1: Early-Exit in S11c (spart ~1,03s)

| Eigenschaft | Detail |
|-------------|--------|
| **Maßnahme** | Early-Exit in S11c **vor** `prepareModifyWithContract` wenn Entry-Triples unverändert |
| **Einsparung** | ~1,03s (851ms `_computeSave.appMeta` + 181ms Overhead) |
| **Trefferquote** | **100%** der Events im Initial-Sync-Szenario |
| **Risiko** | Niedrig — Skip einer Berechnung die immer `null` liefert |
| **Implementierung** | Schneller Triple-Set-Vergleich der Entry-Triples vor/nach → skip wenn identisch |

### Priorität 2: Doppeltes Jelly-Encoding eliminieren (spart ~1,0s)

| Eigenschaft | Detail |
|-------------|--------|
| **Maßnahme** | Jelly-Bytes aus S11c durchreichen statt in S12 neu zu kodieren |
| **Einsparung** | ~1,02s (S12.ShardUpload.encode) |
| **Risiko** | Mittel — erfordert Pipeline-Typ-Anpassung |
| **Implementierung** | `MergedShard` um `encodedForUpload`-Feld erweitern, in S12 wiederverwenden |

### Priorität 3: `determineShards()` untersuchen & optimieren (potentiell ~500ms)

| Eigenschaft | Detail |
|-------------|--------|
| **Maßnahme** | Tiefere Analyse von `determineShards()` — 909ms war überraschend |
| **Einsparung** | Unklar — braucht erst Verständnis der Kosten |
| **Risiko** | Unbekannt |
| **Nächster Schritt** | Code analysieren, Sub-Messungen hinzufügen |

### Priorität 4: `_hashClock` optimieren (spart ~300ms)

| Eigenschaft | Detail |
|-------------|--------|
| **Maßnahme** | Direkter Hash über sortierte `(installationIri, logicalTime)` statt N-Quads-Umweg |
| **Einsparung** | ~300ms (geschätzt: 464ms → ~150ms) |
| **Risiko** | Niedrig — nur Hash-Algorithmus ändert sich, Semantik bleibt gleich |
| **Implementierung** | `_hashClock()` umschreiben: sortierte Tupel → String-Concat → MD5 |

### Priorität 5: Raw Jelly-Bytes aus DB durchreichen (spart ~1,6s bei Re-Sync)

| Eigenschaft | Detail |
|-------------|--------|
| **Maßnahme** | Bei `hasChanges == false` Raw-Bytes aus DB verwenden statt neu zu kodieren |
| **Einsparung** | ~1,6s (S07c.encode) — aber **nur bei Re-Sync**, nicht bei Initial-Sync |
| **Risiko** | Mittel — `RawStoredDocument` existiert, aber Pfad muss erweitert werden |
| **Kommentar** | Bei Initial-Sync ist `hasChanges` immer `true` (Shard-Assignment) |

### Gesamtpotential

| Optimierung | Einsparung | Anwendbar bei Initial-Sync? |
|-------------|------------|----------------------------|
| #1 Early-Exit S11c | ~1,03s | ✅ Ja |
| #2 Doppel-Encoding | ~1,02s | ✅ Ja |
| #3 determineShards | ~500ms? | ✅ Ja |
| #4 _hashClock | ~300ms | ✅ Ja |
| #5 Raw-Bytes-Reuse | ~1,6s | ❌ Nur Re-Sync |
| **Summe (Initial-Sync)** | **~2,85s** | von 17,74s = **16% der Pipeline** |

---

## Implementierte Sub-Messungen

### Stage 7c (`stage7c_crdt_merge.dart`)

| Label | Was wird gemessen | Gemessen |
|-------|-------------------|----------|
| `S07c.merge` | CRDT-Merge (SyncDirection switch) | 344µs |
| `S07c.reconcile.shards` | `determineShards()` | **909ms** |
| `S07c.reconcile.clock` | `getCurrentClock()` (inkl. `_hashClock`) | **464ms** |
| `S07c.reconcile.replace` | `replaceInDocument()` | 65ms |
| `S07c.indexEntries` | `buildActiveIndexEntries()` | 18ms |
| `S07c.tombstones` | `collectTombstonedShards()` | 40ms |
| `S07c.encode` | `encodeBinary()` (Jelly) | **1,60s** |

### Stage 11c (`stage11c_shard_merge.dart`)

| Label | Was wird gemessen | Gemessen |
|-------|-------------------|----------|
| `S11c.remoteMerge` | Remote-CRDT-Merge | 38µs |
| `S11c.prepareModify` | `prepareModifyWithContract()` gesamt | **1,08s** |
| `S11c.encode` | `encodeBinary()` (Jelly) | 226ms |

### `_computeSaveCore` (`crdt_document_manager.dart`)

| Label | Was wird gemessen | Gemessen |
|-------|-------------------|----------|
| `_computeSave.clock` | `createOrIncrementClock()` | 48ms |
| `_computeSave.appMeta` | `generateMetadata()` für App-Daten | **851ms** |
| `_computeSave.construct` | `_constructCrdtDocument()` + Graph-Assembly | **0ms (nie erreicht!)** |

### `reconcileSync` (`document_shard_reconciler.dart`)

| Label | Was wird gemessen | Gemessen |
|-------|-------------------|----------|
| `S07c.reconcile.shards` | `determineShards()` | **909ms** |
| `S07c.reconcile.clock` | `getCurrentClock()` | **464ms** |
| `S07c.reconcile.replace` | `_shardsChanged()` + `replaceInDocument()` | 65ms |

---

## Nächste Schritte

1. ✅ ~~Sync mit Messungen laufen lassen~~ → Echte Zahlen gesammelt
2. ✅ ~~Report mit echten Zahlen aktualisieren~~ → Hypothesen validiert/widerlegt
3. **Optimierung #1 implementieren** → Early-Exit in S11c (~1,03s Einsparung)
4. **Optimierung #2 implementieren** → Doppeltes Jelly-Encoding eliminieren (~1,02s)
5. **`determineShards()` tiefer analysieren** → Warum 59µs pro Aufruf?
