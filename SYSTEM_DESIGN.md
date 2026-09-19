# Everything-macOS: System Design Document

## Executive Summary

This document describes the system design for **Everything-macOS**, an instant file search engine for macOS built on APFS internals. The design mirrors voidtools Everything for Windows but adapts to macOS/APFS architecture.

**Core Design Principle**: Bypass the VFS layer entirely for initial indexing and real-time monitoring, maintaining a complete in-memory filesystem metadata image with bytecode-compiled search execution.

---

## 1. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            Everything-macOS System                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────┐     XPC/IPC      ┌──────────────────────────────────┐   │
│  │  UI Process  │ ◄──────────────► │     Privileged Helper (XPC)      │   │
│  │  (Sandboxed) │                  │        (Root, Unsanitized)       │   │
│  └──────────────┘                  └──────────────────────────────────┘   │
│        │                                    │                              │
│        │ Search Queries                     │ Raw Block Device Access      │
│        │ Results                            │ /dev/diskXsY                 │
│        ▼                                    ▼                              │
│  ┌──────────────┐                  ┌──────────────────────────────────┐   │
│  │ In-Memory    │                  │  APFS FS-Tree Enumeration        │   │
│  │ Index        │                  │  + EndpointSecurity Monitoring   │   │
│  │ (Bytecode VM)│                  │  + FSEvents Fallback             │   │
│  └──────────────┘                  └──────────────────────────────────┘   │
│        │                                    │                              │
│        │ Persistence                        │ Volume Identity Mapping      │
│        ▼                                    ▼                              │
│  ┌──────────────┐                  ┌──────────────────────────────────┐   │
│  │ Everything.db│                  │  DeviceID → VolumeIdentity       │   │
│  │ (LZ4/ZSTD)   │                  │  (APFS UUID, volfs ID, fileref)  │   │
│  └──────────────┘                  └──────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Process Separation

| Process | Privilege | Responsibility | Sandbox |
|---------|-----------|----------------|---------|
| **Everything.app** | User | UI, search, settings, results display | Full App Sandbox |
| **EverythingHelper.xpc** | Root (via SMJobBless) | Raw device I/O, EndpointSecurity, snapshot mount | No sandbox (system extension) |

---

## 2. Component Design

### 2.1 Privileged Helper (EverythingHelper.xpc)

**Location**: `/Library/PrivilegedHelperTools/com.everything.helper`
**LaunchDaemon**: `/Library/LaunchDaemons/com.everything.helper.plist`

#### XPC Protocol
```swift
// EverythingHelperProtocol.swift
protocol EverythingHelperProtocol {
    // Volume management
    func enumerateVolumes(completion: @escaping ([VolumeInfo]) -> Void)
    func getVolumeIdentity(deviceID: dev_t, completion: @escaping (VolumeIdentity?) -> Void)
    
    // Initial indexing
    func startFullScan(volumeUUID: UUID, 
                       progress: @escaping (ScanProgress) -> Void,
                       completion: @escaping (Result<ScanResult, Error>) -> Void)
    func cancelScan(volumeUUID: UUID)
    
    // Real-time monitoring
    func subscribeToEvents(_ events: [ES.EventType],
                           volumeUUID: UUID,
                           handler: @escaping (ESMessage) -> Void) -> SubscriptionToken
    func unsubscribe(_ token: SubscriptionToken)
    
    // File ID resolution
    func resolvePath(deviceID: dev_t, inodeID: UInt64, completion: @escaping (String?) -> Void)
    func resolveFileRefURL(_ url: URL, completion: @escaping (FSNode?) -> Void)
    
    // Snapshot management
    func listSnapshots(volumeUUID: UUID, completion: @escaping ([SnapshotInfo]) -> Void)
    func mountSnapshot(volumeUUID: UUID, snapshotUUID: UUID, mountPoint: String, 
                       completion: @escaping (Error?) -> Void)
    func unmountSnapshot(mountPoint: String, completion: @escaping (Error?) -> Void)
    
    // Debug
    func getDebugInfo(completion: @escaping (DebugInfo) -> Void)
}
```

