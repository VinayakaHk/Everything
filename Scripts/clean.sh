#!/bin/bash
# scripts/clean.sh - Clean build artifacts

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "🧹 Everything-macOS Clean"
echo "========================="

# Clean Swift build artifacts
echo "Cleaning Swift build artifacts..."
swift package clean

# Clean Xcode derived data
echo "Cleaning Xcode derived data..."
xcodebuild -alltargets clean -quiet 2>/dev/null || true

# Remove build directory
rm -rf .build
rm -rf build

# Uninstall helper if installed
if [ -f "/Library/PrivilegedHelperTools/com.everything.helper" ]; then
    echo "Uninstalling helper..."
    sudo /Applications/Everything.app/Contents/MacOS/Everything --uninstall-helper 2>/dev/null || true
fi

# Remove LaunchDaemon
if [ -f "/Library/LaunchDaemons/com.everything.helper.plist" ]; then
    echo "Removing LaunchDaemon..."
    sudo launchctl unload /Library/LaunchDaemons/com.everything.helper.plist 2>/dev/null || true
    sudo rm -f /Library/LaunchDaemons/com.everything.helper.plist
fi

# Remove helper binary
if [ -f "/Library/PrivilegedHelperTools/com.everything.helper" ]; then
    sudo rm -f /Library/PrivilegedHelperTools/com.everything.helper
fi

# Clean test volumes
if [ -d "TestVolumes" ]; then
    echo "Cleaning test volumes..."
    # Don't remove golden master
fi

# Clean temporary files
echo "Cleaning temp files..."
rm -rf /tmp/Everything* 2>/dev/null || true

echo ""
echo "✅ Clean complete!"