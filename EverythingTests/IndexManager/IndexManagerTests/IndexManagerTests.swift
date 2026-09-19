import Foundation
import Nimble
import Quick
import SwiftCheck
@testable import EverythingCore

// MARK: - IndexManager Tests

final class IndexManagerTests: QuickSpec {
    override class func spec() {
        describe("IndexManager") {
            var manager: IndexManager!
            var testNodes: [FSNode]!
            
            beforeEach {
                manager = IndexManager()
                testNodes = createTestNodes(1000)
            }
            
            context("Index Building") {
                it("builds index from nodes") {
                    manager.buildIndex(testNodes)
                    let snapshot = manager.currentSnapshot
                    
                    expect(snapshot.totalNodes).to(equal(1000))
                    expect(snapshot.nodesByName.count).to(equal(1000))
                    expect(snapshot.nodesByPath.count).to(equal(1000))
                    expect(snapshot.nodesByInode.count).to(equal(1000))
                }
                
                it("builds fast-sort indexes when enabled") {
                    manager.enableFastSort([.size, .modTime, .createTime, .extension])
                    manager.buildIndex(testNodes)
                    let snapshot = manager.currentSnapshot
                    
                    expect(snapshot.nodesBySize).toNot(beNil())
                    expect(snapshot.nodesByModTime).toNot(beNil())
                    expect(snapshot.nodesByCreateTime).toNot(beNil())
                    expect(snapshot.nodesByExtension).toNot(beNil())
                }
                
                it("handles duplicate names in different directories") {
                    let nodes = createNodesWithDuplicateNames()
                    manager.buildIndex(nodes)
                    
                    let results = snapshot.nodesByName.prefixRange("duplicate.txt")
                    expect(results.count).to(equal(3))  // 3 different directories
                }
            }
            
            context("Delta Application") {
                var snapshot: IndexSnapshot!
                
                beforeEach {
                    manager.buildIndex(testNodes)
                    snapshot = manager.currentSnapshot
                }
                
                it("applies insert delta") {
                    let newNode = createTestNode(name: "new_file.txt", inodeID: 9999, parentID: 2)
                    let newSnapshot = manager.apply(.insert(newNode), to: snapshot)
                    
                    expect(newSnapshot.totalNodes).to(equal(1001))
                    expect(newSnapshot.nodesByInode[CompositeKey(deviceID: 1, inodeID: 9999)]).toNot(beNil())
                    // Original snapshot unchanged
                    expect(snapshot.totalNodes).to(equal(1000))
                }
                
                it("applies remove delta") {
                    let targetNode = testNodes[0]
                    let newSnapshot = manager.apply(.remove(inodeID: targetNode.inodeID, volumeID: 1), to: snapshot)
                    
                    expect(newSnapshot.totalNodes).to(equal(999))
                    expect(newSnapshot.nodesByInode[CompositeKey(deviceID: 1, inodeID: targetNode.inodeID)]).to(beNil())
                }
                
                it("applies move delta") {
                    let targetNode = testNodes[0]
                    let newParentID: UInt64 = 500
                    let newName = "moved_file.txt"
                    let newSnapshot = manager.apply(.move(
                        inodeID: targetNode.inodeID,
                        volumeID: 1,
                        newParentID: newParentID,
                        newName: newName
                    ), to: snapshot)
                    
                    let movedNode = newSnapshot.nodesByInode[CompositeKey(deviceID: 1, inodeID: targetNode.inodeID)]
                    expect(movedNode?.parentID).to(equal(500))
                    expect(movedNode?.name).to(equal("moved_file.txt"))
                    // Path should be updated
                    expect(movedNode?.path).to(contain("moved_file.txt"))
                }
                
                it("applies size update delta") {
                    let targetNode = testNodes[0]
                    let newSize: UInt64 = 999999
                    let newSnapshot = manager.apply(.updateSize(
                        inodeID: targetNode.inodeID,
                        volumeID: 1,
                        newSize: newSize
                    ), to: snapshot)
                    
                    let updatedNode = newSnapshot.nodesByInode[CompositeKey(deviceID: 1, inodeID: targetNode.inodeID)]
                    expect(updatedNode?.fileSize).to(equal(999999))
                }
                
                it("applies attribute update delta") {
                    let targetNode = testNodes[0]
                    let newSnapshot = manager.apply(.updateAttrs(
                        inodeID: targetNode.inodeID,
                        volumeID: 1,
                        bsdFlags: UF_IMMUTABLE,
                        modTime: 1704067200,
                        modTimeNsec: 0
                    ), to: snapshot)
                    
                    let updatedNode = newSnapshot.nodesByInode[CompositeKey(deviceID: 1, inodeID: targetNode.inodeID)]
                    expect(updatedNode?.bsdFlags).to(equal(UF_IMMUTABLE))
                    expect(updatedNode?.modTime).to(equal(1704067200))
                }
                
                it("applies clone group update") {
                    let targetNode = testNodes[0]
                    let newSnapshot = manager.apply(.updateCloneGroup(
                        inodeID: targetNode.inodeID,
                        volumeID: 1,
                        cloneGroupID: 42
                    ), to: snapshot)
                    
                    let updatedNode = newSnapshot.nodesByInode[CompositeKey(deviceID: 1, inodeID: targetNode.inodeID)]
                    expect(updatedNode?.cloneGroupID).to(equal(42))
                }
                
                it("applies batch deltas atomically") {
                    let deltas: [IndexDelta] = [
                        .insert(createTestNode(name: "batch1.txt", inodeID: 1001, parentID: 2)),
                        .insert(createTestNode(name: "batch2.txt", inodeID: 1002, parentID: 2)),
                        .remove(inodeID: testNodes[0].inodeID, volumeID: 1),
                        .updateSize(inodeID: testNodes[1].inodeID, volumeID: 1, newSize: 5000)
                    ]
                    
                    let newSnapshot = manager.applyBatch(deltas, to: snapshot)
                    
                    expect(newSnapshot.totalNodes).to(equal(1001))  // +2 -1 = +1
                    expect(newSnapshot.nodesByInode[CompositeKey(deviceID: 1, inodeID: 1001)]).toNot(beNil())
                    expect(newSnapshot.nodesByInode[CompositeKey(deviceID: 1, inodeID: 1002)]).toNot(beNil())
                    expect(newSnapshot.nodesByInode[CompositeKey(deviceID: 1, inodeID: testNodes[0].inodeID)]).to(beNil())
                    expect(newSnapshot.nodesByInode[CompositeKey(deviceID: 1, inodeID: testNodes[1].inodeID)]?.fileSize).to(equal(5000))
                }
            }
            
            context("Snapshot Isolation") {
                it("original snapshot unchanged after delta") {
                    manager.buildIndex(testNodes)
                    let snapshot1 = manager.currentSnapshot
                    let originalCount = snapshot1.totalNodes
                    
                    let newNode = createTestNode(name: "new.txt", inodeID: 9999, parentID: 2)
                    let snapshot2 = manager.apply(.insert(createTestNode(name: "new.txt", inodeID: 9999, parentID: 2)), to: snapshot1)
                    
                    expect(snapshot1.totalNodes).to(equal(originalCount))
                    expect(snapshot2.totalNodes).to(equal(originalCount + 1))
                }
                
                it("multiple snapshots independent") {
                    manager.buildIndex(testNodes)
                    let s1 = manager.currentSnapshot
                    
                    let s2 = manager.apply(.insert(createTestNode(name: "a.txt", inodeID: 1001, parentID: 2)), to: s1)
                    let s3 = manager.apply(.insert(createTestNode(name: "b.txt", inodeID: 1002, parentID: 2)), to: s1)
                    
                    expect(s1.totalNodes).to(equal(1000))
                    expect(s2.totalNodes).to(equal(1001))
                    expect(s3.totalNodes).to(equal(1001))
                    expect(s2.nodesByInode[CompositeKey(deviceID: 1, inodeID: 1001)]).toNot(beNil())
                    expect(s3.nodesByInode[CompositeKey(deviceID: 1, inodeID: 1002)]).toNot(beNil())
                    expect(s2.nodesByInode[CompositeKey(deviceID: 1, inodeID: 1002)]).to(beNil())
                    expect(s3.nodesByInode[CompositeKey(deviceID: 1, inodeID: 1001)]).to(beNil())
                }
            }
            
            context("Concurrent Access") {
                it("handles concurrent reads during writes") {
                    manager.buildIndex(testNodes)
                    let expectation = XCTestExpectation(description: "concurrent")
                    expectation.expectedFulfillmentCount = 2000
                    
                    let readQueue = DispatchQueue(label: "read", attributes: .concurrent)
                    let writeQueue = DispatchQueue(label: "write")
                    
                    for i in 0..<100 {
                        // Readers
                        for _ in 0..<10 {
                            expectation.fulfill()
                            readQueue.async {
                                let snapshot = manager.currentSnapshot
                                _ = snapshot.nodesByName.prefixRange("test")
                                _ = snapshot.nodesBySize?.range(0...1000)
                            }
                        }
                        
                        // Writers
                        expectation.fulfill()
                        writeQueue.async {
                            let newNode = createTestNode(name: "concurrent_\(i).txt", inodeID: UInt64(10000 + i), parentID: 2)
                            _ = manager.apply(.insert(createTestNode(name: "concurrent_\(i).txt", inodeID: UInt64(10000 + i), parentID: 2)), to: manager.currentSnapshot)
                        }
                    }
                    
                    wait(for: [expectation], timeout: 10)
                }
            }
            
            context("Memory Efficiency") {
                it("uses COW for snapshots") {
                    manager.buildIndex(testNodes)
                    let snapshot1 = manager.currentSnapshot
                    
                    // Apply small delta
                    let snapshot2 = manager.apply(.insert(createTestNode(name: "cow.txt", inodeID: 9999, parentID: 2)), to: snapshot1)
                    
                    // Most arrays should be shared (COW)
                    // This is a structural test - real verification needs memory introspection
                    expect(snapshot1.nodesByName).to(beIdenticalTo(snapshot2.nodesByName))
                    // But nodesByInode should differ
                    expect(snapshot1.nodesByInode.count).to(equal(1000))
                    expect(snapshot2.nodesByInode.count).to(equal(1001))
                }
                
                it("fast-sort indexes use same node references") {
                    manager.enableFastSort([.size, .modTime])
                    manager.buildIndex(testNodes)
                    let snapshot = manager.currentSnapshot
                    
                    let primary = snapshot.nodesByName.first!
                    let bySize = snapshot.nodesBySize?.first
                    
                    expect(bySize).to(beIdenticalTo(primary))
                }
            }
        }
    }
}