#### Helper Internal Architecture
```
EverythingHelper.xpc
├── VolumeManager
│   ├── enumerateVolumes() → [VolumeInfo]
│   ├── getVolumeIdentity(dev_t) → VolumeIdentity
│   └── VolumeIdentityCache (deviceID → VolumeIdentity)
│
├── APFSScanner
│   ├── RawBlockDevice (FileHandle for /dev/diskXsY)
│   ├── NXSuperblockParser
│   ├── ContainerSuperblockParser
│   ├── VolumeSuperblockParser
│   ├── ObjectMapResolver (virtual OID → physical block)
│   ├── FSTreeIterator (B-Tree traversal)
│   ├── RecordParsers:
│   │   ├── InodeRecordParser (j_inode_val_t + xfields)
│   │   ├── DirRecordParser (j_drec_hashed_key_t + j_drec_val_t)
│   │   ├── ExtentRecordParser
│   │   ├── XattrRecordParser
│   │   ├── SiblingLinkParser
│   │   └── ClonegroupParser
│   └── ScanProgressReporter
│
├── EndpointSecurityMonitor
│   ├── ESClient wrapper
│   ├── EventFilter (volumeUUID allowlist)
│   ├── EventTranslator (ESMessage → IndexDelta)
│   └── SubscriptionManager
│
├── FSEventsMonitor (fallback)
│   ├── FSEventStream per volume
│   ├── EventCoalescer (batch directory changes)
│   └── RescanScheduler (getattrlistbulk)
│
├── SnapshotManager
│   ├── fs_snapshot_list()
│   ├── fs_snapshot_mount()/unmount()
│   └── MountPointTracker
│
└── FileIDResolver
    ├── resolvePath(deviceID, inodeID) → path
    └── resolveFileRefURL(url) → FSNode
```

---

### 2.2 UI Process (Everything.app)

#### Architecture
```
Everything.app
├── AppDelegate / SceneDelegate
│   ├── MenuBarController (NSStatusItem)
│   ├── HotkeyManager (MASShortcut / CGEventTap)
│   └── WindowController (NSWindow)
│
├── SearchEngine
│   ├── QueryParser (String → AST)
│   ├── BytecodeCompiler (AST → [SearchOpcode])
│   ├── BytecodeVM (execute against indexes)
│   ├── IndexManager
│   │   ├── PrimaryIndex (nodesByName, nodesByPath, nodesByInode)
│   │   ├── FastSortIndexes (size, modTime, createTime, extension)
│   │   ├── VolumeIndexes (per-volume isolated indexes)
│   │   └── IndexSnapshot (copy-on-write for concurrent search)
│   ├── ResultRanker (runCount, recency, path depth)
│   └── SearchSession (history, filters, sort state)
│
├── IndexPersistence
│   ├── DatabaseWriter (background, incremental)
│   ├── DatabaseReader (mmap on launch)
│   ├── SchemaMigrator (version handling)
│   └── CompressionEngine (LZ4/ZSTD)
│
├── UI Components
│   ├── SearchField (NSSearchField + custom suggestions)
│   ├── ResultsTableView (NSTableView, virtualized)
│   ├── PreviewPane (QLPreviewPanel / QuickLook)
│   ├── ThumbnailGenerator (CGImageSource, async)
│   ├── SidebarControllers (Folders, Filters, Bookmarks)
│   └── ContextMenuBuilder (NSMenu + custom actions)
│
├── IPC Client
│   ├── XPCConnectionManager (reconnect, health check)
│   ├── RequestRouter (async/await wrappers)
│   └── EventHandler (IndexDelta → IndexManager.apply())
│
├── SettingsManager
│   ├── UserDefaults + custom JSON (Everything.plist)
│   ├── SettingsUI (SwiftUI / AppKit)
│   └── Migration (version upgrades)
│
├── PluginManager (future)
│   ├── PluginLoader (DLL bundles)
│   ├── PluginSandbox (XPC subprocess)
│   └── PluginAPI (index access, UI hooks)
│
└── CLI Tool (everything)
    ├── ArgumentParser (swift-argument-parser)
    ├── JSONOutputFormatter
    └── SearchEngine reuse
```

---

### 2.3 In-Memory Index Data Structures

