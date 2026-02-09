# Worker Isolate Architecture - Implementation Plan

## Status: DRAFT - Ready for Implementation
**Created:** 2025-10-28  
**Updated:** 2025-10-28  
**Target:** Performance optimization for web/mobile through isolate-based architecture

## 🎯 Goal

Move heavy operations (CRDT merge, database, HTTP, DPoP) to separate isolate/worker to keep main thread responsive, especially on web platform.

## 📊 Performance Validation (COMPLETED ✅)

Benchmarks prove Turtle serialization is fast enough for worker architecture:
- **Single Note round-trip**: <2ms (Native), <2ms (Web)
- **10 Notes batch**: <10ms (Native), <10ms (Web)  
- **50 Notes batch**: <35ms (Native), <35ms (Web)

**Conclusion**: Serialization overhead is negligible (10-100x faster than target) compared to CRDT/DB/HTTP operations.

---

## 🏗️ Final Architecture Design

### Current Architecture (Single Thread)
```
Main Thread
├── Locorda (Dart objects with RdfMapper)
│   └── SyncEngine (RDF operations)
│       └── StandardsyncEngine
│           ├── CrdtDocumentManager (CRDT merge)
│           ├── Storage (Drift/SQLite)
│           ├── Backend (HTTP to Solid Pod)
│           └── SyncManager
```

### Target Architecture (Worker-Based)
```
Main Thread                                    Worker Isolate
├── Locorda (Dart objects)                
│   ├── RdfMapper (Dart ↔ RDF)
│   └── ProxysyncEngine ----[Turtle]----> StandardsyncEngine
│       └── Message Protocol                     ├── CrdtDocumentManager
│                                                ├── Storage (DriftIsolate)
│                                                ├── Backend (HTTP)
│                                                └── SyncManager
```

**Key Design Principles:**

1. **Clean Separation of Concerns**:
   - **Main Thread**: Handles Dart objects, RdfMapper, UI state
   - **Worker Thread**: Handles RDF operations, CRDT merge, storage, HTTP

2. **Config Transmission Strategy**:
   - Main: `SyncConfig` (Dart Types) → `toSyncEngineConfig()` → `SyncEngineConfig` (IRIs only)
   - Worker: Receives serialized `SyncEngineConfig` via JSON
   - **No duplication**: Config created once in Main, automatically transmitted

3. **Dependency Injection Solution**:
   - Main: User passes `mapperInitializer` (needed for Dart objects)
   - Worker: User writes ~15 lines to instantiate `storage` + `backends`
   - Framework handles config transmission, message protocol, serialization

4. **Platform Abstraction**:
   - Framework provides `LocordaWorker.start(dartScript:, jsScript:)`
   - Platform detection (`kIsWeb`) hidden inside framework
   - User code never checks platform explicitly

---

## 🚧 Final Solution: Config Transmission + Minimal User Code

### Problem Overview
Initial approaches had issues:
- ❌ Config-based factories: Not extensible for custom implementations
- ❌ User-written factories: Too much boilerplate (duplicated setup)

### Final Solution: Automatic Config Transmission

**Key Insight**: Worker doesn't need Dart types, only RDF (IRIs). Config can be automatically converted and transmitted.

**Main Thread API** (application code):
```dart
// packages/locorda/example/personal_notes_app/lib/main.dart
Future<void> main() async {
  // 1. Create worker handle (framework abstracts platform)
  final workerHandle = await LocordaWorker.start(
    workerEntryPoint: workerMain,  // Function reference for native
    jsScript: 'worker.dart.js',     // Compiled JS for web
  );
  
  // 2. Setup with worker - config automatically transmitted
  final sync = await Locorda.setupWithWorker(
    worker: workerHandle,
    config: _buildConfig(),            // SyncConfig with Dart Types
    mapperInitializer: _initMapper,    // Only needed on Main thread
  );
  
  // 3. Setup Solid authentication (optional, only if using Solid backend)
  final solidAuth = SolidAuth(/* ... */);
  final authBridge = SolidAuthBridge.forWorker(
    solidAuth,
    workerHandle,  // Auth bridge handles key + token transmission internally
  );
  
  // Auth bridge automatically loads DPoP key and forwards all credentials to worker
  
  runApp(MyApp(sync: sync, solidAuth: solidAuth));
}
```

