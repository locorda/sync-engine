# Analyse: `.triples`-Zugriffe & Pipeline-Interleaving

**Datum**: 2026-04-03  
**Kontext**: Performance-Profiling nach S11c-Optimierungen (155.205 Events, 9.376ms Sync-Dauer)

---

## Teil 1: `.triples`-Zugriffe — Audit der Codebase

### Methodik

Systematische Suche nach allen `.triples`-Zugriffen auf `RdfGraph`-Objekte in Produktionscode (`lib/`).  
Ausgeschlossen: Tests, generierter Code, Build-Artefakte.

### Ergebnisse: 33 Fundstellen, 3 Kategorien

#### 🔴 Potenziell optimierbar (Subject/Predicate bekannt) — 3 Stellen

| # | Datei | Code-Muster | Subject bekannt? | Graph-Größe | Hot Path? | Priorität |
|---|-------|-------------|-------------------|-------------|-----------|-----------|
| 1 | `identified_blank_node_builder.dart:230` | `graph.triples.where((t) => blankNodeSubjects.contains(t.object)).fold(...)` | Nein (Objekt-Filter) | 10-50 Triples | Ja (Merge) | **Niedrig** |
| 2 | `hlc_service.dart:236` | `ourClockEntry.$2.triples.where(predicate != ...)` | Ja (`ourClockEntry.$1`) | 3-5 Triples | Ja (Save) | **Keine** |
| 3 | `shard_document_generator.dart:265` | `entry.headerProperties!.triples` → Filter `subject == entry.resourceIri` | Ja (`entry.resourceIri`) | 1-5 Triples | Ja (Shard rebuild) | **Niedrig** |

**Fazit**: Alle drei Fundstellen operieren auf **kleinen Subgraphen** (1-50 Triples). `findTriples()` ohne Subject-Indexing ist ebenfalls O(n). **Kein messbarer Performance-Gewinn** durch Umstellung.

Die einzige **bereits behobene** kritische Stelle war `GroupKeyGenerator.generateGroupKeys()` (group_key_generator.dart), die über den *gesamten* Dokument-RdfGraph (Hunderte Triples inkl. CRDT-Metadaten, Clocks etc.) iterierte — jetzt O(1) mit `subjectIri`.

#### 🟡 Graph-Assembly — Vollständige Iteration korrekt — 17 Stellen

Alle Triples müssen kopiert/zusammengeführt werden. Beispiele:
- `crdt_document_manager.dart:217` — `allTriples.addAll(additionalGraph.triples)`
- `crdt_document_manager.dart:703` — `documentTriples.addAll(appData.triples)`
- `rdf_extensions.dart:157/166/278/483/536` — Graph-Zusammenbau (`withNodes`, `mergeGraphs`, `addNodes`)
- `remote_sync_orchestrator.dart:2953` — `document.triples.toSet()` für Diff
- `local_document_merger.dart:99` — `document.triples.toSet()` für Modifikation
- Diverse Subgraph→Triple-Übernahmen in `shard_document_generator.dart`, `stage11a_prepare.dart`

**→ Korrekt, nicht optimierbar.**

#### 🟢 Kein `RdfGraph.triples` / Debug / Sonstiges — 13 Stellen

- `triplesToRemove` (Feld auf `CrdtMetadataResult`, nicht `RdfGraph`) — 6×
- Debug/Error-Strings — 3×  
- `.triples.length` für Exception-Context — 1×
- DartDoc-Beispiele — 1×
- Andere Pakete (vollständige Kopie) — 2×

**→ Irrelevant.**

### Zusammenfassung Teil 1

```
Kritisch optimierbar:  0  (die einzige kritische Stelle wurde bereits behoben: GroupKeyGenerator)
Marginal optimierbar:  3  (alle auf kleinen Subgraphen, kein messbarer Effekt)
Korrekt / nicht opt.:  30 (Graph-Assembly, Subgraph-Extraktion, Debug, andere Typen)
```

**Kein weiterer Handlungsbedarf bei `.triples`-Zugriffen.**

---

## Teil 2: Pipeline-Interleaving — Analyse

### Die Erwartung vs. Realität