#### Primary Indexes
```swift
final class IndexManager {
    // Primary: O(log n) prefix search
    private var nodesByName: SortedArray<FSNode>      // sorted by name
    private var nodesByPath: SortedArray<FSNode>      // sorted by full path
    private var nodesByInode: [CompositeKey: FSNode]  // (deviceID, inodeID) → node
    
    // Hierarchy: O(1) parent → children
    private var nodesByParent: [CompositeKey: [FSNode]]
    
    // Fast-sort auxiliary (optional, enabled per setting)
    private var nodesBySize: SortedArray<FSNode>?
    private var nodesByModTime: SortedArray<FSNode>?
    private var nodesByCreateTime: SortedArray<FSNode>?
    private var nodesByExtension: SortedArray<FSNode>?
    
    // Per-volume isolation
    private var volumeIndexes: [UUID: VolumeIndex]
    
    // Concurrency: copy-on-write snapshots
    private var currentSnapshot: IndexSnapshot
    private let snapshotQueue = DispatchQueue(label: "index.snapshots", 
                                               attributes: .concurrent)
}

struct CompositeKey: Hashable {
    let deviceID: UInt32
    let inodeID: UInt64
}
```

#### Bytecode VM
```swift
enum SearchOpcode {
    // Indexed filters (binary search on sorted arrays)
    case namePrefix(String)
    case pathPrefix(String)
    case extensionMatch(String)
    case sizeRange(ClosedRange<UInt64>)
    case modTimeRange(ClosedRange<UInt64>)
    case createTimeRange(ClosedRange<UInt64>)
    case cloneGroup(UInt64)
    case hardLinkCount(Int)
    case volumeFilter(UUID)
    case bsdFlags(UInt32)        // uchg, uappnd, compressed, dataless
    
    // Non-indexed (linear scan of candidates)
    case regex(NSRegularExpression)
    case content(String)         // delegate to Spotlight
    case attribute(String)       // xattr
    
    // Boolean logic
    case and
    case or
    case not
    
    // Control flow
    case groupStart
    case groupEnd
    case limit(Int)
    case offset(Int)
    
    // Output
    case sortBy(Property, ascending: Bool)
    case distinct(Property)
}

final class BytecodeVM {
    func execute(_ bytecode: [SearchOpcode], 
                 against snapshot: IndexSnapshot,
                 context: SearchContext) -> SearchResults {
        var candidates: CandidateSet = .all(snapshot)
        var stack: [CandidateSet] = []
        
        for op in bytecode {
            switch op {
            case .namePrefix(let prefix):
                candidates = intersect(candidates, 
                    snapshot.nodesByName.prefixRange(prefix))
            case .sizeRange(let range):
                if let idx = snapshot.nodesBySize {
                    candidates = intersect(candidates, idx.range(range))
                } else {
                    candidates = candidates.filter { range.contains($0.fileSize) }
                }
            case .and:
                let rhs = stack.popLast()!
                let lhs = stack.popLast()!
                stack.append(intersect(lhs, rhs))
            // ... other opcodes
            }
        }
        
        return SearchResults(candidates: stack.popLast() ?? candidates)
    }
}
```

---

### 2.4 Database Persistence

#### File Format: Everything.db
```
┌─────────────────────────────────────────────────────────────────┐
│ Header (64 bytes)                                               │
├─────────────────────────────────────────────────────────────────┤
│ Volume Table (variable)                                         │
├─────────────────────────────────────────────────────────────────┤
│ Exclude List (variable)                                         │
├─────────────────────────────────────────────────────────────────┤
│ Node Table (variable, delta-encoded)                            │
├─────────────────────────────────────────────────────────────────┤
│ Property Indexes (optional, variable)                           │
├─────────────────────────────────────────────────────────────────┤
│ String Table (prefix-compressed)                                │
├─────────────────────────────────────────────────────────────────┤
│ Footer (checksum, metadata)                                     │
└─────────────────────────────────────────────────────────────────┘
```

