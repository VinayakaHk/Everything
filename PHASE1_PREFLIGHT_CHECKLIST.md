# Phase 1 Pre-Flight Checklist: Technical & Observability Only

**Rule**: Do not write scanner code until every item is ✅. Each item has a verification command.

---

## 0. Repository & Tooling Foundation

| # | Item | Verification |
|---|------|--------------|
| 0.1 | Xcode project builds clean (Debug + Release) | `xcodebuild -scheme Everything -configuration Debug build` → **SUCCEEDED** |
| 0.2 | Swift Package Manager resolves deps | `swift package resolve` → **resolved** |
| 0.3 | SwiftLint passes strict mode | `swiftlint lint --strict` → **0 warnings, 0 errors** |
| 0.4 | Git hooks installed (pre-commit: lint + unit tests) | `.git/hooks/pre-commit` exists + executable |
| 0.5 | `.swift-format` config committed | `cat .swift-format` shows config |
| 0.6 | Xcode schemes: `Everything`, `EverythingHelper`, `EverythingTests`, `EverythingBenchmarks` | `xcodebuild -list` shows all 4 |
| 0.7 | Code signing identity configured (Developer ID Application + Developer ID Installer) | `xcodebuild -showBuildSettings | grep CODE_SIGN_IDENTITY` shows valid IDs |
| 0.8 | Entitlements files exist for both targets | `Everything.entitlements`, `EverythingHelper.entitlements` in repo |
| 0.9 | Info.plist keys: `NSPrincipalClass`, `CFBundleIdentifier`, `LSMinimumSystemVersion` | `plutil -p Info.plist` |
| 0.10 | Minimum deployment target: macOS 11.0 (Big Sur) | `MACOSX_DEPLOYMENT_TARGET = 11.0` |

---

## 1. Privileged Helper Infrastructure

| # | Item | Verification |
|---|------|--------------|
| 1.1 | `SMJobBless` integration compiles | `xcodebuild -target EverythingHelper` → **SUCCEEDED** |
| 1.2 | LaunchDaemon plist valid (`/Library/LaunchDaemons/com.everything.helper.plist`) | `plutil -lint LaunchDaemon.plist` → **OK** |
| 1.3 | Helper binary installs to `/Library/PrivilegedHelperTools/com.everything.helper` | `ls -la /Library/PrivilegedHelperTools/com.everything.helper` |
| 1.4 | Helper runs as root (verified via `whoami` in helper log) | `grep "running as" ~/Library/Logs/Everything/Helper.log` |
| 1.5 | XPC service name matches: `com.everything.helper` | `launchctl list | grep everything` |
| 1.6 | Helper entitlements: `com.apple.developer.endpoint-security.client`, `com.apple.security.cs.disable-library-validation` | `codesign -d --entitlements :- /Library/PrivilegedHelperTools/com.everything.helper` |
| 1.7 | Helper auto-starts on boot (LaunchDaemon `RunAtLoad = true`) | Reboot Mac → `launchctl list | grep everything` |
| 1.8 | Helper restarts on crash (`KeepAlive = true`) | `kill -9 $(pgrep -f everything.helper)` → auto-restarts in <5s |
| 1.9 | UI can detect helper not installed → show install prompt | Run app without helper → shows "Install Helper" button |
| 1.10 | Uninstall flow: `SMJobRemove` + cleanup | `sudo /Applications/Everything.app/Contents/MacOS/Everything --uninstall-helper` |

---

## 2. XPC Communication Layer