**Erwartung**: Bei einer Pipeline mit IO- und CPU-Stages sollte `total ≈ max(Σ IO, Σ CPU)`, weil IO und CPU **überlappend** arbeiten können.

**Realität**: `total ≈ Σ IO + Σ CPU` — die Pipeline serialisiert vollständig.

### Quantitative IO/CPU-Aufschlüsselung

Aus den Pipeline-Stats (155.205 Events, **9.376ms** Sync-Dauer):

> **Hinweis**: Die ursprüngliche `perf.pipeline`-Ausgabe zeigte 13,19s — das war die Summe ALLER Stage-Zeiten inkl. verschachtelter Sub-Messungen (Doppelzählung). Die tatsächliche Wall-Clock Sync-Dauer war **9.376ms** (`perf.backend syncFunction`).

#### IO-Stages (DB + Remote)

| Stage | Typ | Total | Bemerkung |
|-------|-----|-------|-----------|
| S01 Shard Resolution | DB read | 78ms | 2× bulk DB queries |
| S02 Shard Fetch (io) | Remote IO | 17ms | Batch download |
| S04 Change Detect | DB read | 559ms | ETag-Vergleich pro Entry |
| S05 Local Load | DB read | 1.290ms | Dokument-Laden aus DB |
| S07b Preload (io) | DB read | 570ms | Merge-Contract + Index-Config laden |
| S09 DB Commit | DB write | 577ms | Transaktions-Flush |
| S10 Shard Entry Load | DB read | 278ms | Shard-Entries + Shard-Docs laden |
| S11b Contract Load | DB read | 9,5ms | Shard-Merge-Contracts |
| S12 Upload (dbLoad) | DB read | 26ms | Shard-Daten aus DB |
| S12 Upload (encode) | CPU/DB | 496ms | Jelly-Encoding (CPU, aber im IO-Block) |
| S12 Upload (io) | Remote IO | 68ms | Shard-Upload |
| S13 Shard DB Commit | DB write | 39ms | |
| S14 Feedback | Orchestration | 98ms | |
| **Σ IO** | | **≈ 4,1s** | |

#### CPU-Stages

| Stage | Typ | Total | Bemerkung |
|-------|-----|-------|-----------|
| S03 Shard Parse | CPU | 1,1ms | Trivial |
| S07a Decode | CPU | 999ms | Jelly→RdfGraph (15.440×) |
| S07b Preload (cpu) | CPU | 178ms | Aufbereitung |
| S07c CRDT Merge | CPU | 3.010ms | Kernarbeit (15.440×) |
| S11a Prepare | CPU | 215ms | Shard-Vorbereitung |
| S11c Shard Merge | CPU | 236ms | Shard-CRDT-Merge |
| **Σ CPU** | | **≈ 4,6s** | |

#### Overhead-Rechnung

| | |
|---|---|
| Σ IO | ~4,1s |
| Σ CPU | ~4,6s |
| Σ IO + Σ CPU | ~8,7s |
| Tatsächliche Sync-Dauer | **9,376ms** |
| Overhead (Dart Event-Loop, GC, Scheduling) | **~676ms** (≈ 7%) |
| Theoretisches Minimum bei perfektem Interleaving (`max(IO, CPU)`) | **~4,6s** |

**Beobachtung**: Overhead ist nur ~7% — die Pipeline-Mechanik ist effizient. Das Problem ist **ausschließlich die fehlende Überlappung** von IO und CPU.

### Architektur-Analyse: Warum kein Interleaving

#### Die Pipeline-Topologie

```dart
// streaming_remote_sync_orchestrator.dart, Zeile ~97-122
final pipeline = inputController.stream
    .asyncExpand(shardResolution(...))          // S01 - DB
    .transform(_remote.shardFetch(...))         // S02 - Remote IO
    .map(shardParse(...))                       // S03 - CPU
    .asyncExpand(changeDetection(...))          // S04 - DB
    .transform(localContentLoad(...))           // S05 - DB
    .transform(_remote.resourceFetch(...))      // S06 - Remote IO
    .map(decodeCandidates(...))                 // S07a - CPU
    .transform(preloadCandidates(...))          // S07b - DB + CPU
    .expand(mergeCandidates(...))               // S07c - CPU
    .transform(_remote.resourceUpload(...))     // S08 - Remote IO
    .asyncExpand(dbCommit(...))                 // S09 - DB write
    .asyncExpand(shardEntryLoad(...))           // S10 - DB read
    .expand(prepareShards(...))                 // S11a - CPU
    .asyncMap(loadShardContracts(...))          // S11b - DB
    .expand(mergeShards(...))                   // S11c - CPU
    .transform(_remote.shardUpload(...))        // S12 - Remote IO
    .asyncExpand(shardDbCommit(...))            // S13 - DB write
    .asyncExpand(feedback(...))                 // S14
```

