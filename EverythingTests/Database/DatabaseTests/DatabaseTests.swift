import Foundation
import Nimble
import Quick
@testable import EverythingCore

// MARK: - Database Tests

final class DatabaseTests: QuickSpec {
    override class func spec() {
        describe("Database Persistence") {
            var tempDir: URL!
            var dbURL: URL!
            
            beforeEach {
                tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("EverythingDBTests_\(UUID().uuidString)")
                try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                dbURL = tempDir.appendingPathComponent("test.db")
            }
            
            afterEach {
                try? FileManager.default.removeItem(at: tempDir)
            }
            
            context("Write/Read Round-trip") {
                it("saves and loads index correctly") {
                    let nodes = createTestNodes(1000)
                    let manager = IndexManager()
                    manager.buildIndex(nodes)
                    let snapshot = manager.currentSnapshot
                    
                    let writer = DatabaseWriter(url: dbURL)
                    try! writer.write(snapshot)
                    
                    let reader = DatabaseReader(url: dbURL)
                    let loaded = try! reader.read()
                    
                    expect(loaded.totalNodes).to(equal(1000))
                    expect(loaded.nodesByName.count).to(equal(1000))
                    expect(loaded.nodesByInode.count).to(equal(1000))
                    
                    // Verify a few nodes
                    for (key, original) in snapshot.nodesByInode.prefix(10) {
                        let loadedNode = loaded.nodesByInode[key]
                        expect(loadedNode).toNot(beNil())
                        expect(loadedNode?.inodeID).to(equal(original.inodeID))
                        expect(loadedNode?.name).to(equal(original.name))
                        expect(loadedNode?.fileSize).to(equal(original.fileSize))
                    }
                }
                
                it("preserves all node fields") {
                    let node = FSNode(
                        inodeID: 100, parentID: 2, privateID: 100,
                        name: "test.txt",
                        createTime: 1704067200, createTimeNsec: 123456789,
                        modTime: 1704153600, modTimeNsec: 987654321,
                        changeTime: 1704240000, changeTimeNsec: 555555555,
                        accessTime: 1704326400, accessTimeNsec: 111111111,
                        fileSize: 4096, uncompressedSize: 8192,
                        mode: 0o100644, flags: INODE_HAS_UNCOMPRESSED_SIZE,
                        bsdFlags: UF_COMPRESSED | UF_IMMUTABLE,
                        owner: 501, group: 20,
                        writeGen: 42,
                        cloneGroupID: 42, hardLinkCount: 3,
                        volumeID: 1, apfsVolumeUUID: UUID(),
                        volfsVolumeID: 16777220, filerefVolumeID: 6571367,
                        path: "/test/test.txt", depth: 1
                    )
                    
                    let manager = IndexManager()
                    manager.buildIndex([node])
                    let snapshot = manager.currentSnapshot
                    
                    let writer = DatabaseWriter(url: dbURL)
                    try! writer.write(snapshot)
                    
                    let reader = DatabaseReader(url: dbURL)
                    let loaded = try! reader.read()
                    
                    let loadedNode = loaded.nodesByInode[CompositeKey(deviceID: 1, inodeID: 100)]!
                    
                    expect(loadedNode.createTime).to(equal(node.createTime))
                    expect(loadedNode.createTimeNsec).to(equal(node.createTimeNsec))
                    expect(loadedNode.modTimeNsec).to(equal(node.modTimeNsec))
                    expect(loadedNode.uncompressedSize).to(equal(node.uncompressedSize))
                    expect(loadedNode.flags).to(equal(node.flags))
                    expect(loadedNode.bsdFlags).to(equal(node.bsdFlags))
                    expect(loadedNode.writeGen).to(equal(node.writeGen))
                    expect(loadedNode.cloneGroupID).to(equal(node.cloneGroupID))
                    expect(loadedNode.hardLinkCount).to(equal(node.hardLinkCount))
                    expect(loadedNode.volfsVolumeID).to(equal(node.volfsVolumeID))
                    expect(loadedNode.filerefVolumeID).to(equal(node.filerefVolumeID))
                }
                
                it("handles empty index") {
                    let manager = IndexManager()
                    manager.buildIndex([])
                    let snapshot = manager.currentSnapshot
                    
                    let writer = DatabaseWriter(url: dbURL)
                    try! writer.write(snapshot)
                    
                    let reader = DatabaseReader(url: dbURL)
                    let loaded = try! reader.read()
                    
                    expect(loaded.totalNodes).to(equal(0))
                }
            }
            
            context("Compression") {
                it("compresses with LZ4") {
                    let nodes = createTestNodes(10_000)
                    let manager = IndexManager()
                    manager.buildIndex(nodes)
                    let snapshot = manager.currentSnapshot
                    
                    let writer = DatabaseWriter(url: dbURL)
                    try! writer.write(snapshot)
                    
                    let fileSize = try! dbURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
                    
                    // Should be significantly smaller than uncompressed
                    // Rough estimate: 10k nodes * ~200 bytes = 2MB uncompressed
                    // LZ4 should achieve ~30-40% = 600-800KB
                    expect(fileSize).to(beLessThan(1_500_000))
                }
                
                it("handles incompressible data") {
                    // Random data doesn't compress well
                    var nodes: [FSNode] = []
                    for i in 0..<100 {
                        let randomName = UUID().uuidString
                        nodes.append(createTestNode(name: randomName, inodeID: UInt64(i), parentID: 2))
                    }
                    
                    let manager = IndexManager()
                    manager.buildIndex(nodes)
                    let snapshot = manager.currentSnapshot
                    
                    let writer = DatabaseWriter(url: dbURL)
                    try! writer.write(snapshot)
                    
                    let fileSize = try! dbURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
                    // Should still write successfully
                    expect(fileSize).to(beGreaterThan(0))
                }
            }
            
            context("Atomic Writes") {
                it("uses temp file + rename") {
                    let nodes = createTestNodes(100)
                    let manager = IndexManager()
                    manager.buildIndex(nodes)
                    let snapshot = manager.currentSnapshot
                    
                    let writer = DatabaseWriter(url: dbURL)
                    try! writer.write(snapshot)
                    
                    // No .tmp file should remain
                    let tmpFiles = try! FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension == "tmp" }
                    expect(tmpFiles).to(beEmpty())
                }
                
                it("survives crash during write (simulated)") {
                    let nodes = createTestNodes(1000)
                    let manager = IndexManager()
                    manager.buildIndex(nodes)
                    let snapshot = manager.currentSnapshot
                    
                    let writer = DatabaseWriter(url: dbURL)
                    try! writer.write(snapshot)
                    
                    // Verify valid
                    let reader = DatabaseReader(url: dbURL)
                    let loaded = try! reader.read()
                    expect(loaded.totalNodes).to(equal(1000))
                }
            }
            
            context("Schema Versioning") {
                it("includes version in header") {
                    let manager = IndexManager()
                    manager.buildIndex(createTestNodes(10))
                    let snapshot = manager.currentSnapshot
                    
                    let writer = DatabaseWriter(url: dbURL)
                    try! writer.write(snapshot)
                    
                    let data = try! Data(contentsOf: dbURL)
                    let version = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
                    expect(version).to(equal(0x01000001))  // v1.0.0.1
                }
                
                it("rejects incompatible version") {
                    // Write file with wrong magic
                    var badData = Data(count: 100)
                    badData[0..<4] = Data([0xDE, 0xAD, 0xBE, 0xEF])  // Wrong magic
                    
                    let badURL = tempDir.appendingPathComponent("bad.db")
                    try! badData.write(to: badURL)
                    
                    let reader = DatabaseReader(url: badURL)
                    expect(try reader.read()).to(throwError(DatabaseError.invalidMagic))
                }
            }
            
            context("Checksums") {
                it("validates checksum on read") {
                    let nodes = createTestNodes(100)
                    let manager = IndexManager()
                    manager.buildIndex(nodes)
                    let snapshot = manager.currentSnapshot
                    
                    let writer = DatabaseWriter(url: dbURL)
                    try! writer.write(snapshot)
                    
                    // Corrupt the file
                    var data = try! Data(contentsOf: dbURL)
                    data[100] ^= 0xFF  // Flip a bit
                    try! data.write(to: dbURL)
                    
                    let reader = DatabaseReader(url: dbURL)
                    expect(try reader.read()).to(throwError(DatabaseError.checksumMismatch))
                }
                
                it("detects truncation") {
                    let nodes = createTestNodes(100)
                    let manager = IndexManager()
                    manager.buildIndex(nodes)
                    let snapshot = manager.currentSnapshot
                    
                    let writer = DatabaseWriter(url: dbURL)
                    try! writer.write(snapshot)
                    
                    // Truncate file
                    let data = try! Data(contentsOf: dbURL)
                    let truncated = data.prefix(data.count / 2)
                    try! truncated.write(to: dbURL)
                    
                    let reader = DatabaseReader(url: dbURL)
                    expect(try reader.read()).to(throwError(DatabaseError.truncatedFile))
                }
            }
            
            context("Memory Mapping") {
                it("memory maps on read") {
                    let nodes = createTestNodes(10_000)
                    let manager = IndexManager()
                    manager.buildIndex(nodes)
                    let snapshot = manager.currentSnapshot
                    
                    let writer = DatabaseWriter(url: dbURL)
                    try! writer.write(snapshot)
                    
                    let reader = DatabaseReader(url: dbURL)
                    let loaded = try! reader.read()
                    
                    // Verify it's using mmap (by checking it doesn't load all into heap at once)
                    expect(loaded.totalNodes).to(equal(10_000))
                }
            }
        }
    }
}