**Worker Thread Code** (user writes ~15 lines):
```dart
// lib/worker.dart
import 'package:locorda/worker.dart';
import 'package:locorda_drift/locorda_drift.dart';
import 'package:locorda_solid/locorda_solid.dart';

void main() => runLocordaWorker();

void runLocordaWorker() {
  workerMain((config, context) async {  // config + context from framework
    // User instantiates storage + backends normally
    final storage = DriftStorage(
      web: DriftWebOptions(/* ... */),
      native: DriftNativeOptions(/* ... */),
    );
    
    final backends = [
      SolidBackend(
        // Context provides communication channel for auth
        authProvider: SolidWorkerAuthProvider(context.channel),
      ),
    ];
    
    // Return parameters - framework creates SyncEngine from these
    return EngineParams(
      storage: storage,
      backends: backends,
      // config is passed separately to SyncEngine.createForParams()
    );
  });
}
```

**What Happens Behind the Scenes**:
1. Main validates `SyncConfig`, builds `ResourceTypeCache`
2. Main converts: `SyncConfig` → `toSyncEngineConfig()` → `SyncEngineConfig` (IRIs only)
3. Main serializes `SyncEngineConfig` to JSON
4. Main sends JSON to Worker via `WorkerHandle`
5. Worker deserializes to `SyncEngineConfig`
6. Worker runs user's setup function, passing config
7. Worker creates `StandardsyncEngine` with config
8. Worker wraps it in message handler
9. Main wraps worker in `ProxysyncEngine`
10. Main creates `Locorda` with proxy + mapper

### Challenge 2: Authentication Flow (Local DPoP Generation)

**Problem**: Solid authentication happens in main thread (Flutter UI), but HTTP requests run in worker.

**Solution**: `SolidAuthBridge.forWorker()` internally loads DPoP key and sends all credentials to worker.

```dart
// Main Thread: SolidAuthBridge handles all auth complexity internally
final solidAuth = SolidAuth(/* ... */);
final authBridge = SolidAuthBridge.forWorker(
  solidAuth,
  workerHandle,
);

// Internally, SolidAuthBridge does:
// 1. Listen to solidAuth.authStateChanges (sign in events)
// 2. On sign in: Load DPoP private key from secure storage
// 3. On sign in: Get current access token + ID token
// 4. Send credentials (tokens + DPoP key) to worker
// 5. Listen to token refresh events and forward to worker
// 6. On logout: Send logout message to clear credentials
// User code doesn't need to know about DPoP key or token management!
```

**Sign In Flow** (happens when user authenticates, not at app start):
```
Main Thread                              Worker Thread
    │                                        │
    │  User clicks "Sign In"                │
    │  SolidAuth.signIn() completes         │
    │                                        │
    │  SolidAuthBridge detects sign in      │
    │     - Load DPoP key from storage      │
    │     - Get access token + ID token     │
    │                                        │
    │  Send Credentials on Sign In          │
    ├───────────────────────────────────────>│ Cache: token + key
    │     { accessToken, idToken, dpopKey } │
    │                                        │
```

**Token Refresh Flow**:
```
Main Thread                              Worker Thread
    │                                        │
    │  User triggers login/refresh          │
    │  SolidAuth emits new tokens           │
    │                                        │
    │  3. Send Updated Credentials          │
    ├───────────────────────────────────────>│ Update cached token
    │     { accessToken, idToken }          │ (dpopKey unchanged)
    │                                        │
```

// Worker Thread: Generate DPoP tokens locally (NO roundtrip to main!)
class SolidWorkerAuthProvider implements SolidAuthProvider {
  final WorkerChannel _channel;
  AccessToken? _cachedAccessToken;
  JWK? _dpopPrivateKey;  // Cached private key from main thread
  
  SolidWorkerAuthProvider(this._channel) {
    // Listen for credential updates from main thread
    _channel.messages
      .where((msg) => msg is AuthCredentialsUpdate)
      .listen((msg) {
        // Handle initial setup, refresh, logout, new login
        _cachedAccessToken = msg.accessToken;
        _cachedIdToken = msg.idToken;
        
        // DPoP key only sent on initial setup or new login
        if (msg.dpopPrivateKey != null) {
          _dpopPrivateKey?.clear();  // Clear old key
          _dpopPrivateKey = msg.dpopPrivateKey;
        }
        
        // On logout: clear credentials
        if (msg.accessToken == null) {
          _cachedAccessToken = null;
          _cachedIdToken = null;
          _dpopPrivateKey?.clear();
          _dpopPrivateKey = null;
        }
      });
  }
  
