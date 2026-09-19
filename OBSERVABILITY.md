# Everything-macOS: Observability & Validation Strategy

## Goal
**Validate every step of Phase 1 implementation** with zero-guesswork debugging. No "it seems to work" — only "the test passes" or "the metric shows X".

---

## 1. Structured Logging (Foundation)

### 1.1 Log Format: JSON Lines with Correlation IDs
```swift
// LogEntry.swift
struct LogEntry: Codable {
    let timestamp: String        // ISO8601 with microseconds
    let level: Level             // debug, info, warn, error, fatal
    let subsystem: String        // "ui", "helper", "scanner", "index", "db"
    let category: String         // "scan", "xpc", "es", "fsevents", "search", "db"
    let message: String
    let correlationID: String?   // UUID linking related operations
    let metadata: [String: String]  // flexible key-values
    let file: String             // source file (auto)
    let function: String         // source function (auto)
    let line: Int                // source line (auto)
}

enum Level: String, Codable { case debug, info, warn, error, fatal }
```

### 1.2 Logger Implementation
```swift
// Logger.swift
final class Logger {
    static let shared = Logger()
    
    private let queue = DispatchQueue(label: "logger", qos: .utility)
    private let fileHandle: FileHandle
    private let consoleOutput: Bool
    
    private init() {
        let logDir = FileManager.default.urls(for: .logsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Everything")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("Everything_\(ISO8601DateFormatter().string(from: Date())).log")
        self.fileHandle = try! FileHandle(forWritingTo: logFile)
        self.consoleOutput = ProcessInfo.processInfo.environment["EVERYTHING_DEBUG_CONSOLE"] == "1"
    }
    
    func log(_ level: Level, subsystem: String, category: String, 
             message: String, correlationID: String? = nil, metadata: [String: String] = [:],
             file: String = #file, function: String = #function, line: Int = #line) {
        let entry = LogEntry(
            timestamp: ISO8601DateFormatter.withMicroseconds.string(from: Date()),
            level: level, subsystem: subsystem, category: category,
            message: message, correlationID: correlationID, metadata: metadata,
            file: (file as NSString).lastPathComponent, function: function, line: line
        )
        queue.async {
            let data = try! JSONEncoder().encode(entry)
            self.fileHandle.write(data + Data("\n".utf8))
            if self.consoleOutput || level >= .warn {
                FileHandle.standardError.write(data + Data("\n".utf8))
            }
        }
    }
    
    // Convenience
    func debug(_ msg: String, subsystem: String, category: String, corr: String? = nil, meta: [String: String] = [:]) {
        log(.debug, subsystem: subsystem, category: category, message: msg, correlationID: corr, metadata: meta)
    }
    func info(_ msg: String, subsystem: String, category: String, corr: String? = nil, meta: [String: String] = [:]) { ... }
    func warn(_ msg: String, subsystem: String, category: String, corr: String? = nil, meta: [String: String] = [:]) { ... }
    func error(_ msg: String, subsystem: String, category: String, corr: String? = nil, meta: [String: String] = [:]) { ... }
}

// Usage
Logger.shared.info("Starting full scan", subsystem: "helper", category: "scan", 
                   corr: scanID, meta: ["volume": volumeUUID.uuidString])
```

### 1.3 Log Rotation & Retention
```swift
// Daily rotation, keep 7 days, compress old
// Size limit: 100MB per file, max 10 files
```

---

## 2. Metrics (Prometheus Exposition Format)

### 2.1 Metrics Registry
```swift
// Metrics.swift
final class MetricsRegistry {
    static let shared = MetricsRegistry()
    
    // Counters
    let scanFilesTotal = Counter(name: "everything_scan_files_total", help: "Total files scanned")
    let scanBytesTotal = Counter(name: "everything_scan_bytes_total", help: "Total bytes scanned")
    let scanErrorsTotal = Counter(name: "everything_scan_errors_total", help: "Scan errors")
    let searchRequestsTotal = Counter(name: "everything_search_requests_total", help: "Search requests")
    let searchErrorsTotal = Counter(name: "everything_search_errors_total", help: "Search errors")
    let indexUpdatesTotal = Counter(name: "everything_index_updates_total", help: "Index updates applied")
    let esEventsTotal = Counter(name: "everything_es_events_total", help: "EndpointSecurity events")
    let fsEventsTotal = Counter(name: "everything_fsevents_total", help: "FSEvents received")
    let xpcCallsTotal = Counter(name: "everything_xpc_calls_total", help: "XPC calls")
    let xpcErrorsTotal = Counter(name: "everything_xpc_errors_total", help: "XPC errors")
    let dbWritesTotal = Counter(name: "everything_db_writes_total", help: "Database writes")
    let dbReadsTotal = Counter(name: "everything_db_reads_total", help: "Database reads")
    
    // Gauges
    let memoryUsageBytes = Gauge(name: "everything_memory_usage_bytes", help: "Process memory")
    let indexNodeCount = Gauge(name: "everything_index_node_count", help: "Nodes in index")
    let indexMemoryBytes = Gauge(name: "everything_index_memory_bytes", help: "Index memory")
    let dbSizeBytes = Gauge(name: "everything_db_size_bytes", help: "Database file size")
    let volumesIndexed = Gauge(name: "everything_volumes_indexed", help: "Volumes indexed")
    let volumesDegraded = Gauge(name: "everything_volumes_degraded", help: "Degraded volumes")
    let activeSearches = Gauge(name: "everything_active_searches", help: "Concurrent searches")
    
    // Histograms (latency in seconds)
    let scanDuration = Histogram(name: "everything_scan_duration_seconds", 
                                 buckets: [0.1, 0.5, 1, 2, 5, 10, 30, 60, 120])
    let searchLatency = Histogram(name: "everything_search_latency_seconds",
                                  buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1])
    let indexUpdateLatency = Histogram(name: "everything_index_update_latency_seconds",
                                       buckets: [0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1])
    let xpcCallLatency = Histogram(name: "everything_xpc_call_latency_seconds",
                                   buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.5])
    let dbWriteLatency = Histogram(name: "everything_db_write_latency_seconds",
                                   buckets: [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1])
    
    // HTTP endpoint for scraping
    func startHTTPServer(port: Int = 9090) { ... }
    func expositionFormat() -> String { ... }  // Prometheus text format
}
```

### 2.2 Key Metrics to Alert On
| Metric | Warning | Critical |
|--------|---------|----------|
| `search_latency_seconds` p99 | > 0.1s | > 0.5s |
| `scan_files_per_second` | < 10,000 | < 1,000 |
| `index_update_latency_seconds` p99 | > 0.01s | > 0.1s |
| `memory_usage_bytes` | > 500MB | > 1GB |
| `volumes_degraded` | > 0 | > 0 |
| `xpc_errors_total` rate | > 1/min | > 10/min |

---

## 3. Distributed Tracing

### 3.1 Trace Context Propagation
```swift
// Tracing.swift
struct TraceContext {
    let traceID: String        // UUID
    let spanID: String         // UUID
    let parentSpanID: String?  // for child spans
    let baggage: [String: String]  // cross-process context
    
    static func new() -> TraceContext {
        TraceContext(traceID: UUID().uuidString, spanID: UUID().uuidString, parentSpanID: nil, baggage: [:])
    }
    func child() -> TraceContext {
        TraceContext(traceID: traceID, spanID: UUID().uuidString, parentSpanID: spanID, baggage: baggage)
    }
}

// XPC carries trace context automatically
extension NSXPCConnection {
    func sendWithTrace<T>(_ call: @escaping (TraceContext) async throws -> T) async throws -> T {
        let ctx = TraceContext.new()
        return try await call(ctx)
    }
}
```

### 3.2 Span Recording
```swift
final class Tracer {
    static let shared = Tracer()
    private var spans: [Span] = []
    private let lock = NSLock()
    
    @discardableResult
    func span<T>(name: String, subsystem: String, category: String,
                 ctx: TraceContext? = nil, 
                 _ body: (TraceContext) async throws -> T) async rethrows -> T {
        let spanCtx = ctx?.child() ?? TraceContext.new()
        let start = CFAbsoluteTimeGetCurrent()
        let span = Span(traceID: spanCtx.traceID, spanID: spanCtx.spanID,
                        parentSpanID: spanCtx.parentSpanID, name: name,
                        subsystem: subsystem, category: category, startTime: start)
        
        defer {
            span.endTime = CFAbsoluteTimeGetCurrent()
            lock.lock(); spans.append(span); lock.unlock()
            if spans.count > 10000 { spans.removeFirst(1000) }
        }
        
        return try await body(spanCtx)
    }
    
    func export() -> [Span] { lock.lock(); defer { lock.unlock() }; return spans }
}

struct Span {
    let traceID: String, spanID: String, parentSpanID: String?
    let name: String, subsystem: String, category: String
    var startTime: CFAbsoluteTime, endTime: CFAbsoluteTime?
    var attributes: [String: String] = [:]
    var status: Status = .ok
    enum Status { case ok, error(String) }
}
```

---

## 4. Debug Console (Built-in UI)

### 4.1 Debug Window (⌘⌥D)
```swift
// DebugConsoleWindowController.swift
class DebugConsoleWindowController: NSWindowController {
    // Tabs:
    // 1. Live Log Stream (filter by level, subsystem, category, correlationID)
    // 2. Metrics Dashboard (real-time gauges, histograms)
    // 3. Trace Explorer (span timeline, flame graph)
    // 4. Index Inspector (volume stats, node counts, memory)
    // 5. Volume Identity Map (deviceID → VolumeIdentity)
    // 6. Clonegroup Explorer
    // 7. Snapshot Browser
    // 8. Manual Commands:
    //    - Force Reindex Volume
    //    - Dump Index (JSON to file)
    //    - Verify Database Integrity
    //    - Simulate ES Event
    //    - Toggle Fast-Sort Indexes
    //    - GC / Memory Pressure
}
```

### 4.2 Debug Commands (Search Bar Commands)
```swift
// Type in search box:
/debug           // Open debug console
/config_dump     // Dump all settings JSON
/index_stats     // Print index statistics
/volume_map      // Print volume identity map
/trace_dump      // Export traces to file
/metrics_dump    // Export metrics snapshot
/gc              // Force garbage collection
/sim_create /path/to/file   // Simulate file create event
/sim_rename /old /new       // Simulate rename
/sim_delete /path           // Simulate delete
```

---

## 5. Validation Gates (Automated)

### 5.1 Phase 1 Validation Checklist (Executable)
```swift
// ValidationGates.swift
struct Phase1Validation {
    static func runAll() async throws -> ValidationReport {
        var report = ValidationReport(phase: 1)
        
        // Gate 1: Helper Installation
        report.add(try await validateHelperInstallation())
        
        // Gate 2: XPC Connection
        report.add(try await validateXPCConnection())
        
        // Gate 3: Volume Enumeration
        report.add(try await validateVolumeEnumeration())
        
        // Gate 4: Raw Device Access
        report.add(try await validateRawDeviceAccess())
        
        // Gate 5: Superblock Parsing
        report.add(try await validateSuperblockParsing())
        
        // Gate 6: OMAP Resolution
        report.add(try await validateOMAPResolution())
        
        // Gate 7: FS-Tree Iteration
        report.add(try await validateFSTreeIteration())
        
        // Gate 8: Record Parsing
        report.add(try await validateRecordParsing())
        
        // Gate 9: Index Build
        report.add(try await validateIndexBuild())
        
        // Gate 10: Name Search
        report.add(try await validateNameSearch())
        
        // Gate 11: Persistence
        report.add(try await validatePersistence())
        
        // Gate 12: Memory Budget
        report.add(try await validateMemoryBudget())
        
        return report
    }
}

struct ValidationReport {
    let phase: Int
    var gates: [GateResult] = []
    var passed: Bool { gates.allSatisfy { $0.passed } }
    var summary: String { ... }
}

struct GateResult {
    let name: String
    let passed: Bool
    let duration: TimeInterval
    let details: String
    let metrics: [String: Double]
}
```

### 5.2 Gate Implementations (Examples)

```swift
// Gate 1: Helper Installation
func validateHelperInstallation() async throws -> GateResult {
    let start = CFAbsoluteTimeGetCurrent()
    let helperPath = "/Library/PrivilegedHelperTools/com.everything.helper"
    let exists = FileManager.default.fileExists(atPath: helperPath)
    let isSigned = try await codesignVerify(helperPath)
    let launchdPlist = "/Library/LaunchDaemons/com.everything.helper.plist"
    let plistExists = FileManager.default.fileExists(atPath: launchdPlist)
    let serviceRunning = try await launchctlList("com.everything.helper")
    
    let passed = exists && isSigned && plistExists && serviceRunning
    return GateResult(name: "Helper Installation", passed: passed, 
                      duration: CFAbsoluteTimeGetCurrent() - start,
                      details: "exists=\(exists) signed=\(isSigned) plist=\(plistExists) running=\(serviceRunning)",
                      metrics: [:])
}

// Gate 4: Raw Device Access
func validateRawDeviceAccess() async throws -> GateResult {
    let start = CFAbsoluteTimeGetCurrent()
    let volumes = try await HelperClient.shared.enumerateVolumes()
    var results: [String: Bool] = [:]
    for vol in volumes where vol.fileSystem == "apfs" {
        let devicePath = "/dev/\(vol.bsdName)"
        let fd = open(devicePath, O_RDONLY | O_NOFOLLOW)
        results[vol.bsdName] = fd >= 0
        if fd >= 0 { close(fd) }
    }
    let passed = !results.values.contains(false)
    return GateResult(name: "Raw Device Access", passed: passed,
                      duration: CFAbsoluteTimeGetCurrent() - start,
                      details: results.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
                      metrics: ["volumes_tested": Double(results.count)])
}

// Gate 7: FS-Tree Iteration
func validateFSTreeIteration() async throws -> GateResult {
    let start = CFAbsoluteTimeGetCurrent()
    let testVolume = try await pickTestVolume()
    let result = try await HelperClient.shared.startFullScan(testVolume) { progress in
        // Progress callback validation
        assert(progress.filesScanned >= 0)
        assert(progress.bytesScanned >= 0)
    }
    
    let passed = result.nodes.count > 0 && result.errors.isEmpty
    return GateResult(name: "FS-Tree Iteration", passed: passed,
                      duration: CFAbsoluteTimeGetCurrent() - start,
                      details: "nodes=\(result.nodes.count) errors=\(result.errors.count) duration=\(result.duration)s",
                      metrics: ["nodes": Double(result.nodes.count), "duration": result.duration,
                                "files_per_sec": Double(result.nodes.count) / result.duration])
}

// Gate 10: Name Search
func validateNameSearch() async throws -> GateResult {
    let start = CFAbsoluteTimeGetCurrent()
    let engine = SearchEngine.shared
    
    // Test cases
    let tests = [
        ("exact", "Everything.app", 1),
        ("prefix", "Every", 10),
        ("wildcard", "*.app", 50),
        ("case_insensitive", "everything", 1),
        ("substring", "thing", 20),
    ]
    
    var allPassed = true
    var details: [String] = []
    for (name, query, expectedMin) in tests {
        let results = try await engine.search(query)
        let passed = results.count >= expectedMin
        allPassed = allPassed && passed
        details.append("\(name): \(results.count) results (\(passed ? "✓" : "✗"))")
    }
    
    return GateResult(name: "Name Search", passed: allPassed,
                      duration: CFAbsoluteTimeGetCurrent() - start,
                      details: details.joined(separator: "; "),
                      metrics: [:])
}
```

---

## 6. Test Infrastructure

### 6.1 Golden Master Test Volumes
```bash
# Create test disk images with known content
hdiutil create -size 1g -fs APFS -volname "TestVolume" test.dmg
hdiutil attach test.dmg

# Populate with known structure:
# /File_A.txt
# /Dir_B/File_C.txt
# /Dir_B/Dir_D/File_E.txt
# /Dir_B/Dir_D/File_F.txt (hard link to File_E)
# /clone_source.txt + clone via cp -c
# /.file/id= volume reference
# xattrs, BSD flags, etc.

# Generate golden master JSON:
swift run GenerateGoldenMaster /Volumes/TestVolume > golden_master.json
```

### 6.2 Unit Test Structure
```swift
// Tests/APFSParsersTests.swift
final class APFSParsersTests: XCTestCase {
    func testInodeRecordParsing() throws {
        let data = try Data(contentsOf: goldenMasterURL.appendingPathComponent("inode_record.bin"))
        let record = try InodeRecordParser.parse(data)
        XCTAssertEqual(record.inodeID, 0x1234)
        XCTAssertEqual(record.parentID, 0x2)
        XCTAssertEqual(record.createTime, 1704067200)
        // ... all fields
    }
    
    func testDirRecordHashing() throws {
        // Test CRC-32C of NFD+casefolded UTF-32
        let name = "README.md"
        let hash = DirRecordParser.computeHash(name)
        XCTAssertEqual(hash, 0xABCDEF12)  // Known value
    }
}

// Tests/BytecodeVMTests.swift
final class BytecodeVMTests: XCTestCase {
    func testNamePrefixFilter() throws {
        let index = TestIndexBuilder()
            .add("Apple.txt")
            .add("Application.swift")
            .add("Banana.md")
            .build()
        let vm = BytecodeVM()
        let results = vm.execute([.namePrefix("App")], against: index.snapshot)
        XCTAssertEqual(results.count, 2)
    }
}

// Tests/IndexManagerTests.swift
final class IndexManagerTests: XCTestCase {
    func testConcurrentReadWrite() throws {
        let index = IndexManager()
        let expectation = XCTestExpectation(description: "concurrent")
        expectation.expectedFulfillmentCount = 1000
        
        // 10 writers, 100 readers
        DispatchQueue.concurrentPerform(iterations: 10) { i in
            index.apply(.insert(FSNode(...)))
            expectation.fulfill()
        }
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            _ = index.snapshot.nodesByName.prefixRange("test")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        // No crashes, no data races (Thread Sanitizer)
    }
}
```

### 6.3 Integration Tests (Black Box)
```swift
// Tests/IntegrationTests.swift
final class IntegrationTests: XCTestCase {
    func testFullScanAndSearch() async throws {
        // 1. Launch helper
        // 2. Scan test volume
        // 3. Verify index counts match golden master
        // 4. Search for known files
        // 5. Verify results match expected paths
    }
    
    func testRealTimeUpdates() async throws {
        // 1. Scan volume
        // 2. Create file via FileManager
        // 3. Wait for ES event
        // 4. Verify index updated
        // 5. Search finds new file
    }
    
    func testRestartPersistence() async throws {
        // 1. Scan, search, verify
        // 2. Kill app (SIGTERM)
        // 3. Relaunch
        // 4. Verify index loaded from DB
        // 5. Search works without rescan
    }
}
```

---

## 7. CI/CD Pipeline

### 7.1 GitHub Actions Workflow
```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-14  # Apple Silicon runner
    steps:
      - uses: actions/checkout@v4
      - name: Install dependencies
        run: |
          brew install swiftlint lz4
      - name: Lint
        run: swiftlint lint --strict
      - name: Unit Tests
        run: swift test --parallel --filter "UnitTests"
      - name: Integration Tests
        run: |
          # Create test volume
          hdiutil create -size 2g -fs APFS -volname TestIntegration test.dmg
          hdiutil attach test.dmg -mountpoint /Volumes/TestIntegration
          # Populate
          swift run PopulateTestVolume /Volumes/TestIntegration
          # Run tests
          swift test --filter "IntegrationTests"
      - name: Performance Benchmarks
        run: swift run Benchmarks --json > benchmarks.json
      - name: Upload Benchmarks
        uses: actions/upload-artifact@v4
        with:
          name: benchmarks
          path: benchmarks.json
      - name: Check Benchmarks Thresholds
        run: swift run CheckBenchmarks benchmarks.json
  
  build:
    needs: test
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Build Release
        run: xcodebuild -scheme Everything -configuration Release
      - name: Notarize
        run: |
          xcrun notarytool submit Everything.app --apple-id $APPLE_ID --team-id $TEAM_ID --wait
      - name: Upload Artifacts
        uses: actions/upload-artifact@v4
        with:
          name: Everything-release
          path: build/Release/Everything.app
```

### 7.2 Benchmark Thresholds (Fail Build If Exceeded)
```json
// benchmarks_thresholds.json
{
  "initial_scan_100k_files_sec": { "max": 3.0, "target": 2.0 },
  "initial_scan_1M_files_sec": { "max": 20.0, "target": 15.0 },
  "search_latency_p99_ms": { "max": 50, "target": 10 },
  "memory_1M_files_mb": { "max": 350, "target": 250 },
  "db_size_1M_files_mb": { "max": 30, "target": 25 },
  "launch_time_cold_sec": { "max": 2.0, "target": 1.0 },
  "index_update_latency_p99_us": { "max": 500, "target": 100 }
}
```

---

## 8. Development Workflow

### 7.1 Local Development Loop
```bash
# Terminal 1: Build & run with debug logging
EVERYTHING_DEBUG_CONSOLE=1 swift run Everything

# Terminal 2: Watch structured logs
tail -f ~/Library/Logs/Everything/Everything_*.log | jq .

# Terminal 3: Metrics endpoint
curl http://localhost:9090/metrics | head -50

# Terminal 4: Run validation gates on demand
swift run ValidatePhase1
```

### 7.2 Pre-Commit Hooks
```bash
# .git/hooks/pre-commit
#!/bin/bash
swiftlint lint --strict
swift test --filter "UnitTests" --parallel
# Quick validation (subset)
swift run ValidatePhase1 --quick
```

---

## 8. Observability Stack Summary

| Layer | Tool | Purpose |
|-------|------|---------|
| **Logs** | Custom JSON Lines + `jq` | Structured, queryable, correlated |
| **Metrics** | Prometheus exposition + custom registry | Real-time health, alerting, dashboards |
| **Traces** | In-memory span buffer + debug UI | Distributed request flow |
| **Debug UI** | Built-in (⌘⌥D) | Live inspection, manual commands |
| **Validation** | Executable gates + golden masters | Automated phase verification |
| **Tests** | XCTest + Thread Sanitizer + Property-based | Correctness, concurrency safety |
| **CI** | GitHub Actions (macOS runners) | Automated gates on every PR |

---

## 9. Quick Start Checklist for Phase 1

Before writing any scanner code, set up:

- [ ] **Logger** with JSON Lines output to `~/Library/Logs/Everything/`
- [ ] **MetricsRegistry** with all counters/gauges/histograms defined
- [ ] **HTTP /metrics endpoint** on port 9090 (localhost only)
- [ ] **TraceContext** propagation through XPC
- [ ] **DebugConsoleWindowController** accessible via ⌘⌥D
- [ ] **ValidationGates** skeleton with all 12 gates (stubs returning `.pending`)
- [ ] **Golden master test volume** (2GB APFS DMG with known content)
- [ ] **Unit test targets** for parsers, VM, index
- [ ] **GitHub Actions CI** with macOS runner
- [ ] **Benchmark runner** with threshold config

Then implement Phase 1 gates **one at a time**, each gate must pass before moving to next.

---

## 10. Example: First Gate Implementation Order

```swift
// Phase1GateRunner.swift
@main
struct Phase1GateRunner {
    static func main() async {
        let gates: [() async throws -> GateResult] = [
            validateHelperInstallation,      // 1. Can we talk to helper?
            validateXPCConnection,           // 2. XPC handshake works?
            validateVolumeEnumeration,       // 3. See APFS volumes?
            validateRawDeviceAccess,         // 4. Read /dev/diskXsY?
            validateSuperblockParsing,       // 5. NX/Container/Volume headers?
            validateOMAPResolution,          // 6. Virtual OID → physical block?
            validateFSTreeIteration,         // 7. Walk B-Tree leaves?
            validateRecordParsing,           // 8. Inode/Dir/Extent parse?
            validateIndexBuild,              // 9. Nodes → IndexManager?
            validateNameSearch,              // 10. Search "test" works?
            validatePersistence,             // 11. Save/load DB?
            validateMemoryBudget,            // 12. < 100MB for 100k files?
        ]
        
        for (i, gate) in gates.enumerated() {
            print("🔍 Gate \(i+1)/\(gates.count): \(gateName(gate))...")
            do {
                let result = try await gate()
                print(result.passed ? "✅ PASS" : "❌ FAIL")
                print("   \(result.details)")
                print("   Duration: \(String(format: "%.3f", result.duration))s")
                if !result.passed { exit(1) }
            } catch {
                print("❌ ERROR: \(error)")
                exit(1)
            }
        }
        print("🎉 All Phase 1 gates passed!")
    }
}
```

Run after each implementation step:
```bash
swift run Phase1GateRunner
# Or specific gate:
swift run Phase1GateRunner --gate 7
```