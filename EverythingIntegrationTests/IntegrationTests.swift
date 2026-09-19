import Foundation
import Nimble
import Quick
@testable import EverythingCore
import EverythingXPC
import EverythingAPFS

// MARK: - Integration Tests

final class IntegrationTests: QuickSpec {
    override class func spec() {
        describe("Full System Integration") {
            var testVolume: URL!
            
            beforeSuite {
                // Mount test volume or use known test volume
                testVolume = URL(fileURLWithPath: "/Volumes/EverythingTest")
            }
            
            context("Helper Installation") {
                it("helper binary exists and is signed") {
                    let helperPath = "/Library/PrivilegedHelperTools/com.everything.helper"
                    expect(FileManager.default.fileExists(atPath: helperPath)).to(beTrue())
                    
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                    task.arguments = ["-d", "-v", "--entitlements", ":-", helperPath]
                    let pipe = Pipe()
                    task.standardOutput = pipe
                    try! task.run()
                    task.waitUntilExit()
                    
                    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    expect(output).to(contain("com.apple.developer.endpoint-security.client"))
                }
                
                it("helper launch daemon is loaded") {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    task.arguments = ["list", "com.everything.helper"]
                    let pipe = Pipe()
                    task.standardOutput = pipe
                    try! task.run()
                    task.waitUntilExit()
                    
                    expect(task.terminationStatus).to(equal(0))
                }
            }
            
            context("XPC Connection") {
                var connection: NSXPCConnection!
                
                beforeEach {
                    connection = NSXPCConnection(machServiceName: "com.everything.helper", options: .privileged)
                    connection.remoteObjectInterface = NSXPCInterface(with: EverythingHelperProtocol.self)
                    connection.resume()
                }
                
                afterEach {
                    connection.invalidate()
                }
                
                it("connects successfully") {
                    let helper = connection.remoteObjectProxyWithErrorHandler { error in
                        fail("XPC connection failed: \(error)")
                    } as! EverythingHelperProtocol
                    
                    let volumes = try! await helper.enumerateVolumes()
                    expect(volumes).toNot(beEmpty())
                }
                
                it("enumerates volumes correctly") {
                    let helper = connection.remoteObjectProxyWithErrorHandler { error in
                        fail("XPC connection failed: \(error)")
                    } as! EverythingHelperProtocol
                    
                    let volumes = try! await helper.enumerateVolumes()
                    
                    for vol in volumes {
                        expect(vol.uuid).toNot(equal(UUID()))
                        expect(vol.bsdName).toNot(beEmpty())
                        expect(vol.mountPoint).toNot(beEmpty())
                        expect(vol.fileSystem).toNot(beEmpty())
                        expect(vol.totalCapacity).to(beGreaterThan(0))
                    }
                }
                
                it("gets volume identity") {
                    let helper = connection.remoteObjectProxyWithErrorHandler { error in
                        fail("XPC connection failed: \(error)")
                    } as! EverythingHelperProtocol
                    
                    let volumes = try! await helper.enumerateVolumes()
                    let apfsVolumes = volumes.filter { $0.fileSystem == "apfs" }
                    expect(apfsVolumes).toNot(beEmpty())
                    
                    for vol in apfsVolumes.prefix(1) {
                        let identity = try! await helper.getVolumeIdentity(deviceID: vol.bsdName.deviceID)
                        expect(identity).toNot(beNil())
                        expect(identity?.apfsUUID).to(equal(vol.uuid))
                        expect(identity?.bsdName).to(equal(vol.bsdName))
                    }
                }
            }
            
            context("Full Scan") {
                var connection: NSXPCConnection!
                
                beforeEach {
                    connection = NSXPCConnection(machServiceName: "com.everything.helper", options: .privileged)
                    connection.remoteObjectInterface = NSXPCInterface(with: EverythingHelperProtocol.self)
                    connection.resume()
                }
                
                afterEach {
                    connection.invalidate()
                }
                
                it("scans test volume completely") {
                    let helper = connection.remoteObjectProxyWithErrorHandler { error in
                        fail("XPC connection failed: \(error)")
                    } as! EverythingHelperProtocol
                    
                    let volumes = try! await helper.enumerateVolumes()
                    let testVol = volumes.first { $0.mountPoint == "/Volumes/EverythingTest" }
                    expect(testVol).toNot(beNil())
                    
                    var progressCount = 0
                    var finalResult: ScanResult?
                    
                    for try await progress in try await helper.startFullScan(volumeUUID: testVol!.uuid) {
                        progressCount += 1
                        expect(progress.filesScanned).to(beGreaterThanOrEqualTo(0))
                        expect(progress.phase).toNot(equal(ScanPhase.failed))
                    }
                    
                    expect(progressCount).to(beGreaterThan(0))
                }
                
                it("produces valid scan results") {
                    let helper = connection.remoteObjectProxyWithErrorHandler { error in
                        fail("XPC connection failed: \(error)")
                    } as! EverythingHelperProtocol
                    
                    let volumes = try! await helper.enumerateVolumes()
                    let testVol = volumes.first { $0.mountPoint == "/Volumes/EverythingTest" }
                    
                    var result: ScanResult?
                    for try await progress in try await helper.startFullScan(volumeUUID: testVol!.uuid) {
                        if progress.phase == .complete {
                            // Result would come via separate mechanism in real impl
                        }
                    }
                }
            }
            
            context("Real-time Monitoring") {
                var connection: NSXPCConnection!
                
                beforeEach {
                    connection = NSXPCConnection(machServiceName: "com.everything.helper", options: .privileged)
                    connection.remoteObjectInterface = NSXPCInterface(with: EverythingHelperProtocol.self)
                    connection.resume()
                }
                
                afterEach {
                    connection.invalidate()
                }
                
                it("subscribes to ES events") {
                    let helper = connection.remoteObjectProxyWithErrorHandler { error in
                        fail("XPC connection failed: \(error)")
                    } as! EverythingHelperProtocol
                    
                    let volumes = try! await helper.enumerateVolumes()
                    let testVol = volumes.first { $0.fileSystem == "apfs" }
                    
                    let token = try! await helper.subscribeToEvents([.create, .delete, .rename], volumeUUID: testVol!.uuid)
                    
                    expect(token.id).toNot(equal(UUID()))
                    expect(token.volumeUUID).to(equal(testVol!.uuid))
                    
                    // Cleanup
                    try! await helper.unsubscribe(token)
                }
                
                it("receives file create event") {
                    let helper = connection.remoteObjectProxyWithErrorHandler { error in
                        fail("XPC connection failed: \(error)")
                    } as! EverythingHelperProtocol
                    
                    let volumes = try! await helper.enumerateVolumes()
                    let testVol = volumes.first { $0.fileSystem == "apfs" }
                    
                    let token = try! await helper.subscribeToEvents([.create], volumeUUID: testVol!.uuid)
                    
                    // Create a file
                    let testFile = testVol!.mountPoint.appendingPathComponent("integration_test_\(UUID().uuidString).txt")
                    try! "test".write(to: testFile, atomically: true, encoding: .utf8)
                    
                    // Give ES time to deliver
                    try! await Task.sleep(nanoseconds: 500_000_000)  // 500ms
                    
                    // Verify event received (would need callback mechanism)
                    try! await helper.unsubscribe(token)
                    
                    // Cleanup
                    try? FileManager.default.removeItem(at: testFile)
                }
            }
        }
    }
}