  @override
  Future<String?> getAccessToken() async {
    return _cachedAccessToken?.value;
  }
  
  @override
  Future<String?> getDpopToken(String url, String method) async {
    if (_dpopPrivateKey == null) return null;
    
    // Generate DPoP JWT locally - NO main thread roundtrip!
    return _generateDpopJwt(
      privateKey: _dpopPrivateKey!,
      htm: method,
      htu: url,
      iat: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ath: _hashAccessToken(_cachedAccessToken?.value),
    );
  }
  
  String _generateDpopJwt({required JWK privateKey, ...}) {
    // Sign JWT with ES256 using private key (Web Crypto API / pointycastle)
    // JWT structure: { typ: "dpop+jwt", alg: "ES256", jwk: publicKey }
    // JWT payload: { jti: uuid, htm, htu, iat, ath }
  }
  
  void dispose() {
    // Explicit cleanup on worker shutdown
    _dpopPrivateKey?.clear();
    _dpopPrivateKey = null;
  }
}
```

**Credential Lifecycle**:
```
Main Thread                              Worker Thread
    │                                        │
    │  1. Sign In (user authenticates)      │
    ├───────────────────────────────────────>│ Cache: token + key
    │     { accessToken, idToken, dpopKey } │
    │                                        │
    │                                        │ <HTTP request>
    │                                        ├─ Generate DPoP (local)
    │                                        ├─ Make HTTP request
    │                                        │
    │  2. Token Refresh (periodic)          │
    ├───────────────────────────────────────>│ Update token only
    │     { accessToken, idToken }          │ (dpopKey unchanged)
    │                                        │
    │  3. Logout                             │
    ├───────────────────────────────────────>│ Clear credentials
    │     { accessToken: null }              │ (dpopKey cleared)
    │                                        │
    │  4. New Sign In (after logout)        │
    ├───────────────────────────────────────>│ New credentials
    │     { accessToken, idToken, dpopKey } │ (new key pair!)
```

**Performance Benefits**:
- ✅ **No roundtrips** for DPoP generation (was: 2ms per HTTP request)
- ✅ **100 HTTP requests**: 0ms overhead (vs. 200ms with roundtrips)
- ✅ **Worker autonomy**: All HTTP operations self-contained

**Security Considerations**:
- ✅ Private key transmitted over secure intra-process channel (Native) or same-origin postMessage (Web)
- ✅ No additional exposure vs. keeping key in main thread
- ✅ Explicit cleanup on worker disposal
- ⚠️ Key stays in worker memory for worker lifetime (acceptable trade-off for performance)

### Challenge 3: Platform Abstraction (Hidden from User)

**Framework provides platform-transparent API**:

```dart
/// Platform-agnostic worker handle factory.
abstract class LocordaWorker {
  /// Auto-detects platform and uses appropriate script.
  static Future<LocordaWorker> create({
    required void Function(SendPort) workerEntryPoint,  // For native
    required String jsScript,                            // For web
    String? debugName,
  }) async {
    if (kIsWeb) {
      return _WebWorkerHandle(jsScript, debugName);
    } else {
      return _NativeWorkerHandle(workerEntryPoint, debugName);
    }
  }
  
  /// Builder pattern for advanced configuration.
  static LocordaWorkerHandleBuilder builder() => LocordaWorkerHandleBuilder._();
  
  /// Explicit single-platform factories (throw if wrong platform).
  static Future<LocordaWorker> forDart(
    void Function(SendPort) workerEntryPoint,
  ) { ... }
  static Future<LocordaWorker> forWeb(String jsScript) { ... }
  
  // Internal message protocol
  void sendMessage(Object message);
  Stream<Object> get messages;
  Future<void> dispose();
}
```

**Native Implementation** (Isolate.spawn):
```dart
class _NativeWorkerHandle implements LocordaWorker {
  final SendPort _sendPort;
  final ReceivePort _receivePort;
  