Konsumiert durch: `await pipeline.drain()`

#### Der Serialisierungs-Mechanismus: `asyncExpand` als Backpressure-Barriere

Dart Stream-Operatoren lassen sich in zwei Kategorien teilen:

**Synchrone Operatoren** (`map`, `expand`, `where`): Leiten Events im **selben Microtask** synchron weiter. Kein Scheduling, kein Puffer — ein Event fällt durch alle sync-Stages in einem einzigen Call-Stack:

```
source emits A →
  map(f).handleData(A) →
    expand(g).handleData(f(A)) →
      // Alles im selben Stack-Frame
```

**Asynchrone Operatoren** (`asyncExpand`, `asyncMap`): **Pausieren die Upstream-Subscription** während der inneren Verarbeitung:

```dart
// Dart SDK: asyncExpand Implementierung
subscription.onData((event) {
  subscription.pause();                                      // ← pausiert upstream
  controller.addStream(convert(event))
    .whenComplete(subscription.resume);                      // ← erst nach Abschluss
});
```

Entscheidend: Die **Pause propagiert rückwärts** durch alle synchronen Operatoren bis zur vorherigen `asyncExpand`-Barriere. Die synchronen Stages dazwischen bilden ein **starres Segment** — wenn das downstream-Ende pausiert ist, kann kein Event durch das Segment fließen.

```
         Barriere              sync Segment              Barriere
    ┌──────────────┐    ┌─────────────────────┐    ┌──────────────┐
    │ asyncExpand   │───►│ map ► expand ► where │───►│ asyncExpand  │
    │ (S04: DB)     │    │ (S07a, S07c)         │    │ (S09: DB)    │
    └──────────────┘    └─────────────────────┘    └──────────────┘
                                                        │
                                                   pausiert upstream
                                                   ◄── propagiert zurück
```

**Ergebnis**: Während S09 (DB Commit) arbeitet, ist die gesamte Kette bis S04 pausiert. S04 kann den nächsten Shard nicht laden. Es gibt **kein gleichzeitiges Arbeiten** zwischen Barrieren.

#### Buffer-then-Block-Pattern in IO-Stages

Die Backend-Integration (`file_per_resource_pipeline.dart`) verstärkt das Problem:

```dart
// _pipeDownload / _pipeUpload
final resultStream = backend.download(Stream.fromIterable(requests));
final results = await resultStream.toList();  // ← BLOCKIERT die gesamte Pipeline
```

- Sammelt Events in einen Buffer bis zur Shard-Boundary (gut: Batch-IO)
- `await toList()` blockiert den gesamten `async*`-Generator (schlecht: keine CPU-Arbeit während IO)

Zusätzlich: `DirSyncStorage.download()` arbeitet **sequenziell** pro File:
```dart
await for (final request in requests) {
  yield await _downloadOne(request);  // Ein File nach dem anderen
}
```

### Remote-Backend-Architektur: Bereits für Parallelität designed

Das `RemoteSyncBackend`-Interface ist bewusst als **Stream-in → Stream-out** gestaltet:

```dart
abstract interface class RemoteSyncBackend {
  Stream<RemoteDownloadResult<RawContent>> download(
    Stream<RemoteDownloadRequest> requests);
  Stream<RemoteUploadResult> upload(
    Stream<RemoteUploadRequest<RawContent>> requests);
}
```

Aus der Dokumentation: *"Backends control parallelism themselves — whether sequential, pooled, or using transport-level batching."*