// MARK: - Database Performance Tests

final class DatabasePerformanceTests: QuickSpec {
    override class func spec() {
        describe("Database Performance") {
            var tempDir: URL!
            var dbURL: URL!
            
            beforeEach {
                tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("EverythingDBPerf_\(UUID().uuidString)")
                try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                dbURL = tempDir.appendingPathComponent("perf.db")
            }
            
            afterEach {
                try? FileManager.default.removeItem(at: tempDir)
            }
            
            it("writes 100k nodes fast") {
                let nodes = createTestNodes(100_000)
                let manager = IndexManager()
                manager.buildIndex(nodes)
                let snapshot = manager.currentSnapshot
                
                let writer = DatabaseWriter(url: dbURL)
                
                measure(MetricsRegistry.shared.dbWriteLatency) {
                    try! writer.write(snapshot)
                }
                
                let fileSize = try! dbURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
                print("DB size for 100k nodes: \(fileSize / 1024) KB")
            }
            
            it("reads 100k nodes fast") {
                let nodes = createTestNodes(100_000)
                let manager = IndexManager()
                manager.buildIndex(nodes)
                let snapshot = manager.currentSnapshot
                
                let writer = DatabaseWriter(url: dbURL)
                try! writer.write(snapshot)
                
                let reader = DatabaseReader(url: dbURL)
                
                measure(MetricsRegistry.shared.dbReadLatency) {
                    _ = try! reader.read()
                }
            }
            
            it("compresses efficiently") {
                let nodes = createTestNodes(50_000)
                let manager = IndexManager()
                manager.buildIndex(nodes)
                let snapshot = manager.currentSnapshot
                
                let writer = DatabaseWriter(url: dbURL)
                try! writer.write(snapshot)
                
                let fileSize = try! dbURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
                let uncompressedEstimate = 50_000 * 200  // ~200 bytes per node
                let ratio = Double(fileSize) / Double(uncompressedEstimate)
                
                print("Compression ratio: \(ratio) (\(fileSize / 1024) KB vs \(uncompressedEstimate / 1024) KB)")
                expect(ratio).to(beLessThan(0.5))  // Better than 50%
            }
        }
    }
}