  static Future<_NativeWorkerHandle> create(
    void Function(SendPort) workerEntryPoint,
    String? debugName,
  ) async {
    final receivePort = ReceivePort();
    
    final isolate = await Isolate.spawn(
      workerEntryPoint,
      receivePort.sendPort,
      debugName: debugName,
    );
    
    final sendPort = await receivePort.first as SendPort;
    return _NativeWorkerHandle(sendPort, receivePort);
  }
  
  @override
  void sendMessage(Object message) => _sendPort.send(message);
  
  @override
  Stream<Object> get messages => _receivePort;
}
```

**Web Implementation** (Web Worker):
```dart
class _WebWorkerHandle implements LocordaWorker {
  final Worker _worker;
  final StreamController<Object> _controller = StreamController.broadcast();
  
  static Future<_WebWorkerHandle> create(String jsScript) async {
    final worker = Worker(jsScript);
    final handle = _WebWorkerHandle._(worker);
    
    worker.onMessage.listen((event) {
      handle._controller.add(event.data);
    });
    
    // Wait for 'ready' message
    await handle.messages.firstWhere((msg) => msg == 'ready');
    
    return handle;
  }
  
  @override
  void sendMessage(Object message) => _worker.postMessage(message);
  
  @override
  Stream<Object> get messages => _controller.stream;
}
```

---

## 📋 Implementation Phases

### Phase 1: Worker Handle Infrastructure ⏳

**Goal**: Platform-transparent worker creation and message protocol.

**Deliverables**:
1. `LocordaWorker` abstract class + factory methods
2. `_NativeWorkerHandle` with Isolate.spawn
3. `_WebWorkerHandle` with Web Worker
4. `LocordaWorkerHandleBuilder` for advanced config
5. Message serialization protocol (JSON-based)

**Files**:
- `packages/locorda/lib/src/worker/worker_handle.dart` - Abstract interface
- `packages/locorda/lib/src/worker/native_worker_handle.dart` - Native impl
- `packages/locorda/lib/src/worker/web_worker_handle.dart` - Web impl
- `packages/locorda/lib/src/worker/worker_messages.dart` - Message types

**Tests**:
- Worker handle creation on both platforms
- Message send/receive round-trips
- Error handling (worker crash, timeout)
- Platform detection logic

### Phase 2: Config Serialization ⏳

**Goal**: Enable `SyncEngineConfig` transmission across isolate boundary.

**Deliverables**:
1. Add `toJson()` methods to all config types (✅ `fromJson()` already exists)
2. JSON serialization for: `SyncEngineConfig`, `ResourceGraphConfig`, `IndexGraphConfig`, etc.
3. Validation that serialization preserves semantics

**Files**:
- `packages/locorda_core/lib/src/config/sync_graph_config.dart` - Add `toJson()` methods

**Tests**:
- Round-trip serialization for all config types
- Validation errors for invalid JSON
- Large config serialization performance

**Note**: 
- ✅ `fromJson()` factory constructors already implemented for all config types
- ⏳ `toJson()` methods still need to be added
- ✅ Existing `toSyncEngineConfig()` converter in `packages/locorda/lib/src/config/sync_config_converter.dart` handles SyncConfig → SyncEngineConfig conversion

### Phase 3: Proxy Implementation ⏳

**Goal**: Main thread proxy that forwards operations to worker.

**Deliverables**:
1. `ProxysyncEngine` implementing `SyncEngine` interface
2. RDF ↔ Turtle serialization for all operations
3. Request/response message protocol with IDs
4. Stream forwarding for hydration/sync status

**Files**:
- `packages/locorda/lib/src/worker/proxy_sync_engine.dart`
- `packages/locorda/lib/src/worker/worker_message_protocol.dart`

**Operations to Proxy**:
- `save(typeIri, graph)` → Serialize graph to Turtle → Send to worker
- `deleteDocument(typeIri, iri)` → Forward to worker
- `ensure(typeIri, iri, ...)` → Forward + deserialize response
- `hydrateStream(...)` → Stream bridge with Turtle deserialization
- `configureGroupIndexSubscription(...)` → Forward to worker
- `syncManager` operations → Forward all sync methods

**Tests**:
- Each operation proxied correctly
- Stream forwarding (hydration, sync status)
- Error propagation from worker to main
- Concurrent operations with request IDs

### Phase 4: Worker Entry Point & Setup ⏳

**Goal**: Framework helpers for worker-side setup.

**Deliverables**:
1. `workerMain()` helper function
2. `WorkerAuthBridge` for auth token requests
3. Worker message handler loop
4. `Locorda.setupWithWorker()` factory method

**Files**:
- `packages/locorda/lib/src/worker/worker_main.dart` - Entry point helper
- `packages/locorda/lib/src/worker/worker_auth_bridge.dart` - Auth bridge
- `packages/locorda/lib/src/locorda_sync.dart` - Add `setupWithWorker()`

**Worker Main Pattern**:
```dart
void workerMain(
  Future<SyncEngine> Function(
    SyncEngineConfig config,
    WorkerContext context,
  ) setupFn
) async {
  // 1. Establish communication with main thread
  // 2. Receive SyncEngineConfig
  // 3. Create WorkerContext with communication channel
  // 4. Call user's setupFn with config + context
  // 5. Start message loop forwarding to SyncEngine
}