| # | Item | Verification |
|---|------|--------------|
| 2.1 | Protocol defined in shared framework (`EverythingXPC`) | `EverythingXPC/EverythingHelperProtocol.swift` exists |
| 2.2 | Protocol versioning (semver in `protocolVersion`) | `protocolVersion = "1.0.0"` |
| 2.3 | XPC connection establishes (< 500ms) | Metric: `xpc_connection_latency_seconds` < 0.5 |
| 2.4 | Connection survives helper restart (reconnect logic) | Kill helper → UI reconnects automatically |
| 2.5 | Connection survives UI restart (helper stays alive) | Quit app → relaunch → connection works |
| 2.6 | All async methods use `async/await` (no completion handlers) | `grep -r "completionHandler" EverythingXPC/` → **0 results** |
| 2.7 | Timeout on all calls (30s default, configurable) | `XPCTimeout.default = 30` |
| 2.8 | Error propagation: helper errors → UI as typed `Error` | `try await helper.doThing()` throws `HelperError.xpcFailed` |
| 2.9 | Large payloads: streaming for scan progress (not single reply) | `AsyncStream<ScanProgress>` used |
| 2.10 | Correlation ID propagated across XPC boundary | Logs show same `correlationID` in UI + helper |

---

## 3. Observability Infrastructure (Must Work Before Gate 1)

| # | Item | Verification |
|---|------|--------------|
| 3.1 | Logger writes JSON Lines to `~/Library/Logs/Everything/Everything_YYYYMMDD.log` | `tail -1 ~/Library/Logs/Everything/*.log \| jq .` → valid JSON |
| 3.2 | Log fields: timestamp(µs), level, subsystem, category, message, correlationID, file, function, line | `jq 'keys' log.json` → all present |
| 3.3 | Log rotation: daily, max 100MB/file, 7 days retention | `ls -la ~/Library/Logs/Everything/` shows rotated files |
| 3.4 | `EVERYTHING_DEBUG_CONSOLE=1` mirrors to stderr | `EVERYTHING_DEBUG_CONSOLE=1 swift run Everything 2>&1 \| head -1 \| jq .` |
| 3.5 | MetricsRegistry: all 24 metrics defined (12 counters, 7 gauges, 5 histograms) | `curl -s localhost:9090/metrics \| grep -c '^everything_'` → **24** |
| 3.6 | `/metrics` HTTP endpoint on localhost:9090 (UI + helper) | `curl -s localhost:9090/metrics \| head -5` |
| 3.7 | Metrics updated in real-time (scan increments, search increments) | `watch -n1 'curl -s localhost:9090/metrics \| grep scan_files_total'` |
| 3.8 | TraceContext: UUID traceID/spanID, parentSpanID, baggage | `curl -s localhost:9090/debug/traces \| jq .[0].traceID` |
| 3.9 | TraceContext propagated via XPC (helper spans share traceID) | Same traceID in UI + helper logs for one request |
| 3.10 | Debug console accessible via ⌘⌥D (UI) | Press ⌘⌥D → window opens |
| 3.11 | Debug console tabs: Logs, Metrics, Traces, Index, Volumes, Clones, Snapshots, Commands | 8 tabs visible |
| 3.12 | Search bar commands work: `/debug`, `/index_stats`, `/volume_map`, `/trace_dump` | Type `/index_stats` → output in debug console |

---

## 4. Validation Gates Framework

| # | Item | Verification |
|---|------|--------------|
| 4.1 | `Phase1GateRunner` executable target exists | `swift run Phase1GateRunner --help` shows usage |
| 4.2 | All 12 gates implemented (stubs return `.pending` initially) | `swift run Phase1GateRunner --list` shows 12 gates |
| 4.3 | Gate result struct: name, passed, duration, details, metrics | `swift run Phase1GateRunner --gate 1 --json \| jq .` |
| 4.4 | Gate runner exits non-zero on any failure | `swift run Phase1GateRunner --gate 1` → exit code 1 if fail |
| 4.5 | Gate timeout: 60s per gate (configurable) | `Phase1GateRunner --timeout 30` |
| 4.6 | CI runs gates on every PR | `.github/workflows/ci.yml` has `ValidatePhase1` step |
| 4.7 | Gate 1 (Helper Installation) actually validates: binary exists, signed, launchd loaded, service running | `swift run Phase1GateRunner --gate 1` → PASS only if all 4 true |
| 4.8 | Gate output includes actionable details on failure | `details: "binary missing at /Library/PrivilegedHelperTools/..."` |

---

## 5. Test Infrastructure