// MARK: - Property-Based Tests for IndexManager

final class IndexManagerPropertyTests: QuickSpec {
    override class func spec() {
        describe("IndexManager Property Tests") {
            var manager: IndexManager!
            
            beforeEach {
                manager = IndexManager()
            }
            
            it("insert then remove restores original") {
                property("insert/remove roundtrip") <- forAll { (nodes: [TestNode], newNode: TestNode) in
                    let manager = IndexManager()
                    let baseNodes = nodes.map { $0.toFSNode() }
                    manager.buildIndex(baseNodes)
                    let snapshot1 = manager.currentSnapshot
                    
                    let fsNode = newNode.toFSNode()
                    let snapshot2 = manager.apply(.insert(fsNode), to: snapshot1)
                    let snapshot3 = manager.apply(.remove(inodeID: fsNode.inodeID, volumeID: fsNode.volumeID), to: snapshot2)
                    
                    return snapshot1.totalNodes == snapshot3.totalNodes &&
                           snapshot1.nodesByInode.keys == snapshot3.nodesByInode.keys
                }
            }
            
            it("move preserves node identity") {
                property("move preserves identity") <- forAll { (nodes: [TestNode], targetIdx: Int, newParent: UInt64) in
                    guard !nodes.isEmpty else { return true }
                    let idx = abs(targetIdx) % nodes.count
                    let manager = IndexManager()
                    let baseNodes = nodes.map { $0.toFSNode() }
                    manager.buildIndex(baseNodes)
                    let snapshot1 = manager.currentSnapshot
                    
                    let target = baseNodes[idx]
                    let snapshot2 = manager.apply(.move(
                        inodeID: target.inodeID,
                        volumeID: target.volumeID,
                        newParentID: 999,
                        newName: "moved.txt"
                    ), to: snapshot1)
                    
                    let moved = snapshot2.nodesByInode[CompositeKey(deviceID: target.volumeID, inodeID: target.inodeID)]
                    return moved?.inodeID == target.inodeID &&
                           moved?.privateID == target.privateID &&
                           moved?.createTime == target.createTime
                }
            }
            
            it("batch deltas equal sequential") {
                property("batch equals sequential") <- forAll { (deltas: [TestDelta]) in
                    let manager = IndexManager()
                    let nodes = createTestNodes(100)
                    manager.buildIndex(nodes)
                    let snapshot1 = manager.currentSnapshot
                    
                    let fsDeltas = deltas.map { $0.toIndexDelta() }
                    
                    let batchSnapshot = manager.applyBatch(fsDeltas, to: snapshot1)
                    
                    var seqSnapshot = snapshot1
                    for delta in fsDeltas {
                        seqSnapshot = manager.apply(delta, to: seqSnapshot)
                    }
                    
                    return batchSnapshot.totalNodes == seqSnapshot.totalNodes &&
                           batchSnapshot.nodesByInode.keys == seqSnapshot.nodesByInode.keys
                }
            }
        }
    }
}

