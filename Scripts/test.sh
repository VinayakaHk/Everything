#!/bin/bash
# scripts/test.sh - Run all tests

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "🧪 Everything-macOS Test Suite"
echo "============================="

# Unit tests
echo ""
echo "📋 Unit Tests"
swift test --filter EverythingUnitTests --parallel

# Parser tests
echo ""
echo "📋 APFS Parser Tests"
swift test --filter APFSParsersTests --parallel

# Bytecode VM tests
echo ""
echo "📋 Bytecode VM Tests"
swift test --filter BytecodeVMTests --parallel

# Index Manager tests
echo ""
echo "📋 Index Manager Tests"
swift test --filter IndexManagerTests --parallel

# Database tests
echo ""
echo "📋 Database Tests"
swift test --filter DatabaseTests --parallel

# All unit tests
echo ""
echo "📋 All Unit Tests"
swift test --parallel

# Run Phase 1 gates
echo ""
echo "🚦 Phase 1 Validation Gates"
swift run Phase1GateRunner all --fail-fast

echo ""
echo "✅ All tests passed!"