#### Node Entry (binary, ~80 bytes avg)
```
struct NodeEntry {
    // Fixed (64 bytes)
    var inodeID: UInt64
    var parentID: UInt64
    var privateID: UInt64
    var createTime: UInt64      // seconds
    var createTimeNsec: UInt32
    var modTime: UInt64
    var modTimeNsec: UInt32
    var changeTime: UInt64
    var changeTimeNsec: UInt32
    var accessTime: UInt64
    var accessTimeNsec: UInt32
    var fileSize: UInt64
    var uncompressedSize: UInt64
    var mode: UInt16
    var flags: UInt64
    var bsdFlags: UInt32
    var owner: UInt32
    var group: UInt32
    var writeGen: UInt32
    var cloneGroupID: UInt64
    var hardLinkCount: Int32
    var volumeID: UInt32
    var nameOffset: UInt32      // into string table
    var nameLength: UInt16
    var pathOffset: UInt32      // into string table (or 0 = compute from parent)
    var pathLength: UInt16
    
    // Variable: extended attributes, xattrs (TLV format)
}
```

#### Save Strategy
```swift
final class DatabaseWriter {
    private let dbURL: URL
    private let writeQueue = DispatchQueue(label: "db.writer", qos: .utility)
    private var dirtyRegions: Set<UInt64> = []  // page-aligned offsets
    private var saveTimer: Timer?
    
    func markDirty(_ node: FSNode) { /* ... */ }
    func markVolumeDirty(_ volume: UUID) { /* ... */ }
    
    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in
            self.flush()
        }
    }
    
    func flush() {
        writeQueue.async {
            // 1. Write to .tmp file
            // 2. fsync()
            // 3. rename() atomic swap
            // 4. Update mmap in IndexManager
        }
    }
}
```

---

## 3. Data Flow

### 3.1 Initial Scan Flow
```
User launches Everything.app
        │
        ▼
UI Process: XPC connect to Helper
        │
        ▼
Helper: enumerateVolumes() → [VolumeInfo]
        │
        ▼
UI: Display volume selection / auto-select all APFS
        │
        ▼
For each selected volume:
    Helper: startFullScan(volumeUUID)
            │
            ▼
    APFSScanner:
    1. Open /dev/diskXsY (O_RDONLY | O_NOFOLLOW)
    2. Read NX Superblock (block 0)
    3. Find Container Superblock
    4. Find Volume Superblock → apfs_fstree_oid
    5. ObjectMap.resolve(fstree_oid) → root physical block
    6. B-Tree iteration:
       - Stack-based descent to leaf nodes
       - For each leaf record:
         * Parse j_key_t → (inodeID, recordType)
         * Parse value per recordType
         * Build FSNode incrementally
         * Emit ScanProgress every 10k records
    7. Post-process: resolve paths, compute depths
    8. Return ScanResult { nodes: [FSNode], stats }
        │
        ▼
UI: IndexManager.buildIndex(scanResult)
        │
        ▼
UI: DatabaseWriter.saveIndex()
        │
        ▼
Ready for search
```

### 3.2 Real-Time Update Flow
```
Filesystem change (create/rename/delete/write)
        │
        ▼
EndpointSecurity kernel callback
        │
        ▼
Helper: ESClient receives ESMessage
        │
        ▼
EventTranslator: ESMessage → IndexDelta
    - create → Delta.insert(FSNode)
    - delete → Delta.remove(inodeID)
    - rename → Delta.move(inodeID, newParent, newName)
    - write → Delta.updateSize(inodeID, newSize)
    - setattr → Delta.updateAttrs(inodeID, flags, times)
    - clone → Delta.updateCloneGroup(inodeID, groupID)
        │
        ▼
Helper: XPC send IndexDelta to UI
        │
        ▼
UI: IndexManager.apply(delta) on snapshot
        │
        ▼
UI: DatabaseWriter.markDirty(affectedNodes)
        │
        ▼
UI: SearchResults.update() if affected
```

### 3.3 Search Query Flow
```
User types in search field
        │
        ▼
SearchEngine.parse(queryString) → AST
        │
        ▼
SearchEngine.compile(ast) → [SearchOpcode]
        │
        ▼
SearchEngine.execute(bytecode, snapshot) → SearchResults
        │
        ▼
ResultRanker.rank(results, context) → ranked results
        │
        ▼
UI: ResultsTableView.reloadData() (virtualized)
        │
        ▼
User selects result → open/reveal/copy actions
```

---

## 4. Implementation Phases

### Phase 1: Core Infrastructure (Weeks 1-4)

