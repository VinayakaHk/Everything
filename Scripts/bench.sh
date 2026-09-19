#!/bin/bash
# scripts/bench.sh - Run performance benchmarks

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "📊 Everything-macOS Benchmarks"
echo "============================="

# Check for existing benchmark results to compare
RESULTS_DIR="$PROJECT_DIR/benchmark_results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULTS_FILE="$RESULTS_DIR/bench_$TIMESTAMP.json"

echo "Running all benchmarks..."
swift run EverythingBenchmarks all --size 50000 2>&1 | tee "$RESULTS_FILE.txt"

# Also run with different sizes
echo ""
echo "Running with different sizes..."
for size in 10000 50000 100000; do
    echo "Size: $size"
    swift run EverythingBenchmarks search --size $size --iterations 1000 2>&1 | grep -E "(prefix|Size range|Complex)" | head -3
done

echo ""
echo "✅ Benchmarks complete!"
echo "Results saved to: $RESULTS_FILE.txt"