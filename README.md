# Everything-macOS

An instant file search engine for macOS built on APFS internals — the macOS equivalent of [voidtools Everything](https://www.voidtools.com/) for Windows.

## Overview

Everything-macOS achieves instant search by directly reading the APFS File System Tree (FS-Tree) B-Tree structures, bypassing the VFS layer entirely. It monitors real-time changes via Apple's EndpointSecurity framework with FSEvents fallback.

### Key Features

- **Instant search** — Sub-millisecond name search on millions of files
- **APFS-native** — Reads FS-Tree directly via Object Map, supports clones, snapshots, hard links, DECMPFS compression
- **Real-time updates** — EndpointSecurity (primary) + FSEvents (fallback) monitoring
- **Privacy-first** — No telemetry, no network connections unless explicitly enabled, runs offline
- **Extensible** — Plugin architecture, CLI, SDK for integration

## Architecture

```
┌─────────────────┐     XPC      ┌──────────────────────┐
│  Everything.app │ ◄─────────► │ EverythingHelper.xpc │
│  (Sandboxed)    │             │     (Root, XPC)      │
└─────────────────┘             └──────────────────────┘
       │                                 │
       ▼                                 ▼
┌─────────────────┐             ┌──────────────────┐
│  Bytecode VM    │             │  APFS Scanner    │
│  In-Memory Index│             │  + EndpointSecurity│
└─────────────────┘             └──────────────────┘
```

## Requirements

- macOS 11.0+ (Big Sur)
- APFS-formatted volumes (HFS+/FAT/exFAT via folder indexing)
- Apple Silicon or Intel (Universal Binary)
- Administrator privileges for helper installation

## Installation

```bash
# Clone and build
git clone https://github.com/VinayakaHk/Everything.git
cd Everything
./scripts/dev.sh

# Install privileged helper (requires sudo)
sudo .build/debug/Everything --install-helper

# Run
swift run Everything
```

## Usage

### CLI

```bash
# Basic search
everything search "test"

# Filter by size
everything search "test" --size 1000..5000

# Filter by modification time
everything search "test" --modified 2024-01-01..2024-12-31

# JSON output for scripting
everything search "test" --json --limit 10

# Sort by size descending
everything search "test" --sort size --no-ascending

# Index management
everything index build --force
everything index status

# Helper management
everything helper install
everything helper status

# Configuration
everything config list
everything config set theme dark
```

### Search Syntax

| Operator | Description |
|----------|-------------|
| ` ` (space) | AND |
| `\|` | OR |
| `!` | NOT |
| `< >` | Grouping |
| `"` | Literal |

**Modifiers:** `case:`, `nocase:`, `wholeword:`, `path:`, `regex:`

**Functions:**
- `name:`, `stem:`, `ext:`, `parent:`, `size:`
- `modified:`, `created:`, `accessed:`
- `clonegroup:`, `snapshot:`, `compressed:`, `encrypted:`
- `width:`, `height:`, `duration:`
- `md5:`, `sha256:`
- `content:` (via Spotlight)

## Development

### Prerequisites

- Xcode 15+
- Swift 5.9+
- swiftlint (`brew install swiftlint`)

### Quick Start

```bash
./scripts/dev.sh
```

This will:
1. Resolve Swift dependencies
2. Build all targets (Debug)
3. Run unit tests
4. Run Phase 1 validation gates

### Testing

```bash
# All tests
./scripts/test.sh

# Specific test suites
swift test --filter EverythingUnitTests
swift test --filter APFSParsersTests
swift test --filter BytecodeVMTests
swift test --filter IndexManagerTests
swift test --filter DatabaseTests

# Integration tests (requires test volume)
./scripts/test.sh --integration
```

### Benchmarks

```bash
# All benchmarks
./scripts/bench.sh

# Specific benchmarks
swift run EverythingBenchmarks scan --count 100000
swift run EverythingBenchmarks search --size 100000 --iterations 1000
swift run EverythingBenchmarks index --size 100000
swift run EverythingBenchmarks database --size 50000
swift run EverythingBenchmarks apfs
```

### Phase 1 Validation Gates

```bash
# Run all gates
swift run Phase1GateRunner all

# Individual gates
swift run Phase1GateRunner gate1   # Helper installation
swift run Phase1GateRunner gate2   # XPC connection
swift run Phase1GateRunner gate3   # Volume enumeration
# ... gate4 through gate12
```

### Observability

```bash
# View logs (JSON Lines)
tail -f ~/Library/Logs/Everything/*.log | jq .

# View metrics (Prometheus format)
curl http://localhost:9090/metrics

# Debug console (in app)
# Press ⌘⌥D
```

## Project Structure

```
Everything/
├── Package.swift                    # Swift Package Manager manifest
├── .github/workflows/ci.yml        # GitHub Actions CI
├── .vscode/                        # VS Code configuration
├── Scripts/
│   ├── dev.sh                       # Development setup
│   ├── test.sh                      # Test runner
│   ├── bench.sh                     # Benchmark runner
│   ├── clean.sh                     # Clean build artifacts
│   └── PopulateGoldenMaster/        # Test volume generator
├── Everything/                      # Main app target
│   └── Sources/
│       ├── App/                     # CLI entry point
│       └── Core/                    # Core library (EverythingCore)
├── EverythingHelper/                # Privileged XPC helper
│   └── Sources/
│       ├── Core/                    # Helper core logic
│       └── Service/                 # XPC service implementation
├── EverythingXPC/                   # Shared XPC protocol
├── EverythingAPFS/                  # APFS parsing (C + Swift)
├── EverythingTests/                 # Unit tests
├── EverythingIntegrationTests/      # Integration tests
├── EverythingBenchmarks/            # Performance benchmarks
├── Phase1GateRunner/               # Phase 1 validation
├── Documentation/                   # Technical docs
└── TestVolumes/                     # Test volumes (gitignored)
```

## Documentation

- [Technical Specification](EVERYTHING_MACOS_APFS_SPEC.md) — Complete APFS architecture
- [System Design](SYSTEM_DESIGN.md) — Implementation design
- [Observability Strategy](OBSERVABILITY.md) — Logging, metrics, tracing
- [Phase 1 Pre-Flight Checklist](PHASE1_PREFLIGHT_CHECKLIST.md) — 120 validation items

## License

MIT License — see [LICENSE](LICENSE) for details.

## Acknowledgments

- **voidtools Everything** — The original Windows inspiration
- **Joe Sylve (jtsylve.blog)** — APFS internals documentation
- **Apple** — EndpointSecurity, APFS, FileProvider frameworks
- **Swift community** — Swift Package Manager, swift-argument-parser