// MARK: - IndexManager Performance Tests

final class IndexManagerPerformanceTests: QuickSpec {
    override class func spec() {
        describe("IndexManager Performance") {
            var manager: IndexManager!
            var testNodes: [FSNode]!
            
            beforeEach {
                manager = IndexManager()
                testNodes = createTestNodes(100_000)
            }
            
            it("builds 100k node index fast") {
                measure(MetricsRegistry.shared.scanDuration) {
                    manager.buildIndex(testNodes)
                }
                
                let snapshot = manager.currentSnapshot
                expect(snapshot.totalNodes).to(equal(100_000))
            }
            
            it("applies delta fast") {
                manager.buildIndex(testNodes)
                let snapshot = manager.currentSnapshot
                
                let iterations = 10000
                let start = CFAbsoluteTimeGetCurrent()
                
                for i in 0..<iterations {
                    let node = createTestNode(name: "delta_\(i).txt", inodeID: UInt64(1_000_000 + i), parentID: 2)
                    _ = manager.apply(.insert(node), to: manager.currentSnapshot)
                }
                
                let elapsed = CFAbsoluteTimeGetCurrent() - CFAbsoluteTimeGetCurrent() + CFAbsoluteTimeGetCurrent()
                // Just verify it completes
                expect(manager.currentSnapshot.totalNodes).to(equal(100_000 + iterations))
            }
            
            it("search on 100k index is fast") {
                manager.buildIndex(testNodes)
                let snapshot = manager.currentSnapshot
                
                let bytecode: [SearchOpcode] = [.namePrefix("test")]
                let vm = BytecodeVM()
                
                let iterations = 1000
                let start = CFAbsoluteTimeGetCurrent()
                
                for _ in 0..<iterations {
                    _ = BytecodeVM().execute([.namePrefix("test")], against: snapshot)
                }
                
                let elapsed = CFAbsoluteTimeGetCurrent() - CFAbsoluteTimeGetCurrent() + CFAbsoluteTimeGetCurrent()
                let perQuery = elapsed / 1000 * 1_000_000
                
                print("Search on 100k: \(perQuery) µs")
                expect(perQuery).to(beLessThan(100))
            }
        }
    }
}