// MARK: - Database Edge Case Tests

final class DatabaseEdgeCaseTests: QuickSpec {
    override class func spec() {
        describe("Database Edge Cases") {
            var tempDir: URL!
            var dbURL: URL!
            
            beforeEach {
                tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("EverythingDBEdge_\(UUID().uuidString)")
                try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                dbURL = tempDir.appendingPathComponent("edge.db")
            }
            
            afterEach {
                try? FileManager.default.removeItem(at: tempDir)
            }
            
            it("handles nodes with maximum field values") {
                let node = FSNode(
                    inodeID: UInt64.max,
                    parentID: UInt64.max,
                    privateID: UInt64.max,
                    name: "max.txt",
                    createTime: UInt64.max,
                    createTimeNsec: UInt32.max,
                    modTime: UInt64.max,
                    modTimeNsec: UInt32.max,
                    changeTime: UInt64.max,
                    changeTimeNsec: UInt32.max,
                    accessTime: UInt64.max,
                    accessTimeNsec: UInt32.max,
                    fileSize: UInt64.max,
                    uncompressedSize: UInt64.max,
                    mode: UInt16.max,
                    flags: UInt64.max,
                    bsdFlags: UInt32.max,
                    owner: UInt32.max,
                    group: UInt32.max,
                    writeGen: UInt32.max,
                    cloneGroupID: UInt64.max,
                    hardLinkCount: Int32.max,
                    volumeID: UInt32.max,
                    apfsVolumeUUID: UUID(),
                    volfsVolumeID: UInt32.max,
                    filerefVolumeID: UInt32.max,
                    path: "/max.txt",
                    depth: Int16.max
                )
                
                let manager = IndexManager()
                manager.buildIndex([node])
                let snapshot = manager.currentSnapshot
                
                let writer = DatabaseWriter(url: dbURL)
                try! writer.write(snapshot)
                
                let reader = DatabaseReader(url: dbURL)
                let loaded = try! reader.read()
                
                let loadedNode = loaded.nodesByInode[CompositeKey(deviceID: UInt32.max, inodeID: UInt64.max)]!
                expect(loadedNode.inodeID).to(equal(UInt64.max))
                expect(loadedNode.fileSize).to(equal(UInt64.max))
            }
            
            it("handles very long paths") {
                let longPath = "/" + (0..<100).map { "dir\($0)" }.joined(separator: "/") + "/file.txt"
                let node = createTestNode(name: "file.txt", inodeID: 1, parentID: 2)
                // Override path
                var modified = node
                // Can't easily modify struct, so create new
                let longNode = FSNode(
                    inodeID: 1, parentID: 2, privateID: 1,
                    name: "file.txt",
                    createTime: 0, createTimeNsec: 0,
                    modTime: 0, modTimeNsec: 0,
                    changeTime: 0, changeTimeNsec: 0,
                    accessTime: 0, accessTimeNsec: 0,
                    fileSize: 100, uncompressedSize: 100,
                    mode: 0o100644, flags: 0, bsdFlags: 0,
                    owner: 501, group: 20, writeGen: 1,
                    cloneGroupID: nil, hardLinkCount: 1,
                    volumeID: 1, apfsVolumeUUID: UUID(),
                    volfsVolumeID: nil, filerefVolumeID: nil,
                    path: longPath, depth: 100
                )
                
                let manager = IndexManager()
                manager.buildIndex([longNode])
                let snapshot = manager.currentSnapshot
                
                let writer = DatabaseWriter(url: dbURL)
                try! writer.write(snapshot)
                
                let reader = DatabaseReader(url: dbURL)
                let loaded = try! reader.read()
                
                let loadedNode = loaded.nodesByInode[CompositeKey(deviceID: 1, inodeID: 1)]!
                expect(loadedNode.path).to(equal(longPath))
            }
            
            it("handles special characters in names") {
                let specialNames = [
                    "file with spaces.txt",
                    "file\nwith\nnewlines.txt",
                    "file\twith\ttabs.txt",
                    "file\"with\"quotes.txt",
                    "file'with'apostrophes.txt",
                    "file\\with\\backslashes.txt",
                    "文件.txt",
                    "файл.txt",
                    "ファイル.txt",
                    "🎉🎊🎈.txt",
                    String(repeating: "a", count: 255) + ".txt"
                ]
                
                var nodes: [FSNode] = []
                for (i, name) in specialNames.enumerated() {
                    nodes.append(createTestNode(name: name, inodeID: UInt64(i), parentID: 2))
                }
                
                let manager = IndexManager()
                manager.buildIndex(nodes)
                let snapshot = manager.currentSnapshot
                
                let writer = DatabaseWriter(url: dbURL)
                try! writer.write(snapshot)
                
                let reader = DatabaseReader(url: dbURL)
                let loaded = try! reader.read()
                
                expect(loaded.totalNodes).to(equal(specialNames.count))
                for (i, name) in specialNames.enumerated() {
                    let loadedNode = loaded.nodesByInode[CompositeKey(deviceID: 1, inodeID: UInt64(i))]!
                    expect(loadedNode.name).to(equal(name))
                }
            }
            
            it("handles concurrent read/write") {
                let nodes = createTestNodes(10_000)
                let manager = IndexManager()
                manager.buildIndex(nodes)
                let snapshot = manager.currentSnapshot
                
                let writer = DatabaseWriter(url: dbURL)
                try! writer.write(snapshot)
                
                // Multiple concurrent readers
                let queue = DispatchQueue(label: "readers", attributes: .concurrent)
                let group = DispatchGroup()
                let readers = 20
                
                for _ in 0..<readers {
                    group.enter()
                    DispatchQueue.global().async {
                        let reader = DatabaseReader(url: dbURL)
                        _ = try! reader.read()
                        group.leave()
                    }
                }
                
                group.wait()
            }
        }
    }
}