/// Context provided to worker setup function
class WorkerContext {
  /// Communication channel for auth and other cross-thread needs
  final WorkerChannel channel;
  
  WorkerContext(this.channel);
}
```

**Tests**:
- Worker setup with config transmission
- Auth token request/response cycle
- Worker-side error handling
- Graceful shutdown

### Phase 5: Auth Bridge Integration ⏳

**Goal**: Auth token + DPoP private key flow from main to worker, local DPoP generation.

**Deliverables**:
1. Main-side `SolidAuthBridge` streaming tokens + DPoP key to worker
2. Worker-side `SolidWorkerAuthProvider` generating DPoP tokens locally
3. Token + key cache in worker (no main thread round-trips)
4. Explicit memory cleanup on worker disposal

**Files**:
- `packages/locorda_solid/lib/src/worker/solid_auth_bridge.dart` - Main side
- `packages/locorda_solid/lib/src/worker/solid_worker_auth_provider.dart` - Worker side
- `packages/locorda/lib/src/worker/worker_context.dart` - Worker context with channel

**Tests**:
- Auth token updates flow to worker
- DPoP key transmission and caching
- Local DPoP token generation (no roundtrips)
- Token expiration handling
- Explicit key cleanup on disposal

### Phase 6: Integration & Documentation ⏳

**Goal**: End-to-end testing and user documentation.

**Deliverables**:
1. Example app updated to use worker mode
2. Performance comparison tests (with/without worker)
3. Migration guide for existing apps
4. API documentation

**Files**:
- `packages/locorda/example/personal_notes_app/lib/worker.dart` - Example worker
- `packages/locorda/example/personal_notes_app/lib/main.dart` - Updated setup
- `WORKER-MIGRATION-GUIDE.md` - Migration docs

**Tests**:
- Full CRUD cycle through worker
- Sync operations with Solid Pod
- Group index subscriptions
- Error scenarios (worker crash, timeout, network errors)

**Performance Targets**:
- P95 < 5ms for save/delete operations (was: <16ms frame budget - revised based on discussion)
- No UI jank during heavy sync
- Memory usage comparable to non-worker mode

---

## 📊 Success Criteria

1. **Performance** ✅
   - [x] Serialization benchmarks validate approach (<2ms per operation)
   - [ ] P95 latency < 5ms for 99% of operations (validated empirically with real app)
   - [ ] No dropped frames during sync on 60fps devices

2. **API Quality** ⏳
   - [ ] User code: 1-line change for main thread (`setupWithWorker()`)
   - [ ] User code: ~15 lines for worker setup
   - [ ] Zero platform-specific checks in user code (`kIsWeb` hidden)
   - [ ] Config created once (Main), automatically transmitted

3. **Correctness** ⏳
   - [ ] All existing tests pass with worker mode
   - [ ] CRDT semantics preserved across isolate boundary
   - [ ] Sync operations identical behavior to non-worker mode

4. **Robustness** ⏳
   - [ ] Worker crashes handled gracefully
   - [ ] Message timeouts detected and recovered
   - [ ] Auth token expiration handled correctly
   - [ ] Platform differences abstracted

---

## 🔄 Migration Path

### For New Projects
```dart
// Just use setupWithWorker() from the start
final worker = await LocordaWorker.start(
  workerEntryPoint: workerMain,
  jsScript: 'worker.dart.js',
);

