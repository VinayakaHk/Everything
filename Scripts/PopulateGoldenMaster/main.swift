#!/usr/bin/swift
// Scripts/PopulateGoldenMaster/main.swift
// Creates a golden master test volume with known content

import Foundation

// This script creates a test DMG with known file structure
// Run with: swift run PopulateGoldenMaster

let fileManager = FileManager.default

// Golden master structure:
let goldenMasterContent = [
    // Root files
    ("README.md", "# Everything Test Volume\n\nThis is a golden master test volume for Everything-macOS integration tests.\n"),
    ("LICENSE.txt", "MIT License\n\nCopyright (c) 2024\n"),
    ("config.json", "{\"version\": \"1.0\", \"test\": true}\n"),
    
    // Source code
    ("src/main.c", "#include <stdio.h>\n\nint main() {\n    printf(\"Hello, World!\\n\");\n    return 0;\n}\n"),
    ("src/utils.h", "#ifndef UTILS_H\n#define UTILS_H\n\nvoid helper();\n\n#endif\n"),
    ("src/utils.c", "#include \"utils.h\"\n#include <stdio.h>\n\nvoid helper() {\n    printf(\"Helper function\\n\");\n}\n"),
    
    // Documents
    ("docs/guide.md", "# User Guide\n\n## Getting Started\n\nThis is the user guide.\n"),
    ("docs/api.md", "# API Reference\n\n## Functions\n\n- `init()`\n- `cleanup()`\n"),
    ("docs/changelog.md", "# Changelog\n\n## v1.0.0\n- Initial release\n"),
    
    // Test files
    ("tests/test_main.c", "#include <assert.h>\n\nvoid test_add() {\n    assert(1 + 1 == 2);\n}\n"),
    ("tests/test_utils.c", "#include \"utils.h\"\n#include <assert.h>\n\nvoid test_helper() {\n    helper(); // Just verify it compiles\n}\n"),
    
    // Binary-like files (with specific sizes)
    ("data/small.bin", String(repeating: "A", count: 100)),
    ("data/medium.bin", String(repeating: "B", count: 1024)),
    ("data/large.bin", String(repeating: "C", count: 1024 * 1024)), // 1MB
    
    // Compressed-like (repetitive)
    ("data/compressed.txt", String(repeating: "compressed content ", count: 1000)),
    
    // Hard link targets (will be linked later)
    ("hardlinks/target1.txt", "This is the target for hardlink1\n"),
    ("hardlinks/target2.txt", "This is the target for hardlink2\n"),
    
    // Symlink targets
    ("symlinks/target.txt", "Symlink target content\n"),
    
    // Files with special characters
    ("special/файл.txt", "Cyrillic filename\n"),
    ("special/文件.txt", "Chinese filename\n"),
    ("special/ファイル.txt", "Japanese filename\n"),
    ("special/🎉.txt", "Emoji filename\n"),
    ("special/file with spaces.txt", "Spaces in filename\n"),
    ("special/file\"with\"quotes.txt", "Quotes in filename\n"),
    ("special/file\\with\\backslashes.txt", "Backslashes in filename\n"),
    
    // Deeply nested
    (["deep", "nested", "structure", "level1", "level2", "level3", "deep.txt"], "Deeply nested file\n"),
    
    // Empty files
    ("empty.txt", ""),
    ("empty_dir/.keep", ""),
]

func createGoldenMaster() {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("GoldenMaster_\(UUID().uuidString)")
    
    print("Creating golden master at: \(tempDir.path)")
    
    try? FileManager.default.removeItem(at: tempDir)
    try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    
    // Create all files
    for item in goldenMasterContent {
        let path: String
        let content: String
        
        if let tuple = item as? (String, String) {
            path = tuple.0
            content = tuple.1
        } else if let tuple = item as? ([String], String) {
            path = tuple.0.joined(separator: "/")
            content = tuple.1
        } else {
            continue
        }
        
        let fileURL = tempDir.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
    // Create hard links
    let target1 = tempDir.appendingPathComponent("hardlinks/target1.txt")
    let link1 = tempDir.appendingPathComponent("hardlinks/link1.txt")
    try! FileManager.default.linkItem(at: target1, to: link1)
    
    let link2 = tempDir.appendingPathComponent("other/link_to_target1.txt")
    try! FileManager.default.createDirectory(at: link2.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! FileManager.default.linkItem(at: target1, to: link2)
    
    // Create symlinks
    let symlinkTarget = tempDir.appendingPathComponent("symlinks/target.txt")
    let symlink1 = tempDir.appendingPathComponent("symlinks/link.txt")
    try! FileManager.default.createSymbolicLink(at: symlink1, withDestinationURL: symlinkTarget)
    
    let symlink2 = tempDir.appendingPathComponent("symlinks/relative_link.txt")
    try! FileManager.default.createSymbolicLink(at: symlink2, withDestinationURL: URL(fileURLWithPath: "target.txt", relativeTo: symlink2.deletingLastPathComponent()))
    
    // Create empty directory
    let emptyDir = tempDir.appendingPathComponent("empty_dir")
    try! FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
    
    // Set some file attributes (timestamps, permissions)
    let now = Date()
    let oldDate = Date(timeIntervalSinceNow: -86400 * 30) // 30 days ago
    
    for item in goldenMasterContent {
        let path: String
        if let tuple = item as? (String, String) {
            path = tuple.0
        } else if let tuple = item as? ([String], String) {
            path = tuple.0.joined(separator: "/")
        } else {
            continue
        }
        
        let fileURL = tempDir.appendingPathComponent(path)
        
        // Set random-ish timestamps
        let randomInterval = TimeInterval(arc4random_uniform(86400 * 365))
        let modDate = Date(timeIntervalSinceNow: -randomInterval)
        try! FileManager.default.setAttributes([
            .modificationDate: modDate,
            .creationDate: modDate.addingTimeInterval(-86400 * 7)
        ], ofItemAtPath: fileURL.path)
    }
    
    // Generate manifest
    var manifest: [[String: Any]] = []
    let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey, .linkCountKey])
    
    while let fileURL = enumerator?.nextObject() as? URL {
        let relativePath = fileURL.path.replacingOccurrences(of: tempDir.path + "/", with: "")
        let attrs = try! FileManager.default.attributesOfItem(atPath: fileURL.path)
        
        var entry: [String: Any] = [
            "path": relativePath,
            "size": attrs[.size] as? Int64 ?? 0,
            "created": (attrs[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            "modified": (attrs[.contentModificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            "isDirectory": attrs[.type] as? String == "NSFileTypeDirectory",
            "isSymlink": attrs[.type] as? String == "NSFileTypeSymbolicLink",
            "linkCount": attrs[.referenceCount] as? Int ?? 1
        ]
        
        if entry["isSymlink"] as? Bool == true {
            let target = try! FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)
            entry["symlinkTarget"] = target
        }
        
        manifest.append(entry)
    }
    
    let manifestURL = tempDir.appendingPathComponent(".golden_manifest.json")
    let manifestData = try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
    try! manifestData.write(to: manifestURL)
    
    print("Golden master created at: \(tempDir.path)")
    print("Files: \(manifest.count)")
    print("Manifest: \(manifestURL.path)")
    
    // Optionally create DMG
    print("\nTo create DMG:")
    print("  hdiutil create -srcfolder \"\(tempDir.path)\" -fs APFS -volname \"GoldenMaster\" GoldenMaster.dmg")
}

createGoldenMaster()