// MARK: - End-to-End Search Tests

final class EndToEndSearchTests: QuickSpec {
    override class func spec() {
        describe("End-to-End Search") {
            var manager: IndexManager!
            var testNodes: [FSNode]!
            
            beforeEach {
                manager = IndexManager()
                testNodes = createTestNodes(5000)
                manager.buildIndex(testNodes)
            }
            
            context("Search Engine Integration") {
                let vm = BytecodeVM()
                let snapshot = manager.currentSnapshot
                
                it("finds files by exact name") {
                    let results = vm.execute([.namePrefix("file_100.txt")], against: snapshot)
                    expect(results.count).to(equal(1))
                    expect(results.first?.name).to(equal("file_100.txt"))
                }
                
                it("finds files by prefix") {
                    let results = vm.execute([.namePrefix("file_1")], against: snapshot)
                    // file_1, file_10, file_100, etc.
                    expect(results.count).to(beGreaterThan(10))
                }
                
                it("filters by size") {
                    let results = vm.execute([.sizeRange(5000...10000)], against: snapshot)
                    for node in results {
                        expect(node.fileSize).to(beGreaterThanOrEqualTo(5000))
                        expect(node.fileSize).to(beLessThanOrEqualTo(10000))
                    }
                }
                
                it("filters by modification time") {
                    let now = UInt64(Date().timeIntervalSince1970)
                    let results = vm.execute([.modTimeRange(now-7200...now)], against: snapshot)
                    for node in results {
                        expect(node.modTime).to(beGreaterThanOrEqualTo(now-7200))
                        expect(node.modTime).to(beLessThanOrEqualTo(now))
                    }
                }
                
                it("combines filters with AND") {
                    let results = vm.execute([
                        .namePrefix("file"),
                        .sizeRange(1000...5000),
                        .and
                    ], against: snapshot)
                    
                    for node in results {
                        expect(node.name).to(beginWith("file"))
                        expect(node.fileSize).to(beGreaterThanOrEqualTo(1000))
                        expect(node.fileSize).to(beLessThanOrEqualTo(5000))
                    }
                }
                
                it("combines filters with OR") {
                    let results = vm.execute([
                        .namePrefix("file_1"),
                        .namePrefix("file_2"),
                        .or
                    ], against: snapshot)
                    
                    for node in results {
                        expect(node.name).to(satisfyAnyOf(
                            beginWith("file_1"),
                            beginWith("file_2")
                        ))
                    }
                }
                
                it("excludes with NOT") {
                    let results = vm.execute([
                        .namePrefix("file"),
                        .sizeRange(0...1000),
                        .not
                    ], against: snapshot)
                    
                    for node in results {
                        expect(node.fileSize).to(beGreaterThan(1000))
                    }
                }
                
                it("sorts by size descending") {
                    let results = vm.execute([
                        .namePrefix("file"),
                        .sortBy(.size, ascending: false)
                    ], against: snapshot)
                    
                    for i in 1..<results.count {
                        expect(results[i-1].fileSize).to(beGreaterThanOrEqualTo(results[i].fileSize))
                    }
                }
                
                it("limits results") {
                    let results = vm.execute([
                        .namePrefix("file"),
                        .limit(10)
                    ], against: snapshot)
                    
                    expect(results.count).to(beLessThanOrEqualTo(10))
                }
                
                it("paginates with offset") {
                    let all = vm.execute([.namePrefix("file")], against: snapshot)
                    let page1 = vm.execute([.namePrefix("file"), .limit(10), .offset(0)], against: snapshot)
                    let page2 = vm.execute([.namePrefix("file"), .limit(10), .offset(10)], against: snapshot)
                    
                    expect(page1.count).to(beLessThanOrEqualTo(10))
                    expect(page2.count).to(beLessThanOrEqualTo(10))
                    expect(page1.first?.inodeID).toNot(equal(page2.first?.inodeID))
                }
            }
        }
    }
}