**Aktueller Stand**:
- `DirSyncStorage`: Sequenziell (`await for` + `yield`)
- GDrive/Solid: Noch nicht auf Pipeline migriert (nutzen deprecated `ClassicBackend`)
- Parallele Backends: Interface supported es, aber **kein Backend implementiert es** (ein `maxConcurrentDocumentSyncs` in `RemoteSyncStorage` ist kommentiert mit `// FIXME: concurrent synchronization currently leads to concurrency issues`)

**Für zukünftige Solid/GDrive/WebDAV-Backends** wird paralleles IO innerhalb von `download()`/`upload()` noch wichtiger — die Latenz pro Request ist deutlich höher als bei lokalen Files. Der Stream-basierte Ansatz erlaubt es dem Backend, intern z.B. einen Connection-Pool mit N parallelen HTTP-Requests zu nutzen, ohne dass die Pipeline-Architektur sich ändert.

#### Visualisierung: Ist vs. Soll

**Ist-Zustand** (serialisiert):
```
Zeit: ──────────────────────────────────────────────────►
      [S01:DB][S02:IO][S03:CPU][S04:DB][S05:DB][S07a:CPU][S07b:DB][S07c:CPU][S09:DB]...
      ├──────────── alles sequenziell ──────────────────────────────────────────────┤
```

**Soll-Zustand** (Decoupling-Queues zwischen IO und CPU):
```
Zeit: ──────────────────────────────────────────────────►
IO:   [S04:DB][S05:DB]     [S07b:DB]     [S09:DB]  [S10:DB]     [S12:IO]
CPU:            [S07a:CPU]   [S07c:CPU]     [S11a]  [S11c:CPU]
      ├──────────── IO und CPU überlappen ─────────────────────────────────────────┤
```

### Lösungsansatz: Decoupling-StreamTransformer

#### Warum es funktioniert (trotz Single-Isolate)

Dart ist single-threaded, aber **IO-Operationen yielden zum Event-Loop** während `await`. Ein Decoupling-Punkt zwischen IO-Producer und CPU-Consumer ermöglicht:

1. IO-Stage wartet auf DB-Antwort → yieldet zum Event-Loop
2. Event-Loop gibt Kontrolle an CPU-Consumer → verarbeitet gepuffertes Event
3. CPU-Stage fertig → Event-Loop gibt Kontrolle zurück an IO-Stage (DB-Antwort da)

Das ist **echtes Interleaving** — nicht parallel (gleiche CPU-Kerne), aber **concurrent** (überlappend durch Event-Loop-Scheduling).

#### Konzept: `decouple<T>()` StreamTransformer

Ein generischer StreamTransformer, der einen `StreamController` als Puffer einfügt und damit die Backpressure-Kette unterbricht:

```dart
/// Decouples upstream production from downstream consumption.
///
/// Inserts a [StreamController] as a buffer between pipeline segments.
/// This breaks the [asyncExpand] pause-propagation chain, allowing
/// upstream IO to continue while downstream CPU processes buffered events.
///
/// [maxBuffer] limits memory usage — when the buffer reaches this size,
/// the upstream subscription is paused until downstream catches up.
StreamTransformer<T, T> decouple<T>({int maxBuffer = 64}) {
  return StreamTransformer.fromBind((input) {
    final controller = StreamController<T>();
    int buffered = 0;
    late StreamSubscription<T> subscription;

    subscription = input.listen(
      (event) {
        controller.add(event);
        buffered++;
        if (buffered >= maxBuffer) {
          subscription.pause();  // Backpressure: puffere nicht unbegrenzt
        }
      },
      onError: controller.addError,
      onDone: controller.close,
    );

    // Drain-Feedback: wenn downstream konsumiert, upstream wieder aufwecken
    controller.onListen = () {
      controller.stream.listen(null).onData((_) {
        buffered--;
        if (buffered < maxBuffer) subscription.resume();
      });
    };

    return controller.stream;
  });
}
```

> **Hinweis**: Das obige ist ein vereinfachtes Konzept. Die tatsächliche Implementierung braucht sorgfältiges Lifecycle-Management (cancel, error propagation, backpressure-Hysterese).

#### Wo einsetzen?

An den **neuralgischen Punkten** — dort, wo ein IO-dominanter Block in einen CPU-dominanten Block übergeht:

```dart
final pipeline = inputController.stream
    .asyncExpand(shardResolution(...))          // S01 - DB
    .transform(_remote.shardFetch(...))         // S02 - Remote IO
    .map(shardParse(...))                       // S03 - CPU
    .asyncExpand(changeDetection(...))          // S04 - DB
    .transform(localContentLoad(...))           // S05 - DB
    .transform(_remote.resourceFetch(...))      // S06 - Remote IO
    // ═══════════════════════════════════════════
    .transform(decouple(maxBuffer: 128))        // ★ DECOUPLE: IO→CPU
    // ═══════════════════════════════════════════
    .map(decodeCandidates(...))                 // S07a - CPU
    .transform(preloadCandidates(...))          // S07b - mixed
    .expand(mergeCandidates(...))               // S07c - CPU
    .transform(_remote.resourceUpload(...))     // S08 - Remote IO
    .asyncExpand(dbCommit(...))                 // S09 - DB write
    .asyncExpand(shardEntryLoad(...))           // S10 - DB read
    // ═══════════════════════════════════════════
    .transform(decouple(maxBuffer: 16))         // ★ DECOUPLE: IO→CPU
    // ═══════════════════════════════════════════
    .expand(prepareShards(...))                 // S11a - CPU
    .asyncMap(loadShardContracts(...))          // S11b - DB
    .expand(mergeShards(...))                   // S11c - CPU
    .transform(_remote.shardUpload(...))        // S12 - Remote IO
    .asyncExpand(shardDbCommit(...))            // S13 - DB write
    .asyncExpand(feedback(...))                 // S14
```

**Effekt**: 
- **Decouple 1** (nach S06): S04/S05/S06 können den nächsten Shard laden, während S07a/S07c den aktuellen verarbeiten
- **Decouple 2** (nach S10): S10 kann Shard-Entries laden, während S11a/S11c den aktuellen Shard mergen

#### Erwarteter Gewinn

| Szenario | Sync-Dauer | Bemerkung |
|----------|------------|-----------|
| Ist (Dir, kein Interleaving) | 9,4s | IO + CPU serialisiert |
| Mit Decoupling (Dir) | ~5-6s | CPU + IO überlappen, DB bleibt seriell (Drift) |
| Mit Decoupling + parallelem Remote-Backend | ~4,5-5s | Backend nutzt Connection-Pool |
| Theoretisches Minimum | ~4,6s | max(Σ IO, Σ CPU) |

#### Zusammenspiel mit Remote-Backends

Der Decoupling-Transformer ergänzt die **bereits vorhandene** Backend-Parallelitäts-Architektur:

```
                          Decoupling-Transformer
                               (Pipeline-Level)
                                     │
                   ┌─────────────────┴──────────────────┐
                   │                                     │
          IO-Segment                            CPU-Segment
    (S04→S05→S06→...)                      (S07a→S07c→S09→...)
           │                                       │
    RemoteSyncBackend                         Sync CPU-Arbeit
    (Backend-Level)                           (CRDT Merge etc.)
           │
    ┌──────┴──────┐
    │             │
  Sequential   Parallel Pool
  (Dir)        (Solid/GDrive/WebDAV)
```

**Zwei orthogonale Parallelitäts-Ebenen**:
1. **Pipeline-Decoupling**: IO-Segment und CPU-Segment arbeiten concurrent über den Event-Loop
2. **Backend-Parallelität**: Innerhalb des IO-Segments kann das Backend selbst parallel arbeiten (Connection-Pool für HTTP-Backends)

Beide Mechanismen sind **unabhängig konfigurierbar** und stacken multiplikativ.

---

## Anhang: `findTriples` API-Signatur

```dart
List<Triple> findTriples({
  RdfSubject? subject,
  Iterable<RdfSubject>? subjectIn,
  RdfPredicate? predicate,
  Iterable<RdfPredicate>? predicateIn,
  RdfObject? object,
  Iterable<RdfObject>? objectIn,
})
```

- **O(1)** bei Subject-basierter Query (interner Subject→Predicate-Index)
- **O(n)** bei Predicate-only oder Object-only Query (kein Index dafür)