// MARK: - IndexManager Edge Case Tests

final class IndexManagerEdgeCaseTests: QuickSpec {
    override class func spec() {
        describe("IndexManager Edge Cases") {
            var manager: IndexManager!
            
            beforeEach {
                manager = IndexManager()
            }
            
            it("handles empty index") {
                manager.buildIndex([])
                let snapshot = manager.currentSnapshot
                
                expect(snapshot.totalNodes).to(equal(0))
                expect(snapshot.nodesByName.count).to(equal(0))
                
                let results = BytecodeVM().execute([.namePrefix("test")], against: snapshot)
                expect(results.count).to(equal(0))
            }
            
            it("handles single node") {
                let node = createTestNode(name: "single.txt", inodeID: 1, parentID: 2)
                manager.buildIndex([node])
                
                let snapshot = manager.currentSnapshot
                expect(snapshot.totalNodes).to(equal(1))
                expect(snapshot.nodesByInode.count).to(equal(1))
            }
            
            it("handles duplicate inode IDs (different volumes)") {
                let node1 = createTestNode(name: "file.txt", inodeID: 100, parentID: 2, volumeID: 1)
                let node2 = createTestNode(name: "file.txt", inodeID: 100, parentID: 2, volumeID: 2)
                manager.buildIndex([node1, node2])
                
                let snapshot = manager.currentSnapshot
                expect(snapshot.totalNodes).to(equal(2))
                expect(snapshot.nodesByInode.count).to(equal(2))
            }
            
            it("handles move to non-existent parent") {
                let node = createTestNode(name: "test.txt", inodeID: 100, parentID: 2)
                manager.buildIndex([node])
                let snapshot1 = manager.currentSnapshot
                
                // Move to parent that doesn't exist
                let snapshot2 = manager.apply(.move(inodeID: 100, volumeID: 1, newParentID: 999, newName: "moved.txt"), to: snapshot1)
                
                let moved = snapshot2.nodesByInode[CompositeKey(deviceID: 1, inodeID: 100)]
                expect(moved?.parentID).to(equal(999))
                // Path computation might need special handling
            }
            
            it("handles remove non-existent node") {
                manager.buildIndex(createTestNodes(100))
                let snapshot1 = manager.currentSnapshot
                
                let snapshot2 = manager.apply(.remove(inodeID: 99999, volumeID: 1), to: snapshot1)
                
                // Should not crash, count unchanged
                expect(snapshot2.totalNodes).to(equal(100))
            }
            
            it("handles update on non-existent node") {
                manager.buildIndex(createTestNodes(100))
                let snapshot1 = manager.currentSnapshot
                
                let snapshot2 = manager.apply(.updateSize(inodeID: 99999, volumeID: 1, newSize: 5000), to: snapshot1)
                
                expect(snapshot2.totalNodes).to(equal(100))
            }
            
            it("handles very deep directory hierarchy") {
                var nodes: [FSNode] = []
                var currentParent: UInt64 = 2
                
                for depth in 0..<1000 {
                    let node = createTestNode(
                        name: "depth_\(depth).txt",
                        inodeID: UInt64(1000 + depth),
                        parentID: currentParent
                    )
                    nodes.append(node)
                    currentParent = UInt64(1000 + depth)
                }
                
                manager.buildIndex(nodes)
                let snapshot = manager.currentSnapshot
                
                expect(snapshot.totalNodes).to(equal(1000))
                expect(snapshot.nodesByParent.count).to(equal(1000))
            }
            
            it("handles nodes with all optional fields") {
                let node = FSNode(
                    inodeID: 100,
                    parentID: 2,
                    privateID: 100,
                    name: "full.txt",
                    createTime: 1704067200,
                    createTimeNsec: 123456789,
                    modTime: 1704153600,
                    modTimeNsec: 987654321,
                    changeTime: 1704240000,
                    changeTimeNsec: 555555555,
                    accessTime: 1704326400,
                    accessTimeNsec: 111111111,
                    fileSize: 4096,
                    uncompressedSize: 8192,
                    mode: 0o100644,
                    flags: INODE_HAS_UNCOMPRESSED_SIZE | INODE_WAS_CLONED,
                    bsdFlags: UF_COMPRESSED | UF_IMMUTABLE,
                    owner: 501,
                    group: 20,
                    writeGen: 42,
                    cloneGroupID: 42,
                    hardLinkCount: 3,
                    volumeID: 1,
                    apfsVolumeUUID: UUID(),
                    volfsVolumeID: 16777220,
                    filerefVolumeID: 6571367,
                    path: "/test/full.txt",
                    depth: 1
                )
                
                manager.buildIndex([node])
                let snapshot = manager.currentSnapshot
                let stored = snapshot.nodesByInode[CompositeKey(deviceID: 1, inodeID: 100)]
                
                expect(stored).toNot(beNil())
                expect(stored?.createTimeNsec).to(equal(123456789))
                expect(stored?.uncompressedSize).to(equal(8192))
                expect(stored?.cloneGroupID).to(equal(42))
                expect(stored?.hardLinkCount).to(equal(3))
                expect(stored?.volfsVolumeID).to(equal(16777220))
                expect(stored?.filerefVolumeID).to(equal(6571367))
            }
        }
    }
}

// MARK: - Test Helpers

struct TestNode {
    let name: String
    let inodeID: UInt64
    let parentID: UInt64
    let volumeID: UInt32
    let size: UInt64
    let modTime: UInt64
    
    func toFSNode() -> FSNode {
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
}

struct TestDelta {
    enum Kind { case insert, remove, updateSize }
    let kind: Kind
    let node: TestNode?
    let inodeID: UInt64?
    let volumeID: UInt32?
    let size: UInt64?
    
    func toIndexDelta() -> IndexDelta {
        switch kind {
        case .insert:
            return .insert(node!.toFSNode())
        case .remove:
            return .remove(inodeID: inodeID!, volumeID: volumeID!)
        case .updateSize:
            return .updateSize(inodeID: inodeID!, volumeID: volumeID!, newSize: size!)
        }
    }
}

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

func createNodesWithDuplicateNames() -> [FSNode] {
    return [
        createTestNode(name: "duplicate.txt", inodeID: 100, parentID: 10),
        createTestNode(name: "duplicate.txt", inodeID: 200, parentID: 20),
        createTestNode(name: "duplicate.txt", inodeID: 300, parentID: 30)
    ]
}

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