| # | Item | Verification |
|---|------|--------------|
| 5.1 | Golden master test volume: 2GB APFS DMG at `TestVolumes/golden_master.dmg` | `ls -la TestVolumes/golden_master.dmg` (2GB) |
| 5.2 | Golden master mounted at `/Volumes/EverythingTest` in CI | `hdiutil attach TestVolumes/golden_master.dmg -mountpoint /Volumes/EverythingTest` |
| 5.3 | Golden master population script: `Scripts/populate_golden_master.swift` | `swift run PopulateGoldenMaster` → creates known structure |
| 5.4 | Golden master manifest JSON: `TestVolumes/golden_master_manifest.json` | `jq '.files | length' golden_master_manifest.json` → **known count** |
| 5.5 | Unit test target: `EverythingUnitTests` (parsers, VM, index) | `swift test --filter EverythingUnitTests` |
| 5.6 | Integration test target: `EverythingIntegrationTests` (requires golden master) | `swift test --filter EverythingIntegrationTests` |
| 5.7 | Property-based test dependency: `SwiftCheck` or `QuickCheck` in Package.swift | `swift package show-dependencies \| grep -i swiftcheck` |
| 5.8 | Thread Sanitizer enabled for test scheme | `xcodebuild test -scheme EverythingTests -enableThreadSanitizer YES` |
| 5.9 | Address Sanitizer enabled for test scheme | `xcodebuild test -scheme EverythingTests -enableAddressSanitizer YES` |
| 5.10 | Code coverage target: > 80% for parser/index/VM modules | `xcodebuild test -scheme EverythingTests -enableCodeCoverage YES \| xcrun xccov view --json` |

---

## 6. APFS Parsing Foundations (Before Scanner)

| # | Item | Verification |
|---|------|--------------|
| 6.1 | C module `EverythingAPFS` with modulemap | `EverythingAPFS/EverythingAPFS.h` + `module.modulemap` |
| 6.2 | APFS structs match Joe Sylve blog exactly (j_key_t, j_inode_val_t, j_drec_hashed_key_t, j_drec_val_t) | `diff <(grep -A 20 "j_inode_val_t" EverythingAPFS/apfs_structs.h) <(curl -s jtsylve.blog/.../inode)` → **match** |
| 6.3 | Endianness handling: all on-disk little-endian, host conversion | `APFS_READ_LE64()` macro used everywhere |
| 6.4 | CRC-32C implementation for dir record hash (Castagnoli polynomial) | `CRC32C.compute(data)` matches known test vectors |
| 6.5 | UTF-8 → NFD → casefold → UTF-32 pipeline for hash | `DirRecordHasher.hash("README.md")` == known value |
| 6.6 | Object Map resolver: virtual OID → physical block (B-Tree descent) | `OMAPResolver.resolve(oid: fstree_oid)` returns block data |
| 6.7 | B-Tree node parser: internal vs leaf, key/value extraction | `BTreeNode.parse(block)` → keys + values |
| 6.8 | Record type dispatch: switch on high 4 bits of obj_id_and_type | `RecordParser.parse(key, value)` → enum `Record` |
| 6.9 | Extended fields parser (xf_blob_t, x_field_t) | `ExtendedFields.parse(data)` → `[ExtendedField]` |
| 6.10 | Unit tests for each parser with golden master binary blobs | `swift test --filter APFSParsersTests` → **all pass** |

---

## 7. Index & Search Foundations