final sync = await Locorda.setupWithWorker(
  worker: worker,
  config: config,
  mapperInitializer: initMapper,
);
```

### For Existing Projects

**Option 1: Keep Current (No Changes)**
- Continue using `Locorda.setup()` directly
- Performance fine for native apps with moderate data

**Option 2: Migrate to Worker**
1. Create `lib/worker.dart` with ~15 lines of setup code
2. Compile web worker: `dart compile js -o web/worker.dart.js lib/worker.dart`
3. Change one line in `main.dart`: `setup()` → `setupWithWorker()`

---

## 🎯 Next Steps

**Discussion Points:**
1. ✅ Validate final API design (config transmission approach)
2. ⏳ Approve implementation phases
3. ⏳ Begin Phase 1 (Worker Handle Infrastructure)

**Open Questions:**
- None remaining - design finalized through iterative discussion

**Future Improvements** (separate topics):
- 🔮 **Auto-compile JS worker**: Eliminate need for manual `dart compile js` and explicit `jsScript` parameter
  - Could use runtime compilation in dev mode
  - Or build-time integration (flutter_tools plugin)
  - Or code generation
  - Would simplify API to just `workerEntryPoint` parameter

**Ready to Implement**: Phase 1 can begin immediately.

---

### Phase 3: Proxy Implementation

**Goal**: Create `ProxysyncEngine` that forwards to worker

**Files to create**:
- [ ] `locorda_core/lib/src/proxy_sync_engine.dart`
- [ ] `locorda_core/lib/src/proxy_sync_manager.dart`

**Files to modify**:
- [ ] `locorda_core/lib/src/sync_engine.dart` - Update `.setup()` to use proxy

**Message Protocol**:
```dart
abstract class WorkerMessage {}

class SetupRequest extends WorkerMessage {
  final WorkerSetupConfig config;
}

class SaveRequest extends WorkerMessage {
  final String typeIri;      // Serialized IriTerm
  final String appDataTurtle; // Serialized RdfGraph
}

class SaveResponse extends WorkerMessage {
  final bool success;
  final String? error;
}

class HydrateStreamRequest extends WorkerMessage {
  final String typeIri;
  final String? indexName;
  final String? cursor;
  final int initialBatchSize;
}

class HydrationBatchMessage extends WorkerMessage {
  final List<(String id, String turtleGraph)> updates;
  final List<(String id, String turtleGraph)> deletions;
  final String? cursor;
}

class SyncTriggerRequest extends WorkerMessage {}
class SyncStateUpdate extends WorkerMessage {
  final SyncState state; // Serializable
}

