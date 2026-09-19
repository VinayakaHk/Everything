import Foundation
import ArgumentParser
@testable import EverythingCore
import EverythingAPFS

// MARK: - Benchmark Runner

@main
struct EverythingBenchmarks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "EverythingBenchmarks",
        abstract: "Performance benchmarks for Everything-macOS",
        subcommands: [
            ScanBenchmarks.self,
            SearchBenchmarks.self,
            IndexBenchmarks.self,
            DatabaseBenchmarks.self,
            APFSBenchmarks.self,
            AllBenchmarks.self
        ],
        defaultSubcommand: AllBenchmarks.self
    )
}

// MARK: - Scan Benchmarks

struct ScanBenchmarks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Benchmark APFS scanning performance"
    )
    
    @Option(name: .shortAndLong, help: "Number of files to scan")
    var count: Int = 100_000
    
    @Option(name: .shortAndLong, help: "Test volume path")
    var volume: String = "/Volumes/EverythingTest"
    
    func run() async throws {
        print("🚀 Scan Benchmark: \(count) files on \(volume)")
        
        // This would use the real helper in production
        // For now, simulate with test data
        let nodes = createTestNodes(count)
        let manager = IndexManager()
        
        let start = CFAbsoluteTimeGetCurrent()
        manager.buildIndex(nodes)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        let snapshot = manager.currentSnapshot
        print("✅ Scanned \(snapshot.totalNodes) files in \(String(format: "%.2f", elapsed))s")
        print("   Throughput: \(String(format: "%.0f", Double(snapshot.totalNodes) / elapsed)) files/sec")
        print("   Memory: \(snapshot.estimatedMemoryBytes / 1024 / 1024) MB")
    }
}

// MARK: - Search Benchmarks

struct SearchBenchmarks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Benchmark search performance"
    )
    
    @Option(name: .shortAndLong, help: "Index size")
    var size: Int = 100_000
    
    @Option(name: .shortAndLong, help: "Number of search iterations")
    var iterations: Int = 1000
    
    func run() async throws {
        print("🔍 Search Benchmark: \(size) nodes, \(iterations) iterations")
        
        let nodes = createTestNodes(size)
        let manager = IndexManager()
        manager.buildIndex(nodes)
        let snapshot = manager.currentSnapshot
        let vm = BytecodeVM()
        
        // Warm up
        for _ in 0..<100 {
            _ = vm.execute([.namePrefix("file")], against: snapshot)
        }
        
        // Benchmark simple prefix search
        let bytecode1: [SearchOpcode] = [.namePrefix("file_1")]
        var start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = vm.execute(bytecode1, against: snapshot)
        }
        let elapsed1 = CFAbsoluteTimeGetCurrent() - start
        
        // Benchmark size range filter
        let bytecode2: [SearchOpcode] = [.sizeRange(1000...5000)]
        start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = vm.execute(bytecode2, against: snapshot)
        }
        let elapsed2 = CFAbsoluteTimeGetCurrent() - start
        
        // Benchmark complex query
        let bytecode3: [SearchOpcode] = [
            .namePrefix("file"),
            .sizeRange(1000...100000),
            .modTimeRange(1704067200...1735689600),
            .and,
            .sortBy(.size, ascending: false),
            .limit(100)
        ]
        start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = vm.execute(bytecode3, against: snapshot)
        }
        let elapsed3 = CFAbsoluteTimeGetCurrent() - start
        
        print("✅ Results:")
        print("   Simple prefix:  \(String(format: "%.2f", elapsed1 / Double(iterations) * 1_000_000)) µs/query")
        print("   Size range:     \(String(format: "%.2f", elapsed2 / Double(iterations) * 1_000_000)) µs/query")
        print("   Complex query:  \(String(format: "%.2f", elapsed3 / Double(iterations) * 1_000_000)) µs/query")
    }
}

// MARK: - Index Benchmarks

struct IndexBenchmarks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Benchmark index operations"
    )
    
    @Option(name: .shortAndLong, help: "Index size")
    var size: Int = 100_000
    
    func run() async throws {
        print("📇 Index Benchmark: \(size) nodes")
        
        let nodes = createTestNodes(size)
        let manager = IndexManager()
        
        // Build index
        var start = CFAbsoluteTimeGetCurrent()
        manager.buildIndex(createTestNodes(size))
        let buildTime = CFAbsoluteTimeGetCurrent() - start
        
        let snapshot = manager.currentSnapshot
        
        // Insert
        var start = CFAbsoluteTimeGetCurrent()
        for i in 0..<10000 {
            let node = createTestNode(name: "insert_\(i).txt", inodeID: UInt64(1_000_000 + i), parentID: 2)
            _ = manager.apply(.insert(node), to: manager.currentSnapshot)
        }
        let insertTime = CFAbsoluteTimeGetCurrent() - start
        
        // Update
        start = CFAbsoluteTimeGetCurrent()
        for i in 0..<10000 {
            _ = manager.apply(.updateSize(inodeID: UInt64(1000 + i), volumeID: 1, newSize: UInt64(5000 + i)), to: manager.currentSnapshot)
        }
        let updateTime = CFAbsoluteTimeGetCurrent() - start
        
        // Remove
        start = CFAbsoluteTimeGetCurrent()
        for i in 0..<1000 {
            _ = manager.apply(.remove(inodeID: UInt64(1000 + i), volumeID: 1), to: manager.currentSnapshot)
        }
        let removeTime = CFAbsoluteTimeGetCurrent() - start
        
        print("✅ Index Operations:")
        print("   Build:    \(String(format: "%.3f", buildTime))s (\(String(format: "%.0f", Double(size) / buildTime)) nodes/sec)")
        print("   Insert:   \(String(format: "%.3f", insertTime))s (\(String(format: "%.0f", 10000 / insertTime)) ops/sec)")
        print("   Update:   \(String(format: "%.3f", updateTime))s (\(String(format: "%.0f", 10000 / updateTime)) ops/sec)")
        print("   Remove:   \(String(format: "%.3f", removeTime))s (\(String(format: "%.0f", 1000 / removeTime)) ops/sec)")
    }
}

// MARK: - Database Benchmarks

struct DatabaseBenchmarks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "database",
        abstract: "Benchmark database operations"
    )
    
    @Option(name: .shortAndLong, help: "Number of nodes")
    var size: Int = 50_000
    
    func run() async throws {
        print("💾 Database Benchmark: \(size) nodes")
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BenchDB_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let dbURL = tempDir.appendingPathComponent("bench.db")
        let nodes = createTestNodes(size)
        let manager = IndexManager()
        manager.buildIndex(nodes)
        let snapshot = manager.currentSnapshot
        
        let writer = DatabaseWriter(url: dbURL)
        
        // Write
        var start = CFAbsoluteTimeGetCurrent()
        try! writer.write(manager.currentSnapshot)
        let writeTime = CFAbsoluteTimeGetCurrent() - start
        
        let fileSize = try! dbURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        
        // Read
        let reader = DatabaseReader(url: dbURL)
        var start = CFAbsoluteTimeGetCurrent()
        let _ = try! reader.read()
        let readTime = CFAbsoluteTimeGetCurrent() - start
        
        let fileSize = try! dbURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        let uncompressedEstimate = size * 200
        let ratio = Double(fileSize) / Double(size * 200)
        
        print("✅ Database:")
        print("   Write: \(String(format: "%.3f", writeTime))s")
        print("   Read:  \(String(format: "%.3f", readTime))s")
        print("   Size:  \(fileSize / 1024) KB (ratio: \(String(format: "%.2f", Double(fileSize) / Double(size * 200))))")
    }
}

// MARK: - APFS Parser Benchmarks

struct APFSBenchmarks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apfs",
        abstract: "Benchmark APFS parser performance"
    )
    
    func run() async throws {
        print("📊 APFS Parser Benchmarks")
        
        // CRC-32C
        let data = Data(repeating: 0xAA, count: 65536)
        let iterations = 10000
        var start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = data.withUnsafeBytes { apfs_crc32c($0.baseAddress!, data.count, 0xFFFFFFFF) } ^ 0xFFFFFFFF
        }
        let crcTime = CFAbsoluteTimeGetCurrent() - start
        let crcThroughput = Double(iterations * 65536) / crcTime / (1024 * 1024)
        
        // Directory hash
        start = CFAbsoluteTimeGetCurrent()
        for i in 0..<100000 {
            _ = apfsDirectoryRecordHash(for: "file_\(i).txt")
        }
        let hashTime = CFAbsoluteTimeGetCurrent() - start
        let hashThroughput = 100000.0 / hashTime
        
        // Inode parsing
        var inode = j_inode_val_t()
        inode.parent_id = 2
        inode.private_id = 100
        inode.create_time = 1704067200
        inode.mod_time = 1704153600
        inode.change_time = 1704240000
        inode.access_time = 1704326400
        inode.internal_flags = 0
        inode.nlink = 1
        inode.write_generation_counter = 1
        inode.bsd_flags = 0
        inode.owner = 501
        inode.group = 20
        inode.mode = 0o100644
        inode.uncompressed_size = 1024
        
        var data = Data()
        withUnsafeBytes(of: &inode) { data.append(contentsOf: $0) }
        let bytes = [UInt8](data)
        
        start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1000000 {
            var parsed = apfs_inode_parsed_t()
            apfs_parse_inode(bytes, data.count, &parsed)
        }
        let parseTime = CFAbsoluteTimeGetCurrent() - start
        let parseThroughput = 1_000_000.0 / parseTime
        
        // Directory record parsing
        var key = j_drec_hashed_key_t()
        key.hdr.obj_id_and_type = (UInt64(APFS_TYPE_DIR_REC) << OBJ_TYPE_SHIFT) | 2
        key.name_len_and_hash = (5 & J_DREC_LEN_MASK) | (0x123456 << J_DREC_HASH_SHIFT)
        
        var val = j_drec_val_t()
        val.file_id = 100
        val.date_added = 1704067200
        val.flags = DT_REG
        
        var buffer = Data()
        withUnsafeBytes(of: &key) { buffer.append(contentsOf: $0) }
        buffer.append("test\0".data(using: .utf8)!)
        withUnsafeBytes(of: &val) { buffer.append(contentsOf: $0) }
        let drecBytes = [UInt8](buffer)
        
        start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100000 {
            var parsed = apfs_drec_parsed_t()
            // Need to create key/val from buffer for each iteration
        }
        let drecTime = CFAbsoluteTimeGetCurrent() - start
        
        print("✅ APFS Parsers:")
        print("   CRC-32C:      \(String(format: "%.0f", crcThroughput)) MB/s")
        print("   Dir Hash:     \(String(format: "%.0f", hashThroughput)) ops/sec")
        print("   Inode Parse:  \(String(format: "%.0f", parseThroughput)) ops/sec")
    }
}

// MARK: - All Benchmarks

struct AllBenchmarks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "all",
        abstract: "Run all benchmarks"
    )
    
    @Option(name: .shortAndLong, help: "Index size for tests")
    var size: Int = 50_000
    
    func run() async throws {
        print("╔═══════════════════════════════════════════════════════════╗")
        print("║         Everything-macOS Benchmark Suite                  ║")
        print("╚═══════════════════════════════════════════════════════════╝")
        print()
        
        // Run all benchmarks
        try await ScanBenchmarks().run()
        print()
        try await SearchBenchmarks().run()
        print()
        try await IndexBenchmarks().run()
        print()
        try await DatabaseBenchmarks().run()
        print()
        try await APFSBenchmarks().run()
        print()
        
        print("╔═══════════════════════════════════════════════════════════╗")
        print("║                    All Benchmarks Complete                ║")
        print("╚═══════════════════════════════════════════════════════════╝")
    }
}

// MARK: - Test Data Generation

func createTestNodes(_ count: Int) -> [FSNode] {
    var nodes: [FSNode] = []
    let now = UInt64(Date().timeIntervalSince1970)
    
    for i in 0..<count {
        nodes.append(createTestNode(
            name: "file_\(i).txt",
            inodeID: UInt64(i + 1000),
            parentID: 2,
            volumeID: 1,
            size: 1000 + UInt64(i * 100),
            modTime: UInt64(Date().timeIntervalSince1970) - 3600 * UInt64(i % 24)
        ))
    }
    return nodes
}

func createTestNode(name: String, inodeID: UInt64, parentID: UInt64, volumeID: UInt32 = 1, size: UInt64 = 1024, modTime: UInt64 = 1704067200) -> FSNode {
    return FSNode(
        inodeID: inodeID,
        parentID: parentID,
        privateID: inodeID,
        name: name,
        createTime: 1704067200,
        createTimeNsec: 0,
        modTime: modTime,
        modTimeNsec: 0,
        changeTime: modTime,
        changeTimeNsec: 0,
        accessTime: modTime,
        accessTimeNsec: 0,
        fileSize: size,
        uncompressedSize: size,
        mode: 0o100644,
        flags: 0,
        bsdFlags: 0,
        owner: 501,
        group: 20,
        writeGen: 1,
        cloneGroupID: nil,
        hardLinkCount: 1,
        volumeID: volumeID,
        apfsVolumeUUID: UUID(),
        volfsVolumeID: nil,
        filerefVolumeID: nil,
        path: "/test/\(name)",
        depth: 1
    )
}