| Task | Deliverable | Dependencies |
|------|-------------|--------------|
| 1.1 Xcode project setup, Swift Package Manager | Buildable app + helper targets | - |
| 1.2 SMJobBless helper installation | Installed, code-signed helper | Apple Developer ID |
| 1.3 XPC protocol definition + connection | Working IPC channel | 1.2 |
| 1.4 Volume enumeration (diskutil + IOKit) | List APFS volumes with UUIDs | 1.3 |
| 1.5 Raw block device access (FileHandle) | Read /dev/diskXsY | 1.4, entitlements |
| 1.6 NX/Container/Volume superblock parsing | Verified parsing on test volumes | 1.5 |
| 1.7 Object Map resolver (OMAP) | Virtual OID → physical block | 1.6 |
| 1.8 FS-Tree B-Tree iterator | Leaf record enumeration | 1.7 |
| 1.9 Inode/Dir record parsers | FSNode emission | 1.8 |
| 1.10 In-memory index (SortedArray, CompositeKey) | Index build from scan | 1.9 |
| 1.11 Basic search (name prefix, exact match) | Working search | 1.10 |
| 1.12 Minimal UI (search field, results list) | End-to-end demo | 1.11 |

**Phase 1 Exit Criteria**: Can index a test APFS volume (~100k files) and search by name in <10ms.

---

### Phase 2: Real-Time Monitoring (Weeks 5-8)

| Task | Deliverable | Dependencies |
|------|-------------|--------------|
| 2.1 EndpointSecurity entitlements + client | ES subscription working | Phase 1, entitlements |
| 2.2 EventTranslator (ESMessage → IndexDelta) | All event types handled | 2.1 |
| 2.3 IndexManager.apply(Delta) | Atomic snapshot updates | 2.2 |
| 2.4 FSEvents fallback monitor | Network/non-APFS volumes | 2.3 |
| 2.5 getattrlistbulk directory scanner | Folder indexing | 2.4 |
| 2.6 Database persistence (LZ4) | Save/load index | 2.3 |
| 2.7 Launch at login / menu bar icon | Polished UX | 2.6 |
| 2.8 Hotkey (⌘⇧Space) global | System-wide access | 2.7 |

**Phase 2 Exit Criteria**: Index stays in sync with filesystem changes (<100ms latency), survives restart.

---

### Phase 3: Search Features (Weeks 9-12)

| Task | Deliverable | Dependencies |
|------|-------------|--------------|
| 3.1 Query parser (full syntax) | AST for all operators | Phase 2 |
| 3.2 Bytecode compiler | Optimized opcode emission | 3.1 |
| 3.3 Bytecode VM | Execute all opcodes | 3.2 |
| 3.4 Fast-sort indexes (size, dates) | O(log n) property filters | 3.3 |
| 3.5 Property indexes (extension, clonegroup, bsdflags) | Optional indexes | 3.4 |
| 3.6 Result ranking (run count, recency) | Relevant results first | 3.5 |
| 3.7 Search syntax: regex, wildcards, modifiers | Full syntax support | 3.3 |
| 3.8 Content search bridge (Spotlight/mdfind) | content: function | 3.7 |
| 3.9 Filters sidebar (kind, date, size) | UI filters | 3.6 |
| 3.10 Bookmarks & search history | Persisted searches | 3.6 |

**Phase 3 Exit Criteria**: Full search syntax parity with Windows Everything, sub-20ms latency.

---

### Phase 4: APFS-Native Features (Weeks 13-16)

| Task | Deliverable | Dependencies |
|------|-------------|--------------|
| 4.1 Clonegroup tree parser | Clone detection | Phase 3 |
| 4.2 Snapshot list/mount/unmount | Time Machine browsing | 3.3, Helper |
| 4.3 File Reference URL resolution | file:///.file/id= support | 3.3, Helper |
| 4.4 volfs path resolution | /.vol/ support | 4.3 |
| 4.5 DECMPFS detection + size reporting | compressed: filter | 3.3 |
| 4.6 BSD flags indexing (uchg, dataless, etc.) | bsdflags: filter | 3.5 |
| 4.7 Hard link enumeration (sibling links) | hardlinks: filter | 4.1 |
| 4.8 Extended attributes (xattr) indexing | attr: filter | 4.6 |

**Phase 4 Exit Criteria**: All APFS-specific search functions working, snapshot browsing functional.

---

### Phase 5: Polish & Distribution (Weeks 17-20)

| Task | Deliverable | Dependencies |
|------|-------------|--------------|
| 5.1 Thumbnails (QuickLook) | Image/video preview | Phase 4 |
| 5.2 Preview pane (QLPreviewPanel) | Document preview | 5.1 |
| 5.3 Advanced UI (columns, sorting, grouping) | Power user features | 3.9 |
| 5.4 CLI tool (`everything` command) | Automation | 3.3 |
| 5.5 ETP/HTTP server plugins | Network sharing | 4.0, PluginManager |
| 5.6 Notarization + App Store build | Distribution | All |
| 5.7 Localization (10+ languages) | International | 5.3 |
| 5.8 Documentation + website | User-facing docs | 5.6 |
| 5.9 Performance profiling + optimization | <5ms search, <200MB RAM | All |
| 5.10 Beta program + crash reporting | Production readiness | 5.6 |

**Phase 5 Exit Criteria**: Production-ready, notarized, <5ms search on 1M files, <300MB RAM.

---

## 5. Technical Decisions

### 5.1 Language Choices

| Component | Language | Rationale |
|-----------|----------|-----------|
| UI Process | Swift 5.9+ | Native AppKit/SwiftUI, memory safety |
| Helper (XPC) | Swift + C | C for APFS structs, Swift for logic |
| APFS Parsers | C | Direct struct mapping, zero-copy |
| Bytecode VM | Swift | Performance + safety |
| Database | Swift + C | mmap, compression (LZ4 C) |

### 5.2 Concurrency Model

```
UI Process (MainActor):
├── Main thread: UI, user input, search execution
├── Search queue: BytecodeVM (serial, per-search)
├── Index queue: IndexManager.apply() (serial)
└── Persistence queue: DatabaseWriter (background)

Helper Process:
├── XPC listener queue: Request handling (concurrent)
├── Scan queue: APFSScanner (serial per volume)
├── ES queue: EventTranslator (serial, ordered)
├── FSEvents queue: EventCoalescer (serial per volume)
└── Snapshot queue: Mount operations (serial)
```

**Synchronization**: 
- IndexManager uses copy-on-write snapshots (lock-free reads)
- Writer uses single background queue (serialized writes)
- XPC calls are async with continuation-based await

### 5.3 Memory Management

```swift
// Target: <300MB for 1M files
// Strategies:
1. String interning (names, paths) → ~40% reduction
2. Delta-encoding in memory (parentID, timestamps) → ~30% reduction  
3. Optional fast-sort indexes (disabled by default) → ~100MB savings
4. 32-bit offsets where possible (string table, parent index)
5. Lazy loading: extent data, xattrs only on demand
```

### 5.4 Error Handling & Resilience

```swift
enum ScanError: Error {
    case volumeUnavailable(UUID)
    case permissionDenied(dev_t)
    case omapCorruption(block: UInt64)
    case btreeInconsistency(node: UInt64)
    case resourceExhausted(limit: String)
}

enum MonitorError: Error {
    case esEntitlementMissing
    case esClientCreationFailed(Error)
    case fsEventsStreamFailed(Error)
    case eventQueueOverflow
}

// Strategy: 
// - Scan errors → mark volume degraded, continue others
// - Monitor errors → fallback to FSEvents → fallback to polling
// - Database corruption → rebuild from scratch (Force Reindex)
```

---

## 6. Security Model

### 6.1 Privilege Separation

```
┌────────────────────────────────────────────────────────────┐
│                      Security Boundaries                    │
├────────────────────────────────────────────────────────────┤
│                                                             │
│  Everything.app (Sandboxed, User)                          │
│  ├── com.apple.security.app-sandbox                        │
│  ├── com.apple.security.files.user-selected.read-only      │
│  ├── com.apple.security.network.client (optional ETP)      │
│  └── XPC Client → Helper (restricted interface)            │
│                                                             │
│  ────────────────────────────────────────────────────────  │
│                                                             │
│  EverythingHelper.xpc (Root, No Sandbox)                   │
│  ├── com.apple.developer.endpoint-security.client          │
│  ├── com.apple.security.cs.disable-library-validation      │
│  ├── com.apple.security.cs.allow-dyld-environment-variables│
│  └── Raw /dev/disk* access (via IOKit)                     │
│                                                             │
└────────────────────────────────────────────────────────────┘
```

### 6.2 Data Protection

- **Database**: Encrypted via FileVault (user's keychain), no separate encryption
- **Network**: None by default; ETP/HTTP servers opt-in with auth
- **Logs**: No PII, debug logs opt-in only
- **Telemetry**: None

---

## 7. Testing Strategy

### 7.1 Unit Tests (Target: 80% coverage)

| Module | Test Focus |
|--------|------------|
| APFS Parsers | Golden master files (dd images), fuzzing |
| Query Parser | Property-based (SwiftCheck), syntax edge cases |
| Bytecode VM | Instruction-level, optimization correctness |
| IndexManager | Concurrent read/write, snapshot isolation |
| Database | Round-trip, corruption recovery, migration |

### 7.2 Integration Tests

| Scenario | Validation |
|----------|------------|
| Full scan 1M files | <8s, <300MB, correct counts |
| Real-time create/delete/rename | <100ms index update |
| Clone detection (cp -c) | clonegroup: finds all members |
| Snapshot mount/search | Read-only, correct timestamps |
| File Reference URL resolve | Stable across moves |
| Network volume (SMB) | Folder indexing + FSEvents |
| Encrypted volume (locked) | Metadata only, no content |
| Power loss during write | Database recovery on restart |

### 7.3 Performance Benchmarks

```swift
// Benchmarks run on CI (Mac mini M2, 1TB APFS SSD)
struct Benchmarks {
    static let targets = [
        "initial_scan_100k": 2.0,      // seconds
        "initial_scan_1M": 15.0,
        "search_name_prefix": 0.005,   // seconds (5ms)
        "search_size_range": 0.010,
        "search_regex": 0.050,
        "search_content": 2.0,         // Spotlight delegate
        "index_update_create": 0.0001, // 100µs
        "index_update_batch_1000": 0.010,
        "memory_100k": 30,             // MB
        "memory_1M": 250,
        "db_size_1M": 25,              // MB (LZ4)
        "launch_time_cold": 1.5,
        "launch_time_warm": 0.3,
    ]
}
```

### 7.4 Fuzzing & Stress

- **APFS Parser Fuzzing**: AFL++ on record parsers with corrupted images
- **Query Fuzzing**: Random syntax strings → parser must not crash
- **Concurrency Stress**: 100 concurrent searches + 1000 updates/sec
- **Long-run**: 7 days continuous monitoring, verify no leaks

---

## 8. Risk Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| APFS on-disk format changes | Low | High | Version detection, fallback to FSEvents, abstract parsers |
| EndpointSecurity entitlement denial | Medium | High | FSEvents fallback, user guidance for manual approval |
| SMJobBless installation failure | Medium | High | Clear error UI, manual install instructions |
| Raw device access blocked (SIP) | Low | High | Require SIP status check, documented workaround |
| Database corruption | Low | High | Checksums, atomic writes, auto-rebuild |
| Memory pressure (large volumes) | Medium | Medium | Configurable index limits, optional fast-sort |
| macOS version incompatibility | Medium | Medium | CI matrix (11-15+), conditional compilation |
| Third-party AV interference | Medium | Low | Exclude paths, signed/notarized binaries |

---

## 9. Dependencies

### 9.1 System Requirements
- macOS 11.0+ (Big Sur) for EndpointSecurity
- macOS 13.0+ (Ventura) recommended for full ES features
- APFS-formatted volumes (HFS+ via folder indexing only)
- Apple Silicon or Intel (Universal Binary)

### 9.2 External Dependencies (Swift Package Manager)

```swift
// Package.swift dependencies
dependencies: [
    // Compression
    .package(url: "https://github.com/molecular/lz4-swift", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-compression", from: "1.0.0"),
    
    // CLI
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    
    // Testing
    .package(url: "https://github.com/Quick/Quick", from: "7.0.0"),
    .package(url: "https://github.com/Quick/Nimble", from: "12.0.0"),
]
```

### 9.3 Internal Frameworks
- **CoreServices** (FSEvents, getattrlistbulk)
- **EndpointSecurity** (ESClient)
- **FileProvider** (cloud sync integration)
- **QuickLook** (previews, thumbnails)
- **UniformTypeIdentifiers** (UTI/kind matching)

---

## 10. Monitoring & Observability

### 10.1 Metrics (Internal, No Telemetry)

```swift
struct Metrics {
    // Performance
    var scanDuration: TimeInterval
    var scanFilesPerSecond: Double
    var searchLatencyP50: TimeInterval
    var searchLatencyP99: TimeInterval
    var indexUpdateLatency: TimeInterval
    
    // Health
    var memoryUsageMB: Int
    var databaseSizeMB: Int
    var volumesIndexed: Int
    var volumesDegraded: Int
    
    // Errors
    var esErrorsCount: Int
    var fsEventsErrorsCount: Int
    var scanErrorsCount: Int
    var databaseErrorsCount: Int
}
```

### 10.2 Debug Interface

```
Everything Debug Console (⌘⌥D)
├── Index Stats (counts, memory, volumes)
├── Live Event Stream (ES + FSEvents)
├── Search Query Log (bytecode, timing)
├── Database Stats (pages, compression ratio)
├── Volume Identity Map
├── Clonegroup Explorer
├── Snapshot Browser
└── Manual Commands:
    - Force Reindex
    - Dump Index (JSON)
    - Verify Database
    - Simulate Events
```

---

## 11. Future Extensibility

### 11.1 Plugin Architecture (v1.5+)
```
Plugins/ (bundles loaded via XPC subprocess)
├── ETPServerPlugin (network sharing)
├── HTTPServerPlugin (web interface)
├── EverythingServerPlugin (centralized index)
├── CustomIndexPlugin (Git, Docker, custom FS)
└── CustomSearchPlugin (ML ranking, semantic search)
```

### 11.2 API Surface (for Automation)
```swift
// Public Swift API (distributed via SPM)
public struct Everything {
    public static func search(_ query: String, 
                              options: SearchOptions = .default) async throws -> [SearchResult]
    public static func searchStream(_ query: String) -> AsyncThrowingStream<SearchResult, Error>
    public static func open(_ result: SearchResult)
    public static func reveal(_ result: SearchResult)
    public static func getMetadata(_ result: SearchResult) -> FileMetadata
}
```

### 11.3 Cross-Platform Core (Long-term)
```
EverythingCore (C/Rust)
├── APFS Scanner (this project)
├── NTFS Scanner (Windows Everything)
├── ext4/btrfs Scanner (Linux)
└── Common: Index, Bytecode VM, Query Parser
```

---

## 12. Appendix: File Layout

```
/Applications/Everything.app
├── Contents/
│   ├── MacOS/Everything                    # Main executable
│   ├── XPCServices/EverythingHelper.xpc   # Privileged helper
│   ├── Resources/
│   │   ├── Everything.plist               # Default config
│   │   ├── SearchSyntax.plist             # Syntax highlighting
│   │   └── Icons/
│   └── Frameworks/                        # Embedded Swift libs

/Library/PrivilegedHelperTools/
└── com.everything.helper                  # Installed by SMJobBless

/Library/LaunchDaemons/
└── com.everything.helper.plist            # LaunchDaemon config

~/Library/Application Support/Everything/
├── Everything.db                          # Main database
├── Everything.db-wal                      # WAL (if SQLite, not used here)
├── Plugins/                               # Future plugin dir
└── IndexSnapshots/                        # Backup snapshots

~/Library/Preferences/
└── com.everything.Everything.plist        # User settings

~/Library/Logs/Everything/
├── Everything.log                         # Main log
├── Helper.log                             # Helper log
├── Scan_YYYYMMDD_HHMMSS.log               # Scan logs
└── Debug_YYYYMMDD_HHMMSS.log              # Debug console
```

---

## 13. Conclusion

This system design translates the APFS technical specification into an implementable architecture with:

1. **Clear process separation** (sandboxed UI + privileged helper)
2. **Validated APFS internals** (FS-Tree, OMAP, EndpointSecurity)
3. **Proven search architecture** (bytecode VM, copy-on-write indexes)
4. **Phased delivery** (5 phases, 20 weeks to production)
5. **Risk-aware decisions** (fallbacks, error boundaries, no single points of failure)

The design is ready for implementation. Phase 1 can begin immediately with Xcode project setup and SMJobBless helper installation.