class AuthCredentialsUpdate extends WorkerMessage {
  final AccessToken? accessToken;
  final String? idToken;
  final JWK? dpopPrivateKey;  // DPoP private key (JWK format)
}
```

**Tests**:
- [ ] `locorda_core/test/proxy_sync_engine_test.dart`

**Success Criteria**:
- ✅ `ProxysyncEngine` implements all `SyncEngine` methods
- ✅ All operations correctly forwarded to worker
- ✅ Errors properly propagated back to main thread

---

### Phase 4: Auth Bridge

**Goal**: Implement bi-directional auth communication

**Files to create**:
- [ ] `locorda_core/lib/src/worker/auth/worker_auth_manager.dart`
- [ ] `locorda_core/lib/src/worker/auth/auth_message.dart`

**Files to modify**:
- [ ] `locorda_solid/lib/src/solid_backend.dart` - Accept auth via messages
- [ ] `locorda_solid_auth/lib/src/solid_auth_bridge.dart` - Forward token updates

**Tests**:
- [ ] `locorda_core/test/worker/auth_bridge_test.dart`

**Success Criteria**:
- ✅ Main thread can update auth tokens in worker
- ✅ Worker can request DPoP tokens from main thread
- ✅ Auth works seamlessly across isolate boundary

---

### Phase 5: Stream Handling

**Goal**: Properly handle reactive streams across isolate boundary

**Challenge**: `hydrateStream()` returns `Stream<HydrationBatch>` - needs careful handling

**Approach**:
```dart
class ProxysyncEngine {
  Stream<HydrationBatch> hydrateStream(...) {
    final controller = StreamController<HydrationBatch>();
    
    // Request worker to start streaming
    _worker.send(HydrateStreamRequest(...));
    
    // Listen for batch messages
    _worker.messages
      .where((msg) => msg is HydrationBatchMessage)
      .listen((msg) {
        final batch = _deserializeBatch(msg);
        controller.add(batch);
      });
    
    return controller.stream;
  }
}
```

**Files to modify**:
- [ ] `locorda_core/lib/src/proxy_sync_engine.dart` - Stream adapters

**Tests**:
- [ ] `locorda_core/test/proxy_hydration_stream_test.dart`

**Success Criteria**:
- ✅ Hydration streams work across isolate boundary
- ✅ Proper stream cancellation/cleanup
- ✅ No memory leaks

---

### Phase 6: Integration & Migration

**Goal**: Update example app and run full integration tests

**Files to modify**:
- [ ] `locorda/lib/src/locorda_sync.dart` - Use proxy by default
- [ ] `locorda/example/personal_notes_app/lib/main.dart` - Update initialization

**Tests**:
- [ ] Run existing example app tests
- [ ] Performance tests to verify improvement
- [ ] Full sync cycle tests

**Success Criteria**:
- ✅ Example app works with worker architecture
- ✅ UI stays responsive during sync
- ✅ All existing tests pass
- ✅ Performance benchmarks improved

---

### Phase 7: Documentation & Cleanup

**Goal**: Document new architecture and clean up

**Files to create/update**:
- [ ] `spec/docs/WORKER-ARCHITECTURE.md` - Architecture documentation
- [ ] `MIGRATION-GUIDE.md` - For existing users
- [ ] API documentation updates

**Success Criteria**:
- ✅ Clear documentation of worker architecture
- ✅ Migration guide for existing users
- ✅ Performance characteristics documented

---

## 🔍 Open Questions

1. **DriftIsolate Setup**: How to configure Drift to run in worker isolate on web?
   - Current: `DriftStorage(web: webOptions)` uses `driftWorker.js`
   - Need: DriftIsolate within our worker isolate?
   - **Answer needed**: Check Drift documentation for nested isolate support

2. **Error Handling**: How to handle worker crashes?
   - Should we auto-restart worker?
   - How to preserve state?

3. **Debugging**: How to debug worker code effectively?
   - DevTools support?
   - Logging strategy?

4. **Memory Management**: How to prevent memory leaks with long-lived streams?
   - Stream controller cleanup
   - Worker resource limits?

---

## 📦 Deliverables Summary

**New Packages**: None (all in existing packages)

**New Files** (~15-20 files):
- Worker infrastructure (proxy, messages, platform-specific)
- Configuration serialization
- Auth bridge
- Documentation

**Modified Files** (~8-10 files):
- `SyncEngine.create()` to use proxy
- Storage/Backend factories for config-based creation
- Auth bridge to forward tokens
- Example app initialization

**Tests** (~10-15 new test files):
- Worker communication
- Config serialization
- Proxy forwarding
- Auth bridge
- Stream handling
- Integration tests

---

## 🎯 Success Metrics

**Performance**:
- [ ] Main thread frame rate >55fps during sync (target: 60fps)
- [ ] Save operation main thread time <5ms
- [ ] UI interactions <16ms latency during heavy sync

**Functionality**:
- [ ] All existing tests pass
- [ ] No regressions in functionality
- [ ] Proper error handling and recovery

**Code Quality**:
- [ ] Clean separation of concerns
- [ ] Comprehensive test coverage
- [ ] Clear documentation

---

## 🚀 Next Steps

**Immediate Actions**:
1. Verify DriftIsolate support for nested workers
2. Create proof-of-concept for worker spawning
3. Design detailed message protocol
4. Start Phase 1 implementation

**Decision Points**:
- [ ] Approve overall architecture design
- [ ] Approve message protocol
- [ ] Approve configuration strategy
- [ ] Approve auth bridge approach

---

**Ready to proceed?** Let me know if you want to discuss any aspects or start implementation!
