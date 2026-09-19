#!/bin/bash
# scripts/dev.sh - Development environment setup and run

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "🔧 Everything-macOS Development Environment"
echo "=========================================="

# Check for required tools
check_tool() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ $1 not found. Please install it."
        exit 1
    fi
    echo "✅ $1 found"
}

echo "Checking tools..."
check_tool xcodebuild
check_tool swift
check_tool swiftlint
check_tool jq

# Resolve dependencies
echo ""
echo "📦 Resolving Swift packages..."
swift package resolve

# Build
echo ""
echo "🔨 Building..."
xcodebuild -scheme Everything -configuration Debug -quiet
xcodebuild -scheme EverythingHelper -configuration Debug -quiet
xcodebuild -scheme EverythingTests -configuration Debug -quiet

echo ""
echo "✅ Build successful!"

# Run unit tests
echo ""
echo "🧪 Running unit tests..."
swift test --filter EverythingUnitTests --parallel

# Run validation gates
echo ""
echo "🚦 Running Phase 1 validation gates..."
swift run Phase1GateRunner --gate 1

echo ""
echo "✅ Development environment ready!"
echo ""
echo "To run the app:"
echo "  swift run Everything"
echo ""
echo "To run benchmarks:"
echo "  swift run EverythingBenchmarks all"
echo ""
echo "To view logs:"
echo "  tail -f ~/Library/Logs/Everything/*.log | jq ."
echo ""
echo "To view metrics:"
echo "  curl http://localhost:9090/metrics"