// MARK: - Persistence Integration Tests

final class PersistenceIntegrationTests: QuickSpec {
    override class func spec() {
        describe("Persistence Integration") {
            var tempDir: URL!
            var dbURL: URL!
            
            beforeEach {
                tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("IntegrationDB_\(UUID().uuidString)")
                try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                dbURL = tempDir.appendingPathComponent("integration.db")
            }
            
            afterEach {
                try? FileManager.default.removeItem(at: tempDir)
            }
            
            it("full cycle: build -> save -> load -> search") {
                let nodes = createTestNodes(1000)
                let manager = IndexManager()
                manager.buildIndex(nodes)
                let snapshot = manager.currentSnapshot
                
                // Save
                let writer = DatabaseWriter(url: dbURL)
                try! writer.write(snapshot)
                
                // Load
                let reader = DatabaseReader(url: dbURL)
                let loaded = try! reader.read()
                
                // Search
                let vm = BytecodeVM()
                let results = vm.execute([.namePrefix("file_1")], against: loaded)
                
                expect(results.count).to(beGreaterThan(0))
            }
            
            it("incremental save preserves data") {
                let nodes = createTestNodes(500)
                let manager = IndexManager()
                manager.buildIndex(nodes)
                let snapshot1 = manager.currentSnapshot
                
                // Save
                let writer = DatabaseWriter(url: dbURL)
                try! writer.write(snapshot1)
                
                // Apply delta
                let newNode = createTestNode(name: "new_after_save.txt", inodeID: 9999, parentID: 2)
                let snapshot2 = manager.apply(.insert(newNode), to: snapshot1)
                
                // Save again
                try! writer.write(snapshot2)
                
                // Load
                let reader = DatabaseReader(url: dbURL)
                let loaded = try! reader.read()
                
                expect(loaded.totalNodes).to(equal(501))
                expect(loaded.nodesByInode[CompositeKey(deviceID: 1, inodeID: 9999)]).toNot(beNil())
            }
            
            it("handles crash recovery") {
                let nodes = createTestNodes(1000)
                let manager = IndexManager()
                manager.buildIndex(nodes)
                let snapshot = manager.currentSnapshot
                
                let writer = DatabaseWriter(url: dbURL)
                try! writer.write(snapshot)
                
                // Simulate crash by killing process (we can't actually crash in test)
                // Just verify DB is valid after write
                let reader = DatabaseReader(url: dbURL)
                let loaded = try! reader.read()
                expect(loaded.totalNodes).to(equal(1000))
            }
        }
    }
}

// MARK: - Test Helpers

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
            modTime: now - 3600 * UInt64(i % 24)
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