| # | Item | Verification |
|---|------|--------------|
| 7.1 | `FSNode` struct with all 23 fields (including nsec timestamps, volume IDs) | `MemoryLayout<FSNode>.stride` == expected (≈200 bytes) |
| 7.2 | `CompositeKey(deviceID: UInt32, inodeID: UInt64)` Hashable | `Set<CompositeKey>()` works |
| 7.3 | `SortedArray<T>` wrapper with binary search (`prefixRange`, `range`) | `SortedArray([1,2,3]).prefixRange(2...)` → `[2,3]` |
| 7.4 | `IndexSnapshot` copy-on-write (struct with COW arrays) | Modifying snapshot doesn't affect original |
| 7.5 | `IndexManager.apply(Delta)` produces new snapshot | `let new = manager.apply(.insert(node))` |
| 7.6 | Search AST: enum with all operators (and, or, not, group, modifiers) | `QueryParser.parse("foo bar \| baz")` → valid AST |
| 7.7 | BytecodeCompiler: AST → `[SearchOpcode]` | `BytecodeCompiler.compile(ast)` → opcodes |
| 7.8 | BytecodeVM: executes all opcodes, returns `CandidateSet` | `vm.execute(bytecode, snapshot)` → results |
| 7.9 | CandidateSet operations: intersect, union, difference, filter | `a.intersect(b).filter { $0.size > 1000 }` |
| 7.10 | Property-based tests: random queries vs brute force on small index | `swift test --filter BytecodeVMTests/testRandomQueries` |

---

## 8. Database Persistence

| # | Item | Verification |
|---|------|--------------|
| 8.1 | LZ4 compression via `lz4-swift` or system `compression` | `Compression.compress(data, algorithm: .lz4)` |
| 8.2 | Binary format: header, volume table, exclude list, node table, property indexes, string table, footer | `DatabaseWriter.write(index)` → valid `.db` |
| 8.3 | Delta-encoding: parentID, timestamps, inodeIDs | `DatabaseEncoder.deltaEncode(nodes)` |
| 8.4 | String table: prefix compression (common path prefixes) | `StringTable.compress(paths)` → size reduction > 50% |
| 8.5 | Atomic write: `.tmp` → `fsync` → `rename` | `DatabaseWriter.flush()` → no partial DB on crash |
| 8.6 | mmap on load (read-only) | `DatabaseReader.mmap(url)` → `UnsafeBufferPointer` |
| 8.7 | Schema version in header, migration path for v1→v2 | `DatabaseReader.migrateIfNeeded()` |
| 8.8 | Checksum (xxHash64) in footer, verified on load | `DatabaseReader.verifyChecksum()` → true |
| 8.9 | Round-trip test: index → save → load → index == original | `swift test --filter DatabaseTests/testRoundTrip` |
| 8.10 | Corruption detection: truncated file, bad checksum, wrong magic | `DatabaseReader.load(corrupted.db)` → throws `DatabaseError` |

---

## 9. CI/CD & Benchmarks

| # | Item | Verification |
|---|------|--------------|
| 9.1 | GitHub Actions workflow: `.github/workflows/ci.yml` | `cat .github/workflows/ci.yml` |
| 9.2 | Runner: `macos-14` (Apple Silicon) | `runs-on: macos-14` |
| 9.3 | Steps: checkout → resolve → lint → unit tests → integration tests → benchmarks | `grep -A 20 "steps:" .github/workflows/ci.yml` |
| 9.4 | Integration tests mount golden master DMG | `hdiutil attach` in workflow |
| 9.5 | Benchmark runner: `Benchmarks` executable, JSON output | `swift run Benchmarks --json > bench.json` |
| 9.6 | Benchmark thresholds file: `benchmarks_thresholds.json` | `cat benchmarks_thresholds.json` |
| 9.7 | CI fails if any threshold exceeded | `swift run CheckBenchmarks bench.json` exits 1 on fail |
| 9.8 | Artifacts: benchmarks.json, test logs, coverage | `actions/upload-artifact@v4` |
| 9.9 | Release workflow: notarization, DMG creation, GitHub Release | `.github/workflows/release.yml` |
| 9.10 | Dependabot for Swift packages | `.github/dependabot.yml` exists |

---

## 10. Developer Experience (Local Loop)

| # | Item | Verification |
|---|------|--------------|
| 10.1 | `make dev` or script: builds, installs helper, launches app with debug logs | `./scripts/dev.sh` → app running |
| 10.2 | `make test` runs unit + integration + validation gates | `./scripts/test.sh` |
| 10.3 | `make bench` runs benchmarks, compares to thresholds | `./scripts/bench.sh` |
| 10.4 | `make clean` removes build artifacts, uninstalls helper | `./scripts/clean.sh` |
| 10.5 | VSCode/Xcode launch configurations for UI + Helper debugging | `.vscode/launch.json` + Xcode schemes |
| 10.6 | Log viewing alias: `elog` → `tail -f ~/Library/Logs/Everything/*.log \| jq .` | `alias elog` works |
| 10.7 | Metrics viewing alias: `emetrics` → `watch -n1 'curl -s localhost:9090/metrics \| grep everything'` | `alias emetrics` works |
| 10.8 | Gate runner alias: `egate` → `swift run Phase1GateRunner` | `alias egate` works |

---

## 11. Security Hardening (Pre-Implementation)

| # | Item | Verification |
|---|------|--------------|
| 11.1 | Hardened Runtime enabled for both targets | `codesign -d -v --entitlements :- Everything.app \| grep "runtime"` |
| 11.2 | Library Validation enabled (except helper) | `codesign -d -v Everything.app \| grep "library-validation"` |
| 11.3 | Debug symbols stripped in Release | `dsymutil -v Everything.app` → dSYM created |
| 11.4 | No sensitive strings in binary (API keys, paths) | `strings Everything.app/Contents/MacOS/Everything \| grep -i "key\|secret\|password"` → **none** |
| 11.5 | Helper only accepts connections from same Team ID | `NSXPCConnection` with `requireCodeSignature = true` |
| 11.6 | XPC messages validated (no arbitrary code execution) | Protocol only allows defined methods |
| 11.7 | Raw device access: helper opens `O_RDONLY | O_NOFOLLOW`, never `O_RDWR` | `grep "O_RDWR" EverythingHelper/` → **0 results** |
| 11.8 | No dynamic library loading (dlopen) in helper | `grep "dlopen\|dladdr" EverythingHelper/` → **0 results** |

---

## 12. Sign-Off: Ready for Phase 1 Implementation

**All 120 items must be ✅ before writing `APFSScanner.swift`**

```
Phase 1 Pre-Flight: [ ] PASS / [ ] FAIL
Date: _____________
Engineer: _____________
Git SHA: _____________

Blockers (if any):
1. ___________________________________
2. ___________________________________
3. ___________________________________
```

---

## Quick Verification Script

```bash
#!/bin/bash
# scripts/preflight_check.sh
# Run before every Phase 1 implementation session

set -e

echo "🔍 Phase 1 Pre-Flight Check"
echo "==========================="

checks=(
    "xcodebuild -scheme Everything -quiet 2>&1 | tail -1 | grep -q SUCCEEDED && echo '✅ Build' || echo '❌ Build'"
    "swiftlint lint --quiet 2>&1 && echo '✅ Lint' || echo '❌ Lint'"
    "swift test --filter EverythingUnitTests --quiet 2>&1 && echo '✅ Unit Tests' || echo '❌ Unit Tests'"
    "curl -s localhost:9090/metrics | grep -q 'everything_' && echo '✅ Metrics' || echo '❌ Metrics'"
    "swift run Phase1GateRunner --list 2>&1 | grep -q '12 gates' && echo '✅ Gates' || echo '❌ Gates'"
    "ls -la TestVolumes/golden_master.dmg 2>/dev/null && echo '✅ Golden Master' || echo '❌ Golden Master'"
    "swift test --filter APFSParsersTests --quiet 2>&1 && echo '✅ APFS Parsers' || echo '❌ APFS Parsers'"
    "swift test --filter BytecodeVMTests --quiet 2>&1 && echo '✅ Bytecode VM' || echo '❌ Bytecode VM'"
    "swift test --filter IndexManagerTests --quiet 2>&1 && echo '✅ Index Manager' || echo '❌ Index Manager'"
    "swift test --filter DatabaseTests --quiet 2>&1 && echo '✅ Database' || echo '❌ Database'"
)

for check in "${checks[@]}"; do
    eval "$check"
done

echo ""
echo "Run: swift run Phase1GateRunner --gate 1  # Start